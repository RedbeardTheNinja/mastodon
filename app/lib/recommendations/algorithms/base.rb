# frozen_string_literal: true

module Recommendations
  module Algorithms
    class Base
      include CustomFeeds::Registerable

      # @param [Account] account — the account who owns the feed
      def initialize(account)
        @account = account
      end

      # Score a batch of candidates. Returns [{status:, score: Float}] sorted
      # descending by score. Subclasses can override for batch efficiency.
      # @param [Array<Status>] candidates
      # @return [Array<{status: Status, score: Float}>]
      def score_batch(candidates)
        candidates
          .map { |s| { status: s, score: score_one(s) } }
          .sort_by { |r| -r[:score] }
      end

      # Score a single status.
      # @param [Status] status
      # @return [Float]
      def score_one(_status)
        0.0
      end
    end
  end
end
