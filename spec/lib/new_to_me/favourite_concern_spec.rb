# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewToMe::FavouriteConcern do
  # The concern is included in Favourite via the initializer.
  # We test it through the Favourite model.

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe 'after a favourite is created' do
    it 'enqueues NewToMe::FeedRemoveWorker for the account and status' do
      allow(NewToMe::FeedRemoveWorker).to receive(:perform_async)

      Favourite.create!(account: account, status: status)

      expect(NewToMe::FeedRemoveWorker).to have_received(:perform_async).with(status.id, account.id)
    end
  end

  describe 'after a favourite is destroyed' do
    let!(:favourite) { Fabricate(:favourite, account: account, status: status) }

    it 'does not enqueue NewToMe::FeedRemoveWorker on destroy' do
      allow(NewToMe::FeedRemoveWorker).to receive(:perform_async)

      favourite.destroy!

      expect(NewToMe::FeedRemoveWorker).not_to have_received(:perform_async)
    end
  end
end
