# frozen_string_literal: true

module CustomFeeds
  module Sources
    class RemoteTagTimeline < Base
      def self.key
        'remote_tag_timeline'
      end

      def self.pull_source?
        true
      end

      # options keys:
      #   tags    (array, required) — list of hashtags (with or without leading #)
      #   domains (array, required) — list of remote instance domains
      #   limit_per_run (int, default 40, max MAX_LIMIT_PER_RUN)
      #
      # bucket format: "#{domain}:#{tag}"
      # fetch_candidates is called once per bucket (cross-product of domains × tags).

      def fetch_candidates(_account, options = {}, since_id: nil, bucket: '')
        domain, tag = bucket.split(':', 2)
        domain = domain.to_s.strip
        tag    = tag.to_s.strip
        limit  = options.fetch('limit_per_run', 40).to_i.clamp(1, MAX_LIMIT_PER_RUN)

        return FetchResult.new(nil, []) if domain.blank? || tag.blank?

        url    = "https://#{domain}/api/v1/timelines/tag/#{CGI.escape(tag)}"
        params = { limit: limit }
        params[:since_id] = since_id if since_id.present?

        response = HTTP.timeout(20).get(url, params: params)
        return FetchResult.new(nil, []) unless response.status.success?

        raw      = JSON.parse(response.body)
        max_id   = raw.filter_map { |s| s['id'] }.max
        uris     = raw.filter_map { |s| s['uri'] }
        statuses = resolve_uris(uris)
        FetchResult.new(max_id, statuses)
      rescue => e
        Rails.logger.warn("CustomFeeds::Sources::RemoteTagTimeline fetch failed (#{bucket}): #{e.message}")
        FetchResult.new(nil, [])
      end

      def self.buckets_for(options)
        tags    = Array(options['tags']).filter_map { |t| t.to_s.delete_prefix('#').strip.presence }
        domains = Array(options['domains']).filter_map { |d| d.to_s.strip.presence }

        domains.flat_map { |domain| tags.map { |tag| "#{domain}:#{tag}" } }
      end
    end
  end
end
