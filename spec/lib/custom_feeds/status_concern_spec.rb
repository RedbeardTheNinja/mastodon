# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::StatusConcern do
  let(:local_account)  { Fabricate(:account) }
  let(:remote_account) { Fabricate(:account, domain: 'example.com') }
  let(:original)       { Fabricate(:status) }

  describe 'after_create_commit callback' do
    before do
      allow(CustomFeeds::FeedRemoveWorker).to receive(:perform_async)
    end

    context 'when a local account creates a reblog' do
      it 'enqueues FeedRemoveWorker with reblog_of_id and interaction_type reblog' do
        Fabricate(:status, account: local_account, reblog: original)

        expect(CustomFeeds::FeedRemoveWorker).to have_received(:perform_async)
          .with(original.id, local_account.id, 'reblog')
      end
    end

    context 'when a local account creates a reply' do
      it 'enqueues FeedRemoveWorker with in_reply_to_id and interaction_type reply' do
        Fabricate(
          :status,
          account: local_account,
          in_reply_to_id: original.id,
          in_reply_to_account_id: original.account_id
        )

        expect(CustomFeeds::FeedRemoveWorker).to have_received(:perform_async)
          .with(original.id, local_account.id, 'reply')
      end
    end

    context 'when a remote account creates a reblog' do
      it 'does not enqueue FeedRemoveWorker' do
        Fabricate(:status, account: remote_account, reblog: original)

        expect(CustomFeeds::FeedRemoveWorker).to_not have_received(:perform_async)
      end
    end

    context 'when a local account creates a plain status' do
      it 'does not enqueue FeedRemoveWorker' do
        Fabricate(:status, account: local_account)

        expect(CustomFeeds::FeedRemoveWorker).to_not have_received(:perform_async)
      end
    end
  end
end
