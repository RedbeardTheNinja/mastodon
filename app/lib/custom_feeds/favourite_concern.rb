# frozen_string_literal: true

module CustomFeeds
  module FavouriteConcern
    extend ActiveSupport::Concern

    included do
      after_create_commit :enqueue_custom_feed_remove_on_favourite
      after_create_commit :enqueue_recommendation_signal
    end

    private

    def enqueue_custom_feed_remove_on_favourite
      # status_id is always the original status ID (Favourite normalises reblogs before saving)
      CustomFeeds::FeedRemoveWorker.perform_async(status_id, account_id, 'favourite')
    end

    def enqueue_recommendation_signal
      ::Recommendations::SignalWorker.perform_async('favourite', status_id, account_id)
    end
  end
end
