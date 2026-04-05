# frozen_string_literal: true

module CustomFeeds
  module Filters
    # Excludes posts that contain any of the user-configured blocked tags.
    # Tags are compared case-insensitively after stripping the leading #.
    class BlockedTags < Base
      def self.key
        'blocked_tags'
      end

      # options keys:
      #   tags (array of strings, required) — e.g. ["nsfw", "politics"]

      # @param [Status]  status
      # @param [Account] _account
      # @param [Hash]    options
      # @return [Boolean]
      def exclude?(status, _account, options = {})
        blocked = Array(options['tags']).map { |t| t.to_s.delete_prefix('#').downcase }.presence
        return false if blocked.nil?

        original = status.original_status
        status_tags = original.tags.pluck(:name).map(&:downcase)
        (status_tags & blocked).any?
      end
    end
  end
end
