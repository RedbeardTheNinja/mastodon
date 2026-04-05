# frozen_string_literal: true

module CustomFeeds
  # Thin client-side helper for emitting custom feed metrics to the
  # prometheus_exporter collector.  All calls are no-ops when the exporter
  # is not loaded or the client is not connected — metrics must never raise.
  module Metrics
    def self.record_insert(feed_type:, result:)
      send_metric(metric: 'insert', feed_type: feed_type, result: result)
    end

    def self.record_algo_candidate(result:)
      send_metric(metric: 'algo_candidate', result: result)
    end

    def self.record_signal(signal_type:, interaction_type:)
      send_metric(metric: 'signal_record', signal_type: signal_type, interaction_type: interaction_type)
    end

    def self.record_redis_gauge(feed_type:, memory_bytes:, key_count:)
      send_metric(metric: 'redis_memory', feed_type: feed_type, value: memory_bytes)
      send_metric(metric: 'redis_count',  feed_type: feed_type, value: key_count)
    end

    def self.record_pg_table(table:, bytes:)
      send_metric(metric: 'pg_table_bytes', table: table, value: bytes)
    end

    # --------------------------------------------------------------------------

    def self.send_metric(payload)
      return unless enabled?

      ::PrometheusExporter::Client.default.send_json(payload.merge(type: 'custom_feed'))
    rescue
      # Intentionally swallowed — telemetry must not affect application flow
    end
    private_class_method :send_metric

    def self.enabled?
      defined?(::PrometheusExporter::Client) &&
        ::PrometheusExporter::Client.default
    end
    private_class_method :enabled?
  end
end
