# frozen_string_literal: true

module Recommendations
  module Algorithms
    class AffinityScore < Base
      DECAY_LAMBDA = 0.05
      TAG_CAP      = 5

      def self.key
        'affinity_score'
      end

      def score_batch(candidates)
        # Load all signals once, cache for the batch
        @tag_affinities     = load_signals('tag')
        @account_affinities = load_signals('account')
        @domain_affinities  = load_signals('domain')
        super
      end

      def score_one(status)
        original    = status.reblog? ? status.reblog : status
        age_hours   = (Time.current - original.created_at) / 3600.0
        time_factor = Math.exp(-DECAY_LAMBDA * age_hours)

        tag_score = original.tags.first(TAG_CAP).sum do |tag|
          @tag_affinities[tag.name.downcase].to_f
        end

        account_score = @account_affinities[original.account_id.to_s].to_f
        domain_score  = @domain_affinities[original.account.domain.to_s].to_f * 0.5

        (tag_score + account_score + domain_score) * time_factor
      end

      private

      def load_signals(signal_type)
        RecommendationSignal
          .where(account: @account, signal_type: signal_type)
          .pluck(:entity_id, :weight)
          .to_h
      end
    end
  end
end
