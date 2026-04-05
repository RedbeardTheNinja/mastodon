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

    # Add a status to a custom feed, respecting the config's overflow strategy.
    # Returns false without inserting if the overflow strategy blocks capacity.
    # @param [CustomFeedConfig] config
    # @param [Status] status
    # @return [Boolean]
    def push(config, status)
      overflow = overflow_strategy_for(config)
      feed_key = key(config.list_id)
      max      = ::FeedManager::MAX_ITEMS

      return false if overflow.at_capacity?(redis.zcard(feed_key), max)

      redis.zadd(feed_key, status.id, status.id)
      overflow.trim(redis, feed_key, max)
      true
    end

    # Remove a single status ID from a custom feed.
    # @param [CustomFeedConfig] config
    # @param [Integer] status_id
    # @return [void]
    def remove(config, status_id)
      redis.zrem(key(config.list_id), status_id)
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
        redis.publish(channel, Oj.dump(event: :delete, payload: id.to_s))
      end
    end

    private

    def overflow_strategy_for(config)
      step = config.steps_for('overflow_strategy').first
      klass = step ? OverflowStrategies::Base::REGISTRY[step.step_type] : nil
      (klass || OverflowStrategies::OldestFirst).new
    end
  end
end
