# frozen_string_literal: true

module CustomFeeds
  module StatusConcern
    extend ActiveSupport::Concern

    included do
      after_create_commit :enqueue_custom_feed_remove_if_interaction
    end

    # Returns the original status, resolving through any reblog chain.
    # Consistent helper used throughout the custom feeds pipeline.
    # @return [Status]
    def original_status
      reblog? ? reblog : self
    end

    private

    def enqueue_custom_feed_remove_if_interaction
      return unless account.local?

      if reblog?
        CustomFeeds::FeedRemoveWorker.perform_async(reblog_of_id, account_id, 'reblog')
        ::Recommendations::SignalWorker.perform_async('reblog', reblog_of_id, account_id)
      elsif reply?
        CustomFeeds::FeedRemoveWorker.perform_async(in_reply_to_id, account_id, 'reply')
        ::Recommendations::SignalWorker.perform_async('reply', in_reply_to_id, account_id)
      end
    end
  end
end
