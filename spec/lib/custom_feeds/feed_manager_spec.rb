# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::FeedManager do
  subject { described_class.instance }

  let(:account) { Fabricate(:account) }
  let(:list)    { Fabricate(:list, account: account) }
  let(:config)  do
    config = CustomFeedConfig.create!(account: account, list: list, enabled: true)
    CustomFeedStep.create!(custom_feed_config: config, phase: 'overflow_strategy', step_type: 'oldest_first', position: 0)
    config
  end
  let(:status) { Fabricate(:status) }

  describe '#key' do
    it 'returns the correct Redis key for a list' do
      expect(subject.key(list.id)).to eq "feed:custom:#{list.id}"
    end
  end

  describe '#push' do
    context 'when the overflow strategy allows insertion' do
      it 'adds the status id to the Redis sorted set' do
        subject.push(config, status)

        expect(redis.zscore(subject.key(list.id), status.id)).to_not be_nil
      end

      it 'uses the status id as the score' do
        subject.push(config, status)

        expect(redis.zscore(subject.key(list.id), status.id)).to eq status.id.to_f
      end

      it 'returns true' do
        expect(subject.push(config, status)).to be true
      end

      context 'when the feed exceeds MAX_ITEMS' do
        before do
          stub_const('FeedManager::MAX_ITEMS', 3)
          redis.zadd(subject.key(list.id), [[1, 1], [2, 2], [3, 3]])
        end

        it 'trims the feed to MAX_ITEMS' do
          subject.push(config, status)

          expect(redis.zcard(subject.key(list.id))).to eq FeedManager::MAX_ITEMS
        end
      end
    end
  end

  describe '#remove' do
    before { redis.zadd(subject.key(list.id), status.id, status.id) }

    it 'removes the status id from the Redis sorted set' do
      subject.remove(config, status.id)

      expect(redis.zscore(subject.key(list.id), status.id)).to be_nil
    end

    context 'when the status is not in the feed' do
      it 'does not raise an error' do
        expect { subject.remove(config, 99_999) }.to_not raise_error
      end
    end
  end

  describe '#push_and_stream' do
    it 'returns without publishing if push returns false' do
      manager = described_class.instance
      allow(manager).to receive(:push).and_return(false)
      allow(redis).to receive(:publish)

      manager.push_and_stream(config, status)

      expect(redis).to_not have_received(:publish)
    end

    it 'publishes a streaming event when push succeeds' do
      manager = described_class.instance
      allow(manager).to receive(:push).and_return(true)
      allow(redis).to receive(:publish)

      manager.push_and_stream(config, status)

      expect(redis).to have_received(:publish).with(
        "timeline:list:#{list.id}",
        anything
      )
    end
  end

  describe '#remove_and_stream' do
    before { redis.zadd(subject.key(list.id), status.id, status.id) }

    it 'removes each id and publishes a streaming delete event' do
      allow(redis).to receive(:publish).and_call_original

      subject.remove_and_stream(config, [status.id])

      expect(redis).to have_received(:publish).with(
        "timeline:list:#{list.id}",
        a_string_including('"delete"')
      ).at_least(:once)
      expect(redis.zscore(subject.key(list.id), status.id)).to be_nil
    end
  end
end
