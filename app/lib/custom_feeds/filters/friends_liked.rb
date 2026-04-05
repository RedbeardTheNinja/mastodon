# frozen_string_literal: true

module CustomFeeds
  module Filters
    # Excludes posts unless at least `min_interactions` of the user's follows
    # have favourited or reblogged them. Queries local Mastodon data only.
    class FriendsLiked < Base
      def self.key
        'friends_liked'
      end

      # options keys:
      #   min_interactions (int, default 1)

      # @param [Status]  status
      # @param [Account] account
      # @param [Hash]    options
      # @return [Boolean]
      def exclude?(status, account, options = {})
        min  = (options['min_interactions'] || 1).to_i
        orig = status.reblog? ? status.reblog : status

        following_ids = account.following.pluck(:id)
        return true if following_ids.empty?

        fav_count    = Favourite.where(account_id: following_ids, status_id: orig.id).count
        return false if fav_count >= min

        reblog_count = Status.where(account_id: following_ids, reblog_of_id: orig.id).count
        (fav_count + reblog_count) < min
      end
    end
  end
end
