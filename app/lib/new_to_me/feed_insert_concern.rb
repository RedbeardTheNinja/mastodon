# frozen_string_literal: true

module NewToMe
  module FeedInsertConcern
    def perform_push
      super
      return unless @type == :home

      NewToMe::FeedInsertWorker.perform_async(@status.id, @follower.id)
    end
  end
end
