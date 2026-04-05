# frozen_string_literal: true

module CustomFeeds
  module StatusConcern
    extend ActiveSupport::Concern

    included do
      after_create_commit :enqueue_custom_feed_remove_if_interaction
    end

    private

    def enqueue_custom_feed_remove_if_interaction
      return unless account.local?

      if reblog?
        CustomFeeds::FeedRemoveWorker.perform_async(reblog_of_id, account_id, 'reblog')
      elsif reply?
        CustomFeeds::FeedRemoveWorker.perform_async(in_reply_to_id, account_id, 'reply')
      end
    end
  end
end
