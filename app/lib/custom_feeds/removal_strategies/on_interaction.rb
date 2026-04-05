# frozen_string_literal: true

module CustomFeeds
  module RemovalStrategies
    # Removes a post from the feed whenever the user interacts with it
    # via any of: favourite, reblog, or reply.
    class OnInteraction < Base
      def self.key
        'on_interaction'
      end

      # @param [String] _interaction_type
      # @param [Hash] _options
      # @return [Boolean]
      def remove_on?(_interaction_type, _options = {})
        true
      end
    end
  end
end
