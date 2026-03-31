# frozen_string_literal: true

module NewToMe
  module StatusConcern
    extend ActiveSupport::Concern

    included do
      after_create_commit :enqueue_new_to_me_remove_if_interaction
    end

    private

    def enqueue_new_to_me_remove_if_interaction
      return unless account.local?

      if reblog?
        NewToMe::FeedRemoveWorker.perform_async(reblog_of_id, account_id)
      elsif reply?
        NewToMe::FeedRemoveWorker.perform_async(in_reply_to_id, account_id)
      end
    end
  end
end
