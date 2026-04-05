# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::FeedRemoveWorker do
  subject { described_class.new }

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }
  let(:list)    { Fabricate(:list, account: account) }

  let(:config) do
    c = CustomFeedConfig.create!(account: account, list: list, enabled: true)
    CustomFeedStep.create!(custom_feed_config: c, phase: 'removal_strategy', step_type: 'on_interaction', position: 0)
    c
  end

  let(:cf_manager) { instance_double(CustomFeeds::FeedManager, remove_and_stream: nil) }

  before do
    config # ensure it exists
    allow(CustomFeeds::FeedManager).to receive(:instance).and_return(cf_manager)
  end

  describe '#perform' do
    context 'when account is missing' do
      it 'returns true without removing' do
        result = subject.perform(status.id, nil, 'favourite')
        expect(result).to be true
        expect(cf_manager).to_not have_received(:remove_and_stream)
      end
    end

    context 'when the pipeline says to remove on this interaction' do
      before do
        pipeline = instance_double(CustomFeeds::Pipeline, remove_on?: true)
        allow(CustomFeeds::Pipeline).to receive(:new).and_return(pipeline)
      end

      it 'calls remove_and_stream with the original status id and any reblogs' do
        reblog = Fabricate(:status, reblog: status)

        subject.perform(status.id, account.id, 'favourite')

        expect(cf_manager).to have_received(:remove_and_stream).with(
          config,
          contain_exactly(status.id, reblog.id)
        )
      end
    end

    context 'when the pipeline says not to remove on this interaction' do
      before do
        pipeline = instance_double(CustomFeeds::Pipeline, remove_on?: false)
        allow(CustomFeeds::Pipeline).to receive(:new).and_return(pipeline)
      end

      it 'does not call remove_and_stream' do
        subject.perform(status.id, account.id, 'favourite')
        expect(cf_manager).to_not have_received(:remove_and_stream)
      end
    end
  end
end
