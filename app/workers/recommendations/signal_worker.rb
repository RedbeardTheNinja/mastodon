# frozen_string_literal: true

module Recommendations
  class SignalWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'default', retry: 3

    def perform(interaction_type, status_id, account_id)
      account = Account.find(account_id)
      return unless CustomFeedConfig.where(account: account, feed_type: 'algorithmic').exists?(enabled: true)

      status   = Status.find(status_id)
      original = status.original_status
      weight   = Recommendations::SignalConfig.interaction_weight(interaction_type)
      return if weight.zero?

      tag_count          = 0
      text_phrase_count  = 0
      alt_phrase_count   = 0

      original.tags.each do |tag|
        upsert_signal(account, 'tag', tag.name.downcase, weight * Recommendations::SignalConfig.signal_weight('tag'))
        CustomFeeds::Metrics.record_signal(signal_type: 'tag', interaction_type: interaction_type)
        tag_count += 1
      end

      upsert_signal(account, 'account', original.account_id.to_s, weight)
      CustomFeeds::Metrics.record_signal(signal_type: 'account', interaction_type: interaction_type)

      # Only record domain signals for remote accounts — local accounts all share
      # the same server, so the domain is not a meaningful cross-account signal.
      if original.account.domain.present?
        upsert_signal(account, 'domain', original.account.domain,
                      weight * Recommendations::SignalConfig.signal_weight('domain_multiplier'))
        CustomFeeds::Metrics.record_signal(signal_type: 'domain', interaction_type: interaction_type)
      end

      # Extract keyphrases from post body
      plain_text = Nokogiri::HTML.parse(original.text.to_s).text.strip
      if plain_text.present?
        Recommendations::KeybertClient.extract(
          plain_text,
          top_n: Recommendations::SignalConfig.keybert('top_n'),
          max_ngram: Recommendations::SignalConfig.keybert('max_ngram')
        ).each do |phrase|
          upsert_signal(account, 'text_phrase', phrase,
                        weight * Recommendations::SignalConfig.signal_weight('text_phrase'))
          CustomFeeds::Metrics.record_signal(signal_type: 'text_phrase', interaction_type: interaction_type)
          text_phrase_count += 1
        end
      end

      # Extract keyphrases from media alt text
      alt_text = original.media_attachments.filter_map(&:description).join(' ').strip
      if alt_text.present?
        Recommendations::KeybertClient.extract(
          alt_text,
          top_n: Recommendations::SignalConfig.keybert('top_n'),
          max_ngram: Recommendations::SignalConfig.keybert('max_ngram')
        ).each do |phrase|
          upsert_signal(account, 'alt_text_phrase', phrase,
                        weight * Recommendations::SignalConfig.signal_weight('alt_text_phrase'))
          CustomFeeds::Metrics.record_signal(signal_type: 'alt_text_phrase', interaction_type: interaction_type)
          alt_phrase_count += 1
        end
      end

      Rails.logger.info do
        "SignalWorker: account=#{account_id} status=#{status_id} interaction=#{interaction_type} " \
          "tags=#{tag_count} text_phrases=#{text_phrase_count} alt_phrases=#{alt_phrase_count}"
      end
    rescue ActiveRecord::RecordNotFound
      true
    end

    private

    def upsert_signal(account, signal_type, entity_id, weight)
      RecommendationSignal.upsert(
        {
          account_id: account.id,
          signal_type: signal_type,
          entity_id: entity_id,
          weight: weight,
          observation_count: 1,
          last_observed_at: Time.current,
          created_at: Time.current,
          updated_at: Time.current,
        },
        on_duplicate: Arel.sql(
          'weight = recommendation_signals.weight + EXCLUDED.weight, ' \
          'observation_count = recommendation_signals.observation_count + 1, ' \
          'last_observed_at = EXCLUDED.last_observed_at, ' \
          'updated_at = EXCLUDED.updated_at'
        ),
        unique_by: :idx_rec_signals_lookup
      )
    end
  end
end
