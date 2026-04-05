# frozen_string_literal: true

module CustomFeeds
  module Filters
    class Base
      REGISTRY = {} # rubocop:disable Style/MutableConstant

      def self.key
        raise NotImplementedError
      end

      def self.register!
        REGISTRY[key] = self
      end

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
