# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::Pipeline do
  let(:account) { Fabricate(:account) }
  let(:list)    { Fabricate(:list, account: account) }
  let(:config)  { CustomFeedConfig.create!(account: account, list: list, enabled: true) }

  def add_step(phase, step_type, position: 0)
    CustomFeedStep.create!(
      custom_feed_config: config,
      phase: phase,
      step_type: step_type,
      position: position
    )
  end

  describe '#include?' do
    let(:status) { Fabricate(:status) }

    context 'with a followed_posts source and no filters' do
      before do
        add_step('source', 'followed_posts')
        allow(FeedManager.instance).to receive(:filter).and_return(nil)
      end

      it 'returns true when source includes the status' do
        pipeline = described_class.new(config)
        expect(pipeline.include?(status, account)).to be true
      end
    end

    context 'when the home filter would exclude the status' do
      before do
        add_step('source', 'followed_posts')
        allow(FeedManager.instance).to receive(:filter).and_return(:filter)
      end

      it 'returns false' do
        pipeline = described_class.new(config)
        expect(pipeline.include?(status, account)).to be false
      end
    end

    context 'with an interacted_posts filter when user has favourited the status' do
      before do
        add_step('source', 'followed_posts')
        add_step('filter', 'interacted_posts')
        allow(FeedManager.instance).to receive(:filter).and_return(nil)
        Fabricate(:favourite, account: account, status: status)
      end

      it 'returns false' do
        pipeline = described_class.new(config)
        expect(pipeline.include?(status, account)).to be false
      end
    end

    context 'with no source steps' do
      it 'returns false' do
        pipeline = described_class.new(config)
        expect(pipeline.include?(status, account)).to be false
      end
    end
  end

  describe '#remove_on?' do
    context 'with an on_interaction removal strategy' do
      before { add_step('removal_strategy', 'on_interaction') }

      it 'returns true for favourite' do
        pipeline = described_class.new(config)
        expect(pipeline.remove_on?('favourite')).to be true
      end

      it 'returns true for reblog' do
        pipeline = described_class.new(config)
        expect(pipeline.remove_on?('reblog')).to be true
      end

      it 'returns true for reply' do
        pipeline = described_class.new(config)
        expect(pipeline.remove_on?('reply')).to be true
      end
    end

    context 'with no removal strategy steps' do
      it 'returns false' do
        pipeline = described_class.new(config)
        expect(pipeline.remove_on?('favourite')).to be false
      end
    end
  end

  describe '#overflow' do
    context 'with an oldest_first overflow strategy step' do
      before { add_step('overflow_strategy', 'oldest_first') }

      it 'returns an OldestFirst instance' do
        pipeline = described_class.new(config)
        expect(pipeline.overflow).to be_a CustomFeeds::OverflowStrategies::OldestFirst
      end
    end

    context 'with no overflow strategy step' do
      it 'defaults to OldestFirst' do
        pipeline = described_class.new(config)
        expect(pipeline.overflow).to be_a CustomFeeds::OverflowStrategies::OldestFirst
      end
    end
  end
end
