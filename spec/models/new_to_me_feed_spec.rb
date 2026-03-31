# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewToMeFeed do
  subject { described_class.new(account) }

  let(:account) { Fabricate(:account) }

  describe '#get' do
    before do
      Fabricate(:status, account: account, id: 1)
      Fabricate(:status, account: account, id: 2)
      Fabricate(:status, account: account, id: 3)
    end

    context 'when the feed has entries' do
      before do
        redis.zadd(
          NewToMe::FeedManager.instance.key(account.id),
          [[3, 3], [2, 2], [1, 1]]
        )
      end

      it 'returns statuses in reverse chronological order' do
        results = subject.get(3)

        expect(results.map(&:id)).to eq [3, 2, 1]
      end

      it 'respects the limit' do
        results = subject.get(2)

        expect(results.map(&:id)).to eq [3, 2]
      end

      it 'paginates with max_id' do
        results = subject.get(3, 3)

        expect(results.map(&:id)).to eq [2, 1]
      end

      it 'paginates with since_id' do
        results = subject.get(3, nil, 1)

        expect(results.map(&:id)).to eq [3, 2]
      end

      it 'paginates with min_id (ascending from min)' do
        results = subject.get(3, nil, nil, 1)

        expect(results.map(&:id)).to eq [2, 3]
      end
    end

    context 'when the feed is empty' do
      it 'returns an empty result' do
        results = subject.get(10)

        expect(results).to be_empty
      end
    end
  end
end
