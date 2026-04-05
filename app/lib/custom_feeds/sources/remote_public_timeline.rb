# frozen_string_literal: true

module CustomFeeds
  module Sources
    class RemotePublicTimeline < Base
      def self.key
        'remote_public_timeline'
      end

      def self.pull_source?
        true
      end

      # options keys:
      #   sources (array, required) — [{domain:, local_only:}, ...]
      #   limit_per_run (int, default 40, max 80)
      #
      # bucket = domain

      def fetch_candidates(_account, options = {}, since_id: nil, bucket: '')
        sources = Array(options['sources'])
        entry   = sources.find { |s| s['domain'].to_s.strip == bucket } ||
                  sources.first
        return FetchResult.new(nil, []) unless entry

        domain = entry['domain'].to_s.strip
        local  = entry.fetch('local_only', true)
        limit  = options.fetch('limit_per_run', 40).to_i.clamp(1, 80)

        return FetchResult.new(nil, []) if domain.blank?

        url    = "https://#{domain}/api/v1/timelines/public"
        params = { limit: limit, local: local }
        params[:since_id] = since_id if since_id.present?

        response = HTTP.timeout(10).get(url, params: params)
        return FetchResult.new(nil, []) unless response.status.success?

        raw      = JSON.parse(response.body)
        max_id   = raw.filter_map { |s| s['id'] }.max
        statuses = Chewy.strategy(:bypass) do
          raw.filter_map do |s|
            ResolveURLService.new.call(s['uri'])
          rescue
            nil
          end
        end
        FetchResult.new(max_id, statuses)
      rescue => e
        Rails.logger.warn("CustomFeeds::Sources::RemotePublicTimeline fetch failed (#{bucket}): #{e.message}")
        FetchResult.new(nil, [])
      end

      def self.buckets_for(options)
        Array(options['sources']).filter_map { |s| s['domain'].to_s.strip.presence }
      end
    end
  end
end
