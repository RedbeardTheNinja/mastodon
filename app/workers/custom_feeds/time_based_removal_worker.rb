# frozen_string_literal: true

module CustomFeeds
  # Scans every enabled custom feed that has a time_based removal strategy
  # and removes posts that have been in the feed longer than the configured
  # duration. Uses the inserted_at hash (feed:custom:{id}:inserted_at) written
  # by FeedManager#push rather than the status snowflake ID, so the timer
  # measures time since the post entered this feed, not when it was created.
  #
  # Also performs lazy cleanup of orphaned inserted_at entries left behind
  # by overflow trimming, which removes entries from the sorted set directly
  # without going through FeedManager#remove.
  #
  # Runs on a schedule (every 5 minutes via sidekiq.yml).
  class TimeBasedRemovalWorker
    include Sidekiq::Worker
    include Redisable

    sidekiq_options queue: 'scheduler', retry: 1

    def perform
      configs_with_time_based_removal.find_each do |config|
        process_config(config)
      rescue => e
        Rails.logger.warn("CustomFeeds::TimeBasedRemovalWorker failed for config #{config.id}: #{e.message}")
      end
    end

    private

    def configs_with_time_based_removal
      CustomFeedConfig
        .enabled
        .joins(:custom_feed_steps)
        .where(custom_feed_steps: { phase: 'removal_strategy', step_type: 'time_based' })
        .distinct
    end

    def process_config(config)
      step = config.steps_for('removal_strategy').find { |s| s.step_type == 'time_based' }
      return unless step

      duration_minutes = step.options['duration_minutes'].to_i
      return if duration_minutes <= 0

      cutoff    = duration_minutes.minutes.ago.to_i
      feed_key  = CustomFeeds::FeedManager.instance.key(config.list_id)
      hash_key  = CustomFeeds::FeedManager.instance.inserted_at_key(config.list_id)

      # Load both the insertion-time hash and the current feed members.
      entries      = redis.hgetall(hash_key) # { "id" => "timestamp", ... }
      feed_members = redis.zrange(feed_key, 0, -1).to_set # { "id", ... }

      expired = []
      orphans = []

      entries.each do |id_str, ts_str|
        if feed_members.include?(id_str)
          expired << id_str.to_i if ts_str.to_i <= cutoff
        else
          # Entry was removed from the feed by overflow trimming without going
          # through FeedManager#remove — clean up the stale hash entry.
          orphans << id_str
        end
      end

      redis.hdel(hash_key, *orphans) if orphans.any?

      return if expired.empty?

      CustomFeeds::FeedManager.instance.remove_and_stream(config, expired)
    end
  end
end
