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
      #   sources (array, required) — [{domain:, tag:}, ...]
      #   limit_per_run (int, default 40, max MAX_LIMIT_PER_RUN)
      #
      # bucket format: "#{domain}:#{tag}"
      # fetch_candidates is called once per sources entry (per bucket).

      def fetch_candidates(_account, options = {}, since_id: nil, bucket: '')
        sources = Array(options['sources'])
        entry   = sources.find { |s| "#{s['domain']}:#{s['tag'].to_s.delete_prefix('#')}" == bucket } ||
                  sources.first
        return FetchResult.new(nil, []) unless entry

        domain = entry['domain'].to_s.strip
        tag    = entry['tag'].to_s.delete_prefix('#').strip
        limit  = options.fetch('limit_per_run', 40).to_i.clamp(1, MAX_LIMIT_PER_RUN)

        return FetchResult.new(nil, []) if domain.blank? || tag.blank?

        url    = "https://#{domain}/api/v1/timelines/tag/#{CGI.escape(tag)}"
        params = { limit: limit }
        params[:since_id] = since_id if since_id.present?

        response = HTTP.timeout(10).get(url, params: params)
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
        Array(options['sources']).filter_map do |s|
          domain = s['domain'].to_s.strip
          tag    = s['tag'].to_s.delete_prefix('#').strip
          next if domain.blank? || tag.blank?

          "#{domain}:#{tag}"
        end
      end
    end
  end
end
