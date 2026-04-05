# frozen_string_literal: true

module CustomFeeds
  module Sources
    class Base
      include CustomFeeds::Registerable

      # Returned by fetch_candidates.
      # max_remote_id — the highest ID seen in the raw API response (nil if none);
      #                 used to advance the cursor even when no statuses resolve.
      # statuses      — array of resolved Status records ready to push into the feed.
      FetchResult = Struct.new(:max_remote_id, :statuses)

      # Override to true for sources that run on a schedule (not home-feed delivery).
      def self.pull_source?
        false
      end

      # Push source interface — called by Pipeline#include? via FeedInsertWorker.
      # @param [Status]  status
      # @param [Account] account
      # @param [Hash]    options  step.options
      # @return [Boolean]
      def includes?(status, account, options = {})
        raise NotImplementedError
      end

      # Pull source interface — called by PullSourceIngestWorker per source step.
      # Returns a FetchResult with the raw API max ID and resolved Status records.
      # The worker uses max_remote_id to advance the cursor regardless of whether
      # any statuses resolve (preventing re-fetch of already-seen posts).
      # @param [Account] _account
      # @param [Hash]    options   step.options
      # @param [String]  since_id  cursor from previous run (may be nil)
      # @param [String]  bucket    identifies which sub-source this call is for
      # @return [FetchResult]
      def fetch_candidates(_account, options = {}, since_id: nil, bucket: '')
        raise NotImplementedError
      end

      # Returns all bucket strings for this step's options.
      # Pull sources that cover multiple sub-sources (e.g. multiple domains) must override.
      # @param [Hash] _options  step.options
      # @return [Array<String>]
      def self.buckets_for(_options)
        ['']
      end

      private

      # Resolve a list of remote URIs to local Status records.
      # Checks the local database first to avoid unnecessary HTTP round-trips and
      # to prevent distribution side-effects (home feed insertion via DistributionWorker)
      # for statuses we have already fetched. Truly new statuses are resolved via
      # ActivityPub and will be distributed normally to local followers.
      # @param [Array<String>] uris
      # @return [Array<Status>]
      def resolve_uris(uris)
        Chewy.strategy(:bypass) do
          uris.filter_map do |uri|
            Status.find_by(uri: uri) || ResolveURLService.new.call(uri)
          rescue ActivityPub::FetchRemoteActorService::Error,
                 Mastodon::UnexpectedResponseError,
                 HTTP::Error,
                 OpenSSL::SSL::SSLError => e
            Rails.logger.debug { "CustomFeeds: could not resolve #{uri}: #{e.message}" }
            nil
          end
        end
      end
    end
  end
end
