# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::OverflowStrategies::OldestFirst do
  subject { described_class.new }

  describe '#at_capacity?' do
    it 'always returns false regardless of count' do
      expect(subject.at_capacity?(0, 800)).to be false
      expect(subject.at_capacity?(800, 800)).to be false
      expect(subject.at_capacity?(1000, 800)).to be false
    end
  end

  describe '#trim' do
    include Redisable

    let(:feed_key) { 'feed:custom:trim_test' }

    before do
      stub_const('FeedManager::MAX_ITEMS', 3)
      redis.zadd(feed_key, [[1, 1], [2, 2], [3, 3], [4, 4]])
    end

    after do
      redis.del(feed_key)
    end

    it 'removes the oldest (lowest-score) entries down to max_items' do
      subject.trim(redis, feed_key, 3)

      remaining = redis.zrange(feed_key, 0, -1, with_scores: true).map { |id, _| id.to_i }
      expect(remaining).to contain_exactly(2, 3, 4)
    end

    it 'does nothing when the feed is within max_items' do
      subject.trim(redis, feed_key, 10)

      expect(redis.zcard(feed_key)).to eq 4
    end
  end
end
