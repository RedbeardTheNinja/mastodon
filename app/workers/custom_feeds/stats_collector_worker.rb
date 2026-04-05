# frozen_string_literal: true

module CustomFeeds
  # Samples Redis memory and key counts for all feed types, plus PostgreSQL
  # table sizes for custom feed tables.  Runs every 5 minutes via sidekiq-scheduler.
  # Emits gauges to prometheus_exporter so Prometheus can track feed storage cost
  # over time and compare it against home feed usage as a baseline.
  #
  # Redis scanning uses SCAN rather than KEYS to avoid blocking on large instances.
  class StatsCollectorWorker
    include Sidekiq::Worker
    include Redisable

    sidekiq_options queue: 'scheduler', retry: false

    # Tables to measure; includes indexes via pg_total_relation_size.
    PG_TABLES = %w(
      custom_feed_configs
      custom_feed_steps
      custom_feed_pull_cursors
      recommendation_signals
    ).freeze

    def perform
      return unless CustomFeeds::Metrics.send(:enabled?)

      collect_redis_stats
      collect_pg_stats
    end

    private

    def collect_redis_stats
      {
        'home' => { pattern: 'feed:home:*', exclude: nil },
        'standard' => { pattern: 'feed:custom:*', exclude: ':inserted_at' },
        'algorithmic_pending' => { pattern: 'feed:algo:*:pending', exclude: nil },
      }.each do |feed_type, spec|
        keys = scan_keys(spec[:pattern])
        keys.reject! { |k| k.end_with?(spec[:exclude]) } if spec[:exclude]

        memory_bytes = keys.sum { |k| redis.call('MEMORY', 'USAGE', k) || 0 }
        CustomFeeds::Metrics.record_redis_gauge(
          feed_type: feed_type,
          memory_bytes: memory_bytes,
          key_count: keys.size
        )
      end
    end

    def collect_pg_stats
      conn = ActiveRecord::Base.connection
      PG_TABLES.each do |table|
        result = conn.execute(
          ActiveRecord::Base.sanitize_sql_array(
            ['SELECT pg_total_relation_size(?) AS bytes', table]
          )
        ).first
        CustomFeeds::Metrics.record_pg_table(table: table, bytes: result['bytes'].to_i)
      end
    rescue ActiveRecord::StatementInvalid
      # Table may not exist yet during a fresh migration run
    end

    # Non-blocking key scan using SCAN cursor iteration.
    def scan_keys(pattern)
      keys   = []
      cursor = '0'
      loop do
        cursor, batch = redis.scan(cursor, match: pattern, count: 500)
        keys.concat(batch)
        break if cursor == '0'
      end
      keys
    end
  end
end
