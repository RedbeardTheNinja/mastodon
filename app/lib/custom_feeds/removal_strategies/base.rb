# frozen_string_literal: true

module CustomFeeds
  module RemovalStrategies
    class Base
      REGISTRY = {} # rubocop:disable Style/MutableConstant

      def self.key
        raise NotImplementedError
      end

      def self.register!
        REGISTRY[key] = self
      end

      # Return true to remove the status from the feed after this interaction.
      # @param [String] interaction_type 'favourite' | 'reblog' | 'reply'
      # @param [Hash] options
      # @return [Boolean]
      def remove_on?(interaction_type, options = {})
        raise NotImplementedError
      end
    end
  end
end
