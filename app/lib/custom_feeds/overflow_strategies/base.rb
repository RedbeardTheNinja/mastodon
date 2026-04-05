# frozen_string_literal: true

module CustomFeeds
  module OverflowStrategies
    class Base
      include CustomFeeds::Registerable

      # Return true to block insertion when the feed is already at capacity.
      # Called BEFORE zadd; if true, the status is not added.
      # @param [Integer] current_count
      # @param [Integer] max_items
      # @param [Hash] options
      # @return [Boolean]
      def at_capacity?(_current_count, _max_items, _options = {})
        false
      end

      # Called AFTER zadd to trim the feed if needed.
      # @param [Redis] _redis
      # @param [String] _key
      # @param [Integer] _max_items
      # @param [Hash] _options
      # @return [void]
      def trim(_redis, _key, _max_items, _options = {})
        # no-op by default
      end
    end
  end
end
