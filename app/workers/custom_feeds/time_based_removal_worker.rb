# frozen_string_literal: true

module CustomFeeds
  # Scans every enabled custom feed that has a time_based removal strategy
  # and removes posts whose snowflake ID falls before the cutoff timestamp.
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

      cutoff_id = Mastodon::Snowflake.id_at(duration_minutes.minutes.ago, with_random: false)
      feed_key  = CustomFeeds::FeedManager.instance.key(config.list_id)

      # The sorted set score IS the status ID, so all members with score <= cutoff_id
      # were created (and added to the feed) more than duration_minutes ago.
      expired_ids = redis.zrangebyscore(feed_key, '-inf', cutoff_id).map(&:to_i)
      return if expired_ids.empty?

      CustomFeeds::FeedManager.instance.remove_and_stream(config, expired_ids)
    end
  end
end
