# frozen_string_literal: true

module CustomFeeds
  # Fetches candidates from all pull sources for a single CustomFeedConfig,
  # runs them through the filter pipeline, and pushes passing statuses into
  # the feed. Updates last_pulled_at on the config when complete.
  class PullSourceIngestWorker
    include Sidekiq::Worker
    include DatabaseHelper

    sidekiq_options queue: 'pull', retry: 3

    def perform(config_id)
      config = CustomFeedConfig.find_by(id: config_id)
      return unless config&.enabled?

      account = config.account
      return unless account.user&.signed_in_recently?

      pipeline = CustomFeeds::Pipeline.new(config)
      return unless pipeline.pull_sources?

      all_candidates = []

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

          # Always advance the cursor from the raw API response ID so we don't
          # re-fetch posts that failed to resolve (e.g. transient federation gaps).
          cursor.update!(last_fetched_id: result.max_remote_id, last_fetched_at: Time.current) if result.max_remote_id.present?

          all_candidates.concat(result.statuses)
        end
      end

      # Always stamp last_pulled_at so the scheduler knows this run completed,
      # even when no statuses resolved (avoids re-enqueuing every 5-minute tick).
      config.update_column(:last_pulled_at, Time.current)

      return if all_candidates.empty?

      seen = Set.new
      deduped = all_candidates.select { |s| seen.add?(s.id) }

      deduped.each do |status|
        # Respect user-level blocks, mutes, and domain blocks.
        # We don't use FeedManager.filter(:home, ...) here because filter_from_home
        # applies home-feed-specific rules (language filters, exclusive-list skips)
        # that are not appropriate for a custom feed context.
        next if account.blocking?(status.account) ||
                status.account.blocking?(account) ||
                account.muting?(status.account) ||
                account.domain_blocking?(status.account.domain)
        next unless pipeline.passes_filters?(status, account)

        if pipeline.algorithmic?
          # Stage in the pending queue; the algorithm worker promotes to the feed.
          CustomFeeds::FeedManager.instance.enqueue_candidate(config, status)
          CustomFeeds::Metrics.record_insert(feed_type: 'algorithmic', result: 'enqueued')
        else
          CustomFeeds::FeedManager.instance.push_and_stream(config, status)
          CustomFeeds::Metrics.record_insert(feed_type: 'standard', result: 'pushed')
        end
      end
    rescue ActiveRecord::RecordNotFound
      true
    end
  end
end
