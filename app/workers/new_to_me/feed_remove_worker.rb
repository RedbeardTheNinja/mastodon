# frozen_string_literal: true

module NewToMe
  class FeedRemoveWorker
    include Sidekiq::Worker
    include Redisable

    sidekiq_options queue: 'default', retry: 3

    def perform(status_id, account_id)
      account = Account.find(account_id)

      # Interactions (favourite, reblog, reply) always resolve to the original status ID,
      # but the NTM feed stores the reblog status ID. Remove both the original and any
      # reblogs of it so either case is handled.
      ids_to_remove = [status_id] + Status.where(reblog_of_id: status_id).pluck(:id)
      ids_to_remove.each { |id| NewToMe::FeedManager.instance.remove(account, id) }

      list = List.find_by(account: account, title: NewToMe::LIST_TITLE)
      if list
        channel = "timeline:list:#{list.id}"
        ids_to_remove.each do |id|
          redis.publish(channel, Oj.dump(event: :delete, payload: id.to_s))
        end
      end
    rescue ActiveRecord::RecordNotFound
      true
    end
  end
end
