# frozen_string_literal: true

module CustomFeeds
  module OverflowStrategies
    # Default overflow strategy. Always allows insertion, then removes the
    # lowest-score entries (oldest status IDs) when over capacity.
    # This mirrors the trim behaviour of Mastodon's home and list feeds.
    class OldestFirst < Base
      def self.key
        'oldest_first'
      end

      # Always allows insertion; trimming is handled in #trim.
      # @param [Integer] _current_count
      # @param [Integer] _max_items
      # @param [Hash] _options
      # @return [false]
      def at_capacity?(_current_count, _max_items, _options = {})
        false
      end

      # Removes entries with the lowest scores (oldest) until the feed fits within max_items.
      # @param [Redis] redis
      # @param [String] key
      # @param [Integer] max_items
      # @param [Hash] _options
      # @return [void]
      def trim(redis, key, max_items, _options = {})
        redis.zremrangebyrank(key, 0, -(max_items + 1))
      end
    end
  end
end
