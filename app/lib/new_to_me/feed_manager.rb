# frozen_string_literal: true

require 'singleton'

module NewToMe
  class FeedManager
    include Singleton
    include Redisable

    # Redis key for a given account's New To Me feed
    # @param [Integer] account_id
    # @return [String]
    def key(account_id)
      "feed:new_to_me:#{account_id}"
    end

    # Add a status to an account's New To Me feed.
    # Skips if the user is inactive, has no user, or has already interacted.
    # @param [Account] account
    # @param [Status] status
    # @return [Boolean]
    def push(account, status)
      return false unless account.user&.signed_in_recently?
      return false if interacted?(account, status)

      redis.zadd(key(account.id), status.id, status.id)
      trim(account.id)
      true
    end

    # Remove a status from an account's New To Me feed.
    # @param [Account] account
    # @param [Integer] status_id
    # @return [void]
    def remove(account, status_id)
      redis.zrem(key(account.id), status_id)
    end

    # Check whether the account has already interacted with the status
    # via favourite, reblog, or reply.
    # @param [Account] account
    # @param [Status] status
    # @return [Boolean]
    def interacted?(account, status)
      status = status.reblog if status.reblog?
      Favourite.exists?(account: account, status: status) ||
        Status.exists?(account: account, reblog_of_id: status.id) ||
        Status.exists?(account: account, in_reply_to_id: status.id)
    end

    private

    def trim(account_id)
      redis.zremrangebyrank(key(account_id), 0, -(::FeedManager::MAX_ITEMS + 1))
    end
  end
end
