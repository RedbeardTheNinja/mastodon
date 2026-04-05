# frozen_string_literal: true

require 'singleton'

module CustomFeeds
  class FeedManager
    include Singleton
    include Redisable

    # Redis key for a given list's custom feed.
    # @param [Integer] list_id
    # @return [String]
    def key(list_id)
      "feed:custom:#{list_id}"
    end

    # Redis key for the insertion-time hash: status_id (string) → unix timestamp.
    # Used by TimeBasedRemovalWorker to track how long each post has been in the feed.
    # @param [Integer] list_id
    # @return [String]
    def inserted_at_key(list_id)
      "feed:custom:#{list_id}:inserted_at"
    end

    # Redis key for the algorithmic pending queue.
    # Sorted set: score = unix arrival timestamp, member = status_id.
    # @param [Integer] list_id
    # @return [String]
    def pending_key(list_id)
      "feed:algo:#{list_id}:pending"
    end

    # Add a status to the algorithmic pending queue if not already present.
    # Caps the queue at FeedManager::MAX_ITEMS; evicts the oldest entry on overflow.
    # @param [CustomFeedConfig] config
    # @param [Status] status
    # @return [void]
    def enqueue_candidate(config, status)
      pkey = pending_key(config.list_id)
      max  = ::FeedManager::MAX_ITEMS

      # Deduplicate
      if redis.zscore(pkey, status.id)
        Rails.logger.debug { "CustomFeeds: status #{status.id} already in pending queue for list #{config.list_id}, skipping" }
        return
      end

      if redis.zcard(pkey) >= max
        Rails.logger.debug { "CustomFeeds: pending queue for list #{config.list_id} at capacity, evicting oldest" }
        redis.zpopmin(pkey)
      end

      redis.zadd(pkey, Time.now.to_i, status.id)
    end

    # Dequeue up to `limit` candidates from the pending queue that are younger
    # than `max_age_hours`. Older entries are removed without scoring.
    # Returns resolved Status records (skips IDs that no longer exist in the DB).
    # @param [Integer] list_id
    # @param [Integer] limit
    # @param [Integer] max_age_hours
    # @return [Array<Status>]
    def dequeue_pending(list_id, limit:, max_age_hours:)
      pkey   = pending_key(list_id)
      cutoff = Time.now.to_i - (max_age_hours * 3600)

      # Remove entries older than the max age
      redis.zremrangebyscore(pkey, '-inf', cutoff)

      # Pop the oldest `limit` entries from the queue (lowest score first)
      entries = redis.zpopmin(pkey, limit)
      ids     = entries.map { |member, _score| member.to_i }

      return [] if ids.empty?

      Status.where(id: ids).to_a
    end

    # Add a status to a custom feed, respecting the config's overflow strategy.
    # Returns false without inserting if the overflow strategy blocks capacity.
    # @param [CustomFeedConfig] config
    # @param [Status] status
    # @return [Boolean]
    def push(config, status)
      overflow = overflow_strategy_for(config)
      feed_key = key(config.list_id)
      max      = ::FeedManager::MAX_ITEMS

      if overflow.at_capacity?(redis.zcard(feed_key), max)
        Rails.logger.debug do
          "CustomFeeds: feed #{config.list_id} at capacity (overflow=#{overflow.class.name}), dropping status #{status.id}"
        end
        return false
      end

      redis.zadd(feed_key, status.id, status.id)
      redis.hset(inserted_at_key(config.list_id), status.id, Time.now.to_i)
      overflow.trim(redis, feed_key, max)
      true
    end

    # Delete all Redis keys associated with a custom feed (feed data,
    # insertion timestamps, algorithmic pending queue).
    # Called when a CustomFeedConfig is destroyed.
    # @param [Integer] list_id
    # @return [void]
    def delete_feed(list_id)
      redis.del(key(list_id), inserted_at_key(list_id), pending_key(list_id))
      Rails.logger.info("CustomFeeds: deleted Redis keys for list #{list_id}")
    end

    # Remove a single status ID from a custom feed.
    # @param [CustomFeedConfig] config
    # @param [Integer] status_id
    # @return [void]
    def remove(config, status_id)
      redis.zrem(key(config.list_id), status_id)
      redis.hdel(inserted_at_key(config.list_id), status_id)
    end

    # Push a status and publish a streaming update event on the list channel.
    # @param [CustomFeedConfig] config
    # @param [Status] status
    # @return [void]
    def push_and_stream(config, status)
      return unless push(config, status)

      redis.publish(
        "timeline:list:#{config.list_id}",
        Oj.dump(event: :update, payload: InlineRenderer.render(status, nil, :status))
      )
    end

    # Remove status IDs from a custom feed and publish streaming delete events.
    # @param [CustomFeedConfig] config
    # @param [Array<Integer>] ids
    # @return [void]
    def remove_and_stream(config, ids)
      channel = "timeline:list:#{config.list_id}"
      ids.each do |id|
        remove(config, id)
        # Use 'feeds.remove' instead of 'delete' so the frontend only removes
        # the post from this specific list timeline rather than all timelines.
        # The standard 'delete' event calls deleteFromTimelines which purges
        # the status from every feed in the Redux store (home, public, etc.).
        redis.publish(channel, Oj.dump(event: 'feeds.remove', payload: id.to_s))
      end
    end

    private

    def overflow_strategy_for(config)
      step = config.steps_for('overflow_strategy').first
      klass = step ? OverflowStrategies::Base.registry[step.step_type] : nil
      (klass || OverflowStrategies::OldestFirst).new
    end
  end
end
