# frozen_string_literal: true

module CustomFeeds
  module Filters
    # Excludes posts from accounts the user has blocked or muted, accounts that
    # have blocked the user, and domain-blocked servers — mirroring the
    # blocking/muting checks applied to the home feed.
    #
    # This filter has no configurable options. It is either present (active) or
    # absent (explicitly disabled for this feed). New custom feeds include it by
    # default; removing it allows blocked/muted accounts to appear via pull sources.
    class HomeFilters < Base
      def self.key = 'home_filters'

      def exclude?(status, account, _options = {})
        original = status.original_status
        author   = original.account

        account.blocking?(author) ||
          author.blocking?(account) ||
          account.muting?(author) ||
          (author.domain.present? && account.domain_blocking?(author.domain))
      end
    end
  end
end
