# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::Sources::FollowedPosts do
  subject { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe '#includes?' do
    context 'when the home feed filter passes the status' do
      before do
        allow(FeedManager.instance).to receive(:filter).with(:home, status, account).and_return(nil)
      end

      it 'returns true' do
        expect(subject.includes?(status, account)).to be true
      end
    end

    context 'when the home feed filter would exclude the status' do
      before do
        allow(FeedManager.instance).to receive(:filter).with(:home, status, account).and_return(:filter)
      end

      it 'returns false' do
        expect(subject.includes?(status, account)).to be false
      end
    end
  end
end
