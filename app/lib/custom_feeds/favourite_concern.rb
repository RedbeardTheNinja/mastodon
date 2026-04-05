# frozen_string_literal: true

module CustomFeeds
  module FavouriteConcern
    extend ActiveSupport::Concern

    included do
      after_create_commit :enqueue_custom_feed_remove_on_favourite
    end

    private

    def enqueue_custom_feed_remove_on_favourite
      # status_id is always the original status ID (Favourite normalises reblogs before saving)
      CustomFeeds::FeedRemoveWorker.perform_async(status_id, account_id, 'favourite')
    end
  end
end
