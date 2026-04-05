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
        # Load all signals in a single query and partition in Ruby
        @tag_affinities     = {}
        @account_affinities = {}
        @domain_affinities  = {}

        RecommendationSignal.where(account: @account).pluck(:signal_type, :entity_id, :weight).each do |type, entity, weight|
          case type
          when 'tag'     then @tag_affinities[entity]     = weight
          when 'account' then @account_affinities[entity] = weight
          when 'domain'  then @domain_affinities[entity]  = weight
          end
        end

        Rails.logger.debug do
          "AffinityScore: account=#{@account.id} " \
            "tags=#{@tag_affinities.size} accounts=#{@account_affinities.size} domains=#{@domain_affinities.size}"
        end

        super
      end

      def score_one(status)
        original    = status.original_status
        age_hours   = (Time.current - original.created_at) / 3600.0
        time_factor = Math.exp(-DECAY_LAMBDA * age_hours)

        tag_score = original.tags.first(TAG_CAP).sum do |tag|
          @tag_affinities[tag.name.downcase].to_f
        end

        account_score = @account_affinities[original.account_id.to_s].to_f
        # Skip domain affinity for local accounts (domain is nil/blank — all local
        # accounts share the same server so domain is not a meaningful signal).
        domain_score = if original.account.domain.present?
                         @domain_affinities[original.account.domain].to_f * 0.5
                       else
                         0.0
                       end

        (tag_score + account_score + domain_score) * time_factor
      end
    end
  end
end
