# frozen_string_literal: true

module CustomFeeds
  class FeedInsertWorker
    include Sidekiq::Worker
    include DatabaseHelper

    sidekiq_options queue: 'push', retry: 3

    def perform(status_id, account_id)
      with_primary do
        @status  = Status.find(status_id)
        @account = Account.find(account_id)
      end

      with_read_replica do
        return unless @account.user&.signed_in_recently?
        return if ::FeedManager.instance.filter(:home, @status, @account)

        configs = CustomFeedConfig
          .enabled
          .where(account: @account)
          .joins(:custom_feed_steps)
          .where(custom_feed_steps: { phase: 'source', step_type: 'followed_posts' })
          .distinct

        configs.each do |config|
          pipeline = CustomFeeds::Pipeline.new(config)
          next unless pipeline.include?(@status, @account)

          if pipeline.algorithmic?
            CustomFeeds::FeedManager.instance.enqueue_candidate(config, @status)
            CustomFeeds::Metrics.record_insert(feed_type: 'algorithmic', result: 'enqueued')
          else
            CustomFeeds::FeedManager.instance.push_and_stream(config, @status)
            CustomFeeds::Metrics.record_insert(feed_type: 'standard', result: 'pushed')
          end
        end
      end
    rescue ActiveRecord::RecordNotFound
      # Status or account was deleted before the job ran — expected, not an error.
      Rails.logger.debug { "#{self.class.name}: record not found (status=#{status_id} account=#{account_id})" }
    end
  end
end
