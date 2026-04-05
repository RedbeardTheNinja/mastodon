# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::FeedInsertWorker do
  subject { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }
  let(:list)    { Fabricate(:list, account: account) }

  let(:config) do
    c = CustomFeedConfig.create!(account: account, list: list, enabled: true)
    CustomFeedStep.create!(custom_feed_config: c, phase: 'source', step_type: 'followed_posts', position: 0)
    c
  end

  let(:cf_manager) { instance_double(CustomFeeds::FeedManager, push_and_stream: nil) }

  before do
    config # ensure it exists
    allow(CustomFeeds::FeedManager).to receive(:instance).and_return(cf_manager)
  end

  describe '#perform' do
    context 'when records are missing' do
      it 'returns true and skips push when status is missing' do
        result = subject.perform(nil, account.id)
        expect(result).to be true
        expect(cf_manager).to_not have_received(:push_and_stream)
      end

      it 'returns true and skips push when account is missing' do
        result = subject.perform(status.id, nil)
        expect(result).to be true
        expect(cf_manager).to_not have_received(:push_and_stream)
      end
    end

    context 'when the user has not signed in recently' do
      before { account.user.update!(current_sign_in_at: (User::Activity::ACTIVE_DURATION + 1.day).ago) }

      it 'does not push to any custom feed' do
        subject.perform(status.id, account.id)
        expect(cf_manager).to_not have_received(:push_and_stream)
      end
    end

    context 'when the user has signed in recently' do
      before { account.user.update!(current_sign_in_at: 1.hour.ago) }

      context 'when the home feed filter would filter the status' do
        before do
          feed_manager = instance_double(FeedManager, filter: :filter)
          allow(FeedManager).to receive(:instance).and_return(feed_manager)
        end

        it 'does not push to any custom feed' do
          subject.perform(status.id, account.id)
          expect(cf_manager).to_not have_received(:push_and_stream)
        end
      end

      context 'when the pipeline includes the status' do
        before do
          feed_manager = instance_double(FeedManager, filter: nil)
          allow(FeedManager).to receive(:instance).and_return(feed_manager)

          pipeline = instance_double(CustomFeeds::Pipeline, include?: true)
          allow(CustomFeeds::Pipeline).to receive(:new).and_return(pipeline)
        end

        it 'calls push_and_stream on the custom feed manager' do
          subject.perform(status.id, account.id)
          expect(cf_manager).to have_received(:push_and_stream).with(config, status)
        end
      end

      context 'when the pipeline excludes the status' do
        before do
          feed_manager = instance_double(FeedManager, filter: nil)
          allow(FeedManager).to receive(:instance).and_return(feed_manager)

          pipeline = instance_double(CustomFeeds::Pipeline, include?: false)
          allow(CustomFeeds::Pipeline).to receive(:new).and_return(pipeline)
        end

        it 'does not push to any custom feed' do
          subject.perform(status.id, account.id)
          expect(cf_manager).to_not have_received(:push_and_stream)
        end
      end
    end
  end
end
