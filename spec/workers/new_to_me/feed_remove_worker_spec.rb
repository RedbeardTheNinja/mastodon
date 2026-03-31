# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewToMe::FeedRemoveWorker do
  subject { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe '#perform' do
    let(:ntm_manager) { instance_double(NewToMe::FeedManager, remove: nil) }

    before do
      allow(NewToMe::FeedManager).to receive(:instance).and_return(ntm_manager)
    end

    context 'when records are missing' do
      it 'returns true and skips remove when account is missing' do
        result = subject.perform(status.id, nil)

        expect(result).to be true
        expect(ntm_manager).to_not have_received(:remove)
      end
    end

    context 'when records exist' do
      it 'calls remove on the NewToMe::FeedManager' do
        subject.perform(status.id, account.id)

        expect(ntm_manager).to have_received(:remove).with(account, status.id)
      end
    end
  end
end
