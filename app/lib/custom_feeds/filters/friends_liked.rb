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
        orig = status.original_status

        # Cache following IDs for the lifetime of this filter instance (one per
        # pipeline build / worker job) to avoid N+1 queries across candidates.
        @following_ids_cache ||= {}
        following_ids = @following_ids_cache[account.id] ||= account.following.pluck(:id).to_set
        return true if following_ids.empty?

        fav_ids = following_ids.to_a
        fav_count    = Favourite.where(account_id: fav_ids, status_id: orig.id).count
        return false if fav_count >= min

        reblog_count = Status.where(account_id: fav_ids, reblog_of_id: orig.id).count
        (fav_count + reblog_count) < min
      end
    end
  end
end
