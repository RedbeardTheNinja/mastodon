# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeedsFeed do
  subject { described_class.new(list) }

  let(:account) { Fabricate(:account) }
  let(:list)    { Fabricate(:list, account: account) }

  describe '#get' do
    let(:statuses) { Fabricate.times(3, :status) }

    before do
      statuses.each do |status|
        redis.zadd(CustomFeeds::FeedManager.instance.key(list.id), status.id, status.id)
      end
    end

    after do
      redis.del(CustomFeeds::FeedManager.instance.key(list.id))
    end

    it 'reads from feed:custom:{list_id}' do
      result = subject.get(10)
      expect(result.map(&:id)).to match_array(statuses.map(&:id))
    end

    it 'paginates with max_id' do
      sorted = statuses.sort_by(&:id)
      result = subject.get(10, sorted.last.id)
      expect(result.map(&:id)).to_not include(sorted.last.id)
    end
  end
end
