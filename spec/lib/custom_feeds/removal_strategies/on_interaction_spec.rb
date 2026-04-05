# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::RemovalStrategies::OnInteraction do
  subject { described_class.new }

  describe '#remove_on?' do
    it 'returns true for favourite' do
      expect(subject.remove_on?('favourite')).to be true
    end

    it 'returns true for reblog' do
      expect(subject.remove_on?('reblog')).to be true
    end

    it 'returns true for reply' do
      expect(subject.remove_on?('reply')).to be true
    end
  end
end
