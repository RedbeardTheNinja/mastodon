# frozen_string_literal: true

module CustomFeeds
  # Runs every 5 minutes. Enqueues PullSourceIngestWorker for any enabled
  # CustomFeedConfig whose pull cadence interval has elapsed since last run.
  # Uses pull_cadence_minutes + last_pulled_at on the config — no static
  # list of pull source keys required.
  class SchedulePullSourcesWorker
    include Sidekiq::Worker

    sidekiq_options queue: 'scheduler', retry: 0, lock: :until_executed, lock_ttl: 5.minutes.to_i

    def perform
      configs = CustomFeedConfig
        .enabled
        .where(
          'last_pulled_at IS NULL OR ' \
          "last_pulled_at + (pull_cadence_minutes * interval '1 minute') <= NOW()"
        )

      first_run, due = configs.partition { |c| c.last_pulled_at.nil? }

      # Configs that have never run get an immediate job so they populate on first visit.
      first_run.each { |config| PullSourceIngestWorker.perform_async(config.id) }

      # Configs due by cadence are staggered to avoid a thundering herd.
      due.each_with_index do |config, i|
        PullSourceIngestWorker.perform_in(i * 2.seconds, config.id)
      end
    end
  end
end
