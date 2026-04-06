# frozen_string_literal: true

module CustomFeeds
  class FeedRemoveWorker
    include Sidekiq::Worker
    include Redisable

    sidekiq_options queue: 'default', retry: 3

    # When config_id is nil (initial call), iterates all configs for the account.
    # Configs whose removal strategy has a delay > 0 are re-enqueued with
    # perform_in so removal happens after the configured delay.
    #
    # When config_id is present (delayed call), processes only that one config
    # immediately — the delay has already elapsed.
    def perform(status_id, account_id, interaction_type, config_id = nil)
      account = Account.find(account_id)

      # The status_id is always the original (never a reblog ID) because:
      # - Favourite normalises to original before saving.
      # - StatusConcern passes reblog_of_id / in_reply_to_id.
      # We must also remove any reblog entries stored in the feed.
      ids_to_remove = [status_id] + Status.where(reblog_of_id: status_id).pluck(:id)

      scope = if config_id
                CustomFeedConfig.enabled.where(account: account, id: config_id)
              else
                CustomFeedConfig.enabled.where(account: account)
              end

      scope.find_each do |config|
        pipeline = CustomFeeds::Pipeline.new(config)
        next unless pipeline.remove_on?(interaction_type)

        if config_id.nil?
          delay = pipeline.removal_delay_for(interaction_type)
          if delay.positive?
            self.class.perform_in(delay, status_id, account_id, interaction_type, config.id)
            next
          end
        end

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
