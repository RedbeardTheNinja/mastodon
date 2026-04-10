# frozen_string_literal: true

# Stand-alone custom type collector for the prometheus_exporter server.
# Has NO Rails dependencies so it can be loaded either:
#   1. Via --type-collector flag when running a standalone prometheus_exporter server
#   2. Via require in LOCAL mode (embedded server inside Puma/Sidekiq)
#
# All custom feed metrics are sent with type: 'custom_feed' and dispatched
# internally by the 'metric' field.

require 'prometheus_exporter/server'

module Mastodon
  module PrometheusExporter
    class CustomFeedsCollector < ::PrometheusExporter::Server::TypeCollector
      def initialize
        super
        @inserts = ::PrometheusExporter::Metric::Counter.new(
          'custom_feed_inserts_total',
          'Total statuses processed by custom feed pipelines, by outcome'
        )
        @algo_candidates = ::PrometheusExporter::Metric::Counter.new(
          'custom_feed_algo_candidates_total',
          'Algorithmic feed candidate outcomes (promoted vs filtered)'
        )
        @signals = ::PrometheusExporter::Metric::Counter.new(
          'recommendation_signal_records_total',
          'Recommendation signals recorded per interaction type and signal type'
        )
        @algo_score = ::PrometheusExporter::Metric::Histogram.new(
          'custom_feed_algo_score',
          'Affinity score distribution for posts reaching the pipeline filter after score threshold',
          buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1.0, 2.0, 5.0]
        )
        @pull_source_fetched = ::PrometheusExporter::Metric::Counter.new(
          'custom_feed_pull_source_fetched_total',
          'Total posts fetched from remote pull sources per run, by feed type'
        )
        @pull_source_runs = ::PrometheusExporter::Metric::Counter.new(
          'custom_feed_pull_source_runs_total',
          'Completed pull source runs, labeled by feed type and number of fetch attempts made'
        )
        @redis_memory = ::PrometheusExporter::Metric::Gauge.new(
          'custom_feed_redis_memory_bytes',
          'Estimated Redis memory used by feed keys, by feed type'
        )
        @redis_count = ::PrometheusExporter::Metric::Gauge.new(
          'custom_feed_redis_feed_count',
          'Number of active feed keys in Redis, by feed type'
        )
        @pg_table_bytes = ::PrometheusExporter::Metric::Gauge.new(
          'custom_feed_pg_table_bytes',
          'PostgreSQL total relation size (table + indexes) for custom feed tables'
        )
      end

      def type
        'custom_feed'
      end

      def collect(obj)
        case obj['metric']
        when 'insert'
          @inserts.observe(1, 'feed_type' => obj['feed_type'], 'result' => obj['result'])
        when 'algo_candidate'
          @algo_candidates.observe(1, 'result' => obj['result'])
        when 'signal_record'
          @signals.observe(1, 'signal_type' => obj['signal_type'], 'interaction_type' => obj['interaction_type'])
        when 'algo_score'
          @algo_score.observe(obj['score'].to_f)
        when 'pull_source_fetched'
          @pull_source_fetched.observe(obj['count'].to_i, 'feed_type' => obj['feed_type'])
        when 'pull_source_run'
          @pull_source_runs.observe(1, 'feed_type' => obj['feed_type'], 'attempts' => obj['attempts'].to_s)
        when 'redis_memory'
          @redis_memory.observe(obj['value'].to_i, 'feed_type' => obj['feed_type'])
        when 'redis_count'
          @redis_count.observe(obj['value'].to_i, 'feed_type' => obj['feed_type'])
        when 'pg_table_bytes'
          @pg_table_bytes.observe(obj['value'].to_i, 'table_name' => obj['table'])
        end
      end

      def metrics
        [@inserts, @algo_candidates, @signals, @algo_score,
         @pull_source_fetched, @pull_source_runs,
         @redis_memory, @redis_count, @pg_table_bytes]
      end
    end
  end
end
