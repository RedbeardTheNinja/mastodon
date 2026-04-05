# frozen_string_literal: true

module Recommendations
  class SignalWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'default', retry: 3

    WEIGHTS = {
      'reblog' => 2.0,
      'reply' => 2.0,
      'favourite' => 0.5,
    }.freeze

    DOMAIN_MULTIPLIER = 0.5

    def perform(interaction_type, status_id, account_id)
      account = Account.find(account_id)
      return unless CustomFeedConfig.where(account: account, feed_type: 'algorithmic').exists?(enabled: true)

      status   = Status.find(status_id)
      original = status.reblog? ? status.reblog : status
      weight   = WEIGHTS.fetch(interaction_type, 0.0)
      return if weight.zero?

      original.tags.each do |tag|
        upsert_signal(account, 'tag', tag.name.downcase, weight)
      end

      upsert_signal(account, 'account', original.account_id.to_s, weight)
      # Only record domain signals for remote accounts — local accounts all share
      # the same server, so the domain is not a meaningful cross-account signal.
      upsert_signal(account, 'domain', original.account.domain, weight * DOMAIN_MULTIPLIER) if original.account.domain.present?
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
