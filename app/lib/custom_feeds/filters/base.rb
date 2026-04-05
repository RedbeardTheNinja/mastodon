# frozen_string_literal: true

module CustomFeeds
  module Filters
    class Base
      include CustomFeeds::Registerable

      # Return true to EXCLUDE this status from the feed.
      # @param [Status] status
      # @param [Account] account
      # @param [Hash] options
      # @return [Boolean]
      def exclude?(status, account, options = {})
        raise NotImplementedError
      end
    end
  end
end
