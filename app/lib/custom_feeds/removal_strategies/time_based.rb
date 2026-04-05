# frozen_string_literal: true

module CustomFeeds
  module RemovalStrategies
    # Removes posts from the feed once they have been present for longer than
    # a configured duration. Removal is handled by TimeBasedRemovalWorker on a
    # schedule rather than in response to user interactions, so remove_on?
    # always returns false.
    #
    # options keys:
    #   duration_minutes (integer, required) — how long to keep each post
    class TimeBased < Base
      def self.key
        'time_based'
      end

      # @param [String] _interaction_type
      # @param [Hash]   _options
      # @return [Boolean]
      def remove_on?(_interaction_type, _options = {})
        false
      end
    end
  end
end
