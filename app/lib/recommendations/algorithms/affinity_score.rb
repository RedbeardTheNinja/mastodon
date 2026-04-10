# frozen_string_literal: true

module Recommendations
  module Algorithms
    class AffinityScore < Base
      def self.key
        'affinity_score'
      end

      def score_batch(candidates)
        # Load all signals in a single query and partition in Ruby
        @tag_affinities     = {}
        @account_affinities = {}
        @domain_affinities  = {}
        raw_text_phrases    = []
        raw_alt_phrases     = []

        RecommendationSignal.where(account: @account).pluck(:signal_type, :entity_id, :weight).each do |type, entity, weight|
          case type
          when 'tag'             then @tag_affinities[entity]     = weight
          when 'account'         then @account_affinities[entity] = weight
          when 'domain'          then @domain_affinities[entity]  = weight
          when 'text_phrase'     then raw_text_phrases << [entity, weight]
          when 'alt_text_phrase' then raw_alt_phrases  << [entity, weight]
          end
        end

        # Cache config values once per batch to avoid repeated hash lookups per post
        @decay_lambda       = Recommendations::SignalConfig.scoring('decay_lambda') || 0.05
        @tag_cap            = Recommendations::SignalConfig.scoring('tag_cap') || 5
        @domain_multiplier  = Recommendations::SignalConfig.scoring('domain_score_multiplier') || 0.5

        # Cap phrase affinities by weight descending (done once per batch, not per post)
        text_cap = Recommendations::SignalConfig.scoring('text_phrase_cap') || 5
        alt_cap  = Recommendations::SignalConfig.scoring('alt_text_phrase_cap') || 3
        @text_phrase_affinities = raw_text_phrases.sort_by { |_, w| -w }.first(text_cap).to_h
        @alt_text_phrase_affinities = raw_alt_phrases.sort_by { |_, w| -w }.first(alt_cap).to_h

        Rails.logger.debug do
          "AffinityScore: account=#{@account.id} " \
            "tags=#{@tag_affinities.size} accounts=#{@account_affinities.size} " \
            "domains=#{@domain_affinities.size} text_phrases=#{@text_phrase_affinities.size} " \
            "alt_phrases=#{@alt_text_phrase_affinities.size}"
        end

        super
      end

      def score_one(status)
        original    = status.original_status
        age_hours   = (Time.current - original.created_at) / 3600.0
        time_factor = Math.exp(-@decay_lambda * age_hours)

        tag_score = original.tags.first(@tag_cap).sum do |tag|
          @tag_affinities[tag.name.downcase].to_f
        end

        account_score = @account_affinities[original.account_id.to_s].to_f
        # Skip domain affinity for local accounts (domain is nil/blank — all local
        # accounts share the same server so domain is not a meaningful signal).
        domain_score = if original.account.domain.present?
                         @domain_affinities[original.account.domain].to_f * @domain_multiplier
                       else
                         0.0
                       end

        post_words = Nokogiri::HTML.parse(original.text.to_s).text.downcase
        text_score = @text_phrase_affinities.sum { |phrase, w| post_words.include?(phrase) ? w : 0.0 }

        alt_words  = original.media_attachments.filter_map(&:description).join(' ').downcase
        alt_score  = @alt_text_phrase_affinities.sum { |phrase, w| alt_words.include?(phrase) ? w : 0.0 }

        (tag_score + account_score + domain_score + text_score + alt_score) * time_factor
      end
    end
  end
end
