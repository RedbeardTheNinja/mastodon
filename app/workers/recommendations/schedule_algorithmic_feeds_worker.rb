# frozen_string_literal: true

module Recommendations
  class ScheduleAlgorithmicFeedsWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'scheduler', retry: 0

    def perform
      CustomFeedConfig
        .where(feed_type: 'algorithmic', enabled: true)
        .where(
          'last_pulled_at IS NULL OR ' \
          "last_pulled_at + (pull_cadence_minutes * interval '1 minute') <= NOW()"
        )
        .find_each { |config| AlgorithmicFeedWorker.perform_async(config.id) }
    end
  end
end
