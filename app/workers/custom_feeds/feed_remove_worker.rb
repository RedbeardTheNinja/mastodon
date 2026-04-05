# frozen_string_literal: true

module CustomFeeds
  class FeedRemoveWorker
    include Sidekiq::Worker
    include Redisable

    sidekiq_options queue: 'default', retry: 3

    def perform(status_id, account_id, interaction_type)
      account = Account.find(account_id)

      # The status_id is always the original (never a reblog ID) because:
      # - Favourite normalises to original before saving.
      # - StatusConcern passes reblog_of_id / in_reply_to_id.
      # We must also remove any reblog entries stored in the feed.
      ids_to_remove = [status_id] + Status.where(reblog_of_id: status_id).pluck(:id)

      CustomFeedConfig.enabled.where(account: account).find_each do |config|
        pipeline = CustomFeeds::Pipeline.new(config)
        next unless pipeline.remove_on?(interaction_type)

        CustomFeeds::FeedManager.instance.remove_and_stream(config, ids_to_remove)
      rescue => e
        Rails.logger.error(
          "#{self.class.name} failed for config #{config.id}: #{e.class}: #{e.message}"
        )
      end
    rescue ActiveRecord::RecordNotFound
      # Account was deleted before the job ran — expected, not an error.
      Rails.logger.debug { "#{self.class.name}: account #{account_id} not found, skipping" }
    end
  end
end
