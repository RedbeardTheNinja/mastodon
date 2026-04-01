# frozen_string_literal: true

module NewToMe
  class FeedInsertWorker
    include Sidekiq::Worker
    include DatabaseHelper

    sidekiq_options queue: 'push', retry: 3

    def perform(status_id, account_id)
      with_primary do
        @status  = Status.find(status_id)
        @account = Account.find(account_id)
      end

      with_read_replica do
        return unless @account.user&.signed_in_recently?
        return if ::FeedManager.instance.filter(:home, @status, @account)

        NewToMe::FeedManager.instance.push(@account, @status)
      end
    rescue ActiveRecord::RecordNotFound
      true
    end
  end
end
