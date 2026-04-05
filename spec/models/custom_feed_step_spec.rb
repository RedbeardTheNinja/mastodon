# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeedStep do
  let(:account) { Fabricate(:account) }
  let(:list)    { Fabricate(:list, account: account) }
  let(:config)  { CustomFeedConfig.create!(account: account, list: list) }

  describe 'validations' do
    it 'is valid with a known phase, step_type, and position' do
      step = described_class.new(
        custom_feed_config: config,
        phase: 'source',
        step_type: 'followed_posts',
        position: 0
      )
      expect(step).to be_valid
    end

    it 'is invalid with an unknown phase' do
      step = described_class.new(
        custom_feed_config: config,
        phase: 'invalid_phase',
        step_type: 'followed_posts',
        position: 0
      )
      expect(step).to_not be_valid
      expect(step.errors[:phase]).to_not be_empty
    end

    it 'is invalid without a step_type' do
      step = described_class.new(
        custom_feed_config: config,
        phase: 'source',
        step_type: '',
        position: 0
      )
      expect(step).to_not be_valid
    end

    it 'is invalid with a negative position' do
      step = described_class.new(
        custom_feed_config: config,
        phase: 'source',
        step_type: 'followed_posts',
        position: -1
      )
      expect(step).to_not be_valid
    end
  end
end
