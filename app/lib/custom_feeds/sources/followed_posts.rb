# frozen_string_literal: true

module CustomFeeds
  module Sources
    class FollowedPosts < Base
      def self.key
        'followed_posts'
      end

      # Returns true if the status would pass the home feed filter for the account.
      # Uses ::FeedManager (top-level) to avoid resolving to CustomFeeds::FeedManager.
      # @param [Status] status
      # @param [Account] account
      # @param [Hash] _options
      # @return [Boolean]
      def includes?(status, account, _options = {})
        !::FeedManager.instance.filter(:home, status, account)
      end
    end
  end
end
