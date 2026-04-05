# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::FavouriteConcern do
  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe 'after_create_commit callback' do
    before do
      allow(CustomFeeds::FeedRemoveWorker).to receive(:perform_async)
    end

    it 'enqueues FeedRemoveWorker with interaction_type favourite' do
      Fabricate(:favourite, account: account, status: status)

      expect(CustomFeeds::FeedRemoveWorker).to have_received(:perform_async)
        .with(status.id, account.id, 'favourite')
    end

    context 'when the favourite is for a reblog' do
      let(:reblog) { Fabricate(:status, reblog: status) }

      it 'passes the original status_id (Favourite normalises to original)' do
        Fabricate(:favourite, account: account, status: reblog)

        # Favourite model normalises status_id to original before save
        expect(CustomFeeds::FeedRemoveWorker).to have_received(:perform_async)
          .with(status.id, account.id, 'favourite')
      end
    end
  end
end
