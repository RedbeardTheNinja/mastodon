# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeedConfig do
  let(:account) { Fabricate(:account) }
  let(:list)    { Fabricate(:list, account: account) }

  describe 'validations' do
    it 'is valid with account and list' do
      config = described_class.new(account: account, list: list)
      expect(config).to be_valid
    end

    it 'enforces uniqueness on list_id' do
      described_class.create!(account: account, list: list)
      duplicate = described_class.new(account: account, list: list)

      expect(duplicate).to_not be_valid
      expect(duplicate.errors[:list_id]).to_not be_empty
    end
  end

  describe '.enabled scope' do
    it 'returns only enabled configs' do
      enabled  = described_class.create!(account: account, list: list, enabled: true)
      list2    = Fabricate(:list, account: account)
      disabled = described_class.create!(account: account, list: list2, enabled: false)

      expect(described_class.enabled).to include(enabled)
      expect(described_class.enabled).to_not include(disabled)
    end
  end

  describe '#steps_for' do
    subject(:config) { described_class.create!(account: account, list: list) }

    before do
      CustomFeedStep.create!(custom_feed_config: config, phase: 'source', step_type: 'followed_posts', position: 0)
      CustomFeedStep.create!(custom_feed_config: config, phase: 'filter', step_type: 'interacted_posts', position: 0)
      CustomFeedStep.create!(custom_feed_config: config, phase: 'source', step_type: 'followed_posts', position: 1)
    end

    it 'returns only steps for the requested phase' do
      sources = config.steps_for('source')
      expect(sources.map(&:phase).uniq).to eq ['source']
    end

    it 'orders steps by position' do
      sources = config.steps_for('source')
      expect(sources.map(&:position)).to eq [0, 1]
    end
  end
end
