# frozen_string_literal: true

module CustomFeeds
  module Filters
    # Excludes posts the account has already interacted with via favourite,
    # reblog, or reply. Reblogs are resolved to their original before checking
    # so that interacting with an original excludes all reblogs of it too.
    class InteractedPosts < Base
      def self.key
        'interacted_posts'
      end

      # @param [Status] status
      # @param [Account] account
      # @param [Hash] _options
      # @return [Boolean]
      def exclude?(status, account, _options = {})
        original = status.original_status

        Favourite.exists?(account: account, status: original) ||
          Status.exists?(account: account, reblog_of_id: original.id) ||
          Status.exists?(account: account, in_reply_to_id: original.id)
      end
    end
  end
end
