# frozen_string_literal: true

module NewToMe
  module FavouriteConcern
    extend ActiveSupport::Concern

    included do
      after_create_commit :enqueue_new_to_me_remove
    end

    private

    def enqueue_new_to_me_remove
      NewToMe::FeedRemoveWorker.perform_async(status_id, account_id)
    end
  end
end
