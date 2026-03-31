# frozen_string_literal: true

module NewToMe
  class FeedRemoveWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'default', retry: 3

    def perform(status_id, account_id)
      @account = Account.find(account_id)
      NewToMe::FeedManager.instance.remove(@account, status_id)
    rescue ActiveRecord::RecordNotFound
      true
    end
  end
end
