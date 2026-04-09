# frozen_string_literal: true

module CustomFeeds
  module Filters
    # Excludes posts from accounts the user follows, so pull-sourced posts
    # that would already appear in the home feed are not duplicated here.
    # Reblogs are resolved to their original author before checking.
    class FollowedAccounts < Base
      def self.key = 'followed_accounts'

      def exclude?(status, account, _options = {})
        account.following?(status.original_status.account)
      end
    end
  end
end
