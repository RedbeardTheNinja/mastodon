# frozen_string_literal: true

module CustomFeeds
  module FeedInsertConcern
    def perform_push
      super
      return unless @type == :home

      CustomFeeds::FeedInsertWorker.perform_async(@status.id, @follower.id)
    end
  end
end
