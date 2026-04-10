# frozen_string_literal: true

module Recommendations
  class AlgorithmicFeedWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'default', retry: 3

    def perform(config_id)
      config = CustomFeedConfig.where(feed_type: 'algorithmic', enabled: true).find_by(id: config_id)
      return unless config&.account&.user&.signed_in_recently?

      algo_step = config.steps_for('algorithm').first
      return unless algo_step

      algo_klass = Recommendations::Algorithms::Base.registry[algo_step.step_type]
      return unless algo_klass

      account    = config.account
      algo       = algo_klass.new(account)

      options    = algo_step.options.with_indifferent_access
      candidates = CustomFeeds::FeedManager.instance.dequeue_pending(
        config.list_id,
        limit: options.fetch(:batch_size, 100).to_i,
        max_age_hours: options.fetch(:max_pending_age_hours, 48).to_i
      )

      Rails.logger.info do
        "AlgorithmicFeedWorker: config=#{config_id} account=#{account.id} dequeued=#{candidates.size}"
      end

      return if candidates.empty?

      # Check min_signals gate before any scoring
      min_signals_step = config.steps_for('algorithmic_filter').find { |s| s.step_type == 'min_signals' }
      if min_signals_step
        required = min_signals_step.options.fetch('count', 5).to_i
        actual   = RecommendationSignal.where(account: account).count
        if actual < required
          Rails.logger.info do
            "AlgorithmicFeedWorker: config=#{config_id} skipped (min_signals: need #{required}, have #{actual})"
          end
          candidates.size.times { CustomFeeds::Metrics.record_algo_candidate(result: 'filtered_min_signals') }
          return
        end
      end

      scored = algo.score_batch(candidates)
      scores = scored.pluck(:score)
      Rails.logger.info do
        "AlgorithmicFeedWorker: config=#{config_id} scored=#{scored.size} " \
          "min=#{scores.min&.round(3)} max=#{scores.max&.round(3)} p50=#{percentile(scores, 50)&.round(3)}"
      end

      before_filter = scored.size
      scored = apply_algorithmic_filters(scored, config)
      filtered_score = before_filter - scored.size
      filtered_score.times { CustomFeeds::Metrics.record_algo_candidate(result: 'filtered_score') }

      Rails.logger.debug do
        "AlgorithmicFeedWorker: config=#{config_id} score_filter removed=#{filtered_score} remaining=#{scored.size}"
      end

      # Emit score histogram for posts that passed the score threshold and reach the pipeline.
      scored.each { |r| CustomFeeds::Metrics.record_algo_score(score: r[:score]) }

      # Run standard pipeline filters as a final gate before promotion
      pipeline = CustomFeeds::Pipeline.new(config)
      promoted_count = 0
      filtered_pipeline_count = 0
      scored.each do |result|
        if pipeline.passes_filters?(result[:status], account)
          CustomFeeds::FeedManager.instance.push_and_stream(config, result[:status])
          CustomFeeds::Metrics.record_algo_candidate(result: 'promoted')
          promoted_count += 1
          Rails.logger.debug do
            "AlgorithmicFeedWorker: config=#{config_id} promoted status=#{result[:status].id} score=#{result[:score].round(4)}"
          end
        else
          CustomFeeds::Metrics.record_algo_candidate(result: 'filtered_pipeline')
          filtered_pipeline_count += 1
        end
      end

      Rails.logger.info do
        "AlgorithmicFeedWorker: config=#{config_id} " \
          "promoted=#{promoted_count} filtered_score=#{filtered_score} filtered_pipeline=#{filtered_pipeline_count}"
      end
    end

    private

    def percentile(values, pct)
      return nil if values.empty?

      sorted = values.sort
      idx    = ((pct / 100.0) * (sorted.size - 1)).round
      sorted[idx]
    end

    def apply_algorithmic_filters(scored, config)
      config.steps_for('algorithmic_filter').each do |step|
        scored = case step.step_type
                 when 'min_score'
                   threshold = step.options.fetch('threshold', 0.1).to_f
                   scored.select { |r| r[:score] >= threshold }
                 when 'top_k_per_batch'
                   k = step.options.fetch('k', 10).to_i
                   scored.first(k)
                 else
                   scored
                 end
      end
      scored
    end
  end
end
