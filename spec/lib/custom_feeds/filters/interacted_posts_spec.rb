# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::Filters::InteractedPosts do
  subject { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe '#exclude?' do
    context 'when the account has not interacted with the status' do
      it 'returns false' do
        expect(subject.exclude?(status, account)).to be false
      end
    end

    context 'when the account has favourited the status' do
      before { Fabricate(:favourite, account: account, status: status) }

      it 'returns true' do
        expect(subject.exclude?(status, account)).to be true
      end
    end

    context 'when the account has reblogged the status' do
      before { Fabricate(:status, account: account, reblog: status) }

      it 'returns true' do
        expect(subject.exclude?(status, account)).to be true
      end
    end

    context 'when the account has replied to the status' do
      before do
        Fabricate(:status, account: account, in_reply_to_id: status.id, in_reply_to_account_id: status.account_id)
      end

      it 'returns true' do
        expect(subject.exclude?(status, account)).to be true
      end
    end

    context 'when the status is a reblog and the account has favourited the original' do
      let(:original) { Fabricate(:status) }
      let(:reblog)   { Fabricate(:status, reblog: original) }

      before { Fabricate(:favourite, account: account, status: original) }

      it 'returns true (resolves reblog to original before checking)' do
        expect(subject.exclude?(reblog, account)).to be true
      end
    end
  end
end
