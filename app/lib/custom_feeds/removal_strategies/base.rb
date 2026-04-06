# frozen_string_literal: true

module CustomFeeds
  module RemovalStrategies
    class Base
      include CustomFeeds::Registerable

      # Return true to remove the status from the feed after this interaction.
      # @param [String] interaction_type 'favourite' | 'reblog' | 'reply'
      # @param [Hash] options
      # @return [Boolean]
      def remove_on?(interaction_type, options = {})
        raise NotImplementedError
      end

      # Seconds to wait before actually removing the status. 0 = immediate.
      # @param [String] _interaction_type
      # @param [Hash] _options
      # @return [Integer]
      def delay_for(_interaction_type, _options = {})
        0
      end
    end
  end
end
