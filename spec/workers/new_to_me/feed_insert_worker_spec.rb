# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewToMe::FeedInsertWorker do
  subject { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe '#perform' do
    let(:ntm_manager) { instance_double(NewToMe::FeedManager, push: nil) }

    before do
      allow(NewToMe::FeedManager).to receive(:instance).and_return(ntm_manager)
    end

    context 'when records are missing' do
      it 'returns true and skips push when status is missing' do
        result = subject.perform(nil, account.id)

        expect(result).to be true
        expect(ntm_manager).to_not have_received(:push)
      end

      it 'returns true and skips push when account is missing' do
        result = subject.perform(status.id, nil)

        expect(result).to be true
        expect(ntm_manager).to_not have_received(:push)
      end
    end

    context 'when records exist' do
      context 'when the user has signed in recently' do
        before { account.user.update!(current_sign_in_at: 1.hour.ago) }

        context 'when the home feed would not filter the status' do
          before do
            feed_manager = instance_double(FeedManager, filter: nil)
            allow(FeedManager).to receive(:instance).and_return(feed_manager)
          end

          it 'calls push on the NewToMe::FeedManager' do
            subject.perform(status.id, account.id)

            expect(ntm_manager).to have_received(:push).with(account, status)
          end
        end

        context 'when the home feed would filter the status' do
          before do
            feed_manager = instance_double(FeedManager, filter: :filter)
            allow(FeedManager).to receive(:instance).and_return(feed_manager)
          end

          it 'does not push to the NewToMe feed' do
            subject.perform(status.id, account.id)

            expect(ntm_manager).to_not have_received(:push)
          end
        end
      end

      context 'when the user has not signed in recently' do
        before do
          account.user.update!(current_sign_in_at: (User::Activity::ACTIVE_DURATION + 1.day).ago)
        end

        it 'does not push to the NewToMe feed' do
          subject.perform(status.id, account.id)

          expect(ntm_manager).to_not have_received(:push)
        end
      end
    end
  end
end
