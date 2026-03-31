# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewToMe::StatusConcern do
  # The concern is included in Status via the initializer.
  # We test it through the Status model.

  let(:local_account) { Fabricate(:account) }
  let(:original_status) { Fabricate(:status) }

  before do
    allow(NewToMe::FeedRemoveWorker).to receive(:perform_async)
  end

  describe 'when a local reblog is created' do
    it 'enqueues NewToMe::FeedRemoveWorker for the reblogger and the original status' do
      Fabricate(:status, account: local_account, reblog: original_status)

      expect(NewToMe::FeedRemoveWorker).to have_received(:perform_async)
        .with(original_status.id, local_account.id)
    end
  end

  describe 'when a local reply is created' do
    it 'enqueues NewToMe::FeedRemoveWorker for the replier and the parent status' do
      Fabricate(:status,
                account: local_account,
                in_reply_to_id: original_status.id,
                in_reply_to_account_id: original_status.account_id,
                thread: original_status)

      expect(NewToMe::FeedRemoveWorker).to have_received(:perform_async)
        .with(original_status.id, local_account.id)
    end
  end

  describe 'when a regular (non-reblog, non-reply) local status is created' do
    it 'does not enqueue NewToMe::FeedRemoveWorker' do
      Fabricate(:status, account: local_account)

      expect(NewToMe::FeedRemoveWorker).not_to have_received(:perform_async)
    end
  end

  describe 'when a remote account reblogs' do
    let(:remote_account) { Fabricate(:account, domain: 'example.com') }

    it 'does not enqueue NewToMe::FeedRemoveWorker' do
      Fabricate(:status, account: remote_account, reblog: original_status)

      expect(NewToMe::FeedRemoveWorker).not_to have_received(:perform_async)
    end
  end

  describe 'when a remote account replies' do
    let(:remote_account) { Fabricate(:account, domain: 'example.com') }

    it 'does not enqueue NewToMe::FeedRemoveWorker' do
      Fabricate(:status,
                account: remote_account,
                in_reply_to_id: original_status.id,
                in_reply_to_account_id: original_status.account_id,
                thread: original_status)

      expect(NewToMe::FeedRemoveWorker).not_to have_received(:perform_async)
    end
  end
end
