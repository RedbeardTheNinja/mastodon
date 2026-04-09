# frozen_string_literal: true

module CustomFeeds
  # Fetches candidates from all pull sources for a single CustomFeedConfig,
  # runs them through the filter pipeline, and pushes passing statuses into
  # the feed. Updates last_pulled_at on the config when complete.
  #
  # When fewer than 3/4 of fetched candidates pass the filter pipeline, the
  # worker re-fetches (cursors already advanced) and adds the new candidates
  # to the result. It retries up to MAX_RETRIES additional times, stopping
  # early if the API returns nothing new (cursor stopped advancing) or all
  # fetched candidates were already seen.
  class PullSourceIngestWorker
    include Sidekiq::Worker
    include DatabaseHelper

    sidekiq_options queue: 'pull', retry: 3, lock: :until_executed, lock_ttl: 30.minutes.to_i

    MAX_RETRIES = 3
    REFILL_THRESHOLD = 3.0 / 4.0

    def perform(config_id)
      config = CustomFeedConfig.find_by(id: config_id)
      return unless config&.enabled?

      account = config.account
      return unless account.user&.signed_in_recently?

      pipeline = CustomFeeds::Pipeline.new(config)
      return unless pipeline.pull_sources?

      Rails.logger.info { "PullSourceIngestWorker: config=#{config_id} starting" }

      seen           = Set.new
      total_promoted = 0
      total_filtered = 0

      # Initial fetch plus up to MAX_RETRIES additional rounds.
      (1 + MAX_RETRIES).times do |attempt|
        any_cursor_advanced, raw_candidates = fetch_round(config_id, pipeline, account)

        new_candidates = raw_candidates.reject { |s| seen.include?(s.id) }
        new_candidates.each { |s| seen.add(s.id) }

        round_promoted, round_filtered = promote_candidates(new_candidates, pipeline, config, account)
        total_promoted += round_promoted
        total_filtered += round_filtered

        Rails.logger.debug do
          "PullSourceIngestWorker: config=#{config_id} attempt=#{attempt + 1} " \
            "fetched=#{new_candidates.size} promoted=#{round_promoted} filtered=#{round_filtered}"
        end

        # Stop if the API has no more posts, all fetched posts were already seen,
        # or enough posts made it through the filter this round.
        break unless any_cursor_advanced
        break if new_candidates.empty?
        break if round_promoted >= new_candidates.size * REFILL_THRESHOLD
      end

      # Stamp last_pulled_at after all rounds so the scheduler knows this run
      # completed (avoids re-enqueuing on the next 5-minute tick).
      config.update_column(:last_pulled_at, Time.current)

      Rails.logger.info do
        "PullSourceIngestWorker: config=#{config_id} total_promoted=#{total_promoted} total_filtered=#{total_filtered}"
      end
    rescue ActiveRecord::RecordNotFound
      # Config or account was deleted before the job ran — expected, not an error.
      Rails.logger.debug { "#{self.class.name}: record not found for config #{config_id}" }
    end

    private

    # Runs one fetch round across all pull source entries and their buckets.
    # Advances cursors for any bucket that returned a new max_remote_id.
    #
    # Returns [any_cursor_advanced, candidates] where any_cursor_advanced is true
    # if at least one bucket's cursor moved (i.e. the API returned new posts).
    def fetch_round(config_id, pipeline, account)
      any_cursor_advanced = false
      candidates = []

      pipeline.pull_source_entries.each do |entry|
        klass   = entry[:klass]
        options = entry[:options]
        step    = entry[:step]
        source  = entry[:instance]

        buckets = klass.buckets_for(options)
        buckets = [''] if buckets.empty?

        buckets.each do |bucket|
          cursor = CustomFeedPullCursor.for_step_bucket(step, bucket)

          result = source.fetch_candidates(account, options, since_id: cursor.last_fetched_id, bucket: bucket)

          Rails.logger.debug do
            "PullSourceIngestWorker: config=#{config_id} bucket=#{bucket.inspect} " \
              "fetched=#{result.statuses.size} max_remote_id=#{result.max_remote_id.inspect}"
          end

          # Always advance the cursor from the raw API response ID so we don't
          # re-fetch posts that failed to resolve (e.g. transient federation gaps).
          if result.max_remote_id.present?
            cursor.update!(last_fetched_id: result.max_remote_id, last_fetched_at: Time.current)
            any_cursor_advanced = true
          end

          candidates.concat(result.statuses)
        end
      end

      [any_cursor_advanced, candidates]
    end

    # Filters candidates through block/mute/domain checks and the pipeline,
    # then pushes passing statuses into the feed (or pending queue for algo feeds).
    #
    # Returns [promoted, filtered] counts.
    def promote_candidates(candidates, pipeline, config, account)
      promoted = 0
      filtered = 0

      candidates.each do |status|
        # Respect user-level blocks, mutes, and domain blocks.
        # We don't use FeedManager.filter(:home, ...) here because filter_from_home
        # applies home-feed-specific rules (language filters, exclusive-list skips)
        # that are not appropriate for a custom feed context.
        next if account.blocking?(status.account) ||
                status.account.blocking?(account) ||
                account.muting?(status.account) ||
                account.domain_blocking?(status.account.domain)

        unless pipeline.passes_filters?(status, account)
          filtered += 1
          next
        end

        if pipeline.algorithmic?
          # Stage in the pending queue; the algorithm worker promotes to the feed.
          CustomFeeds::FeedManager.instance.enqueue_candidate(config, status)
          CustomFeeds::Metrics.record_insert(feed_type: 'algorithmic', result: 'enqueued')
        else
          CustomFeeds::FeedManager.instance.push_and_stream(config, status)
          CustomFeeds::Metrics.record_insert(feed_type: 'standard', result: 'pushed')
        end
        promoted += 1
      end

      [promoted, filtered]
    end
  end
end
