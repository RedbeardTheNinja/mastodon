# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::ListControllerConcern do
  let(:controller_class) do
    Class.new do
      prepend CustomFeeds::ListControllerConcern

      attr_writer :list

      def list_feed
        ListFeed.new(@list)
      end
    end
  end

  let(:account) { Fabricate(:account) }

  describe '#list_feed' do
    context 'when the list has a CustomFeedConfig' do
      let(:list) { Fabricate(:list, account: account) }

      before do
        config = CustomFeedConfig.create!(account: account, list: list, enabled: true)
        CustomFeedStep.create!(custom_feed_config: config, phase: 'source', step_type: 'followed_posts', position: 0)
      end

      it 'returns a CustomFeedsFeed' do
        controller = controller_class.new
        controller.list = list

        expect(controller.send(:list_feed)).to be_a CustomFeedsFeed
      end
    end

    context 'when the list has a disabled CustomFeedConfig' do
      let(:list) { Fabricate(:list, account: account) }

      before do
        CustomFeedConfig.create!(account: account, list: list, enabled: false)
      end

      it 'returns a regular ListFeed' do
        controller = controller_class.new
        controller.list = list

        expect(controller.send(:list_feed)).to be_a ListFeed
      end
    end

    context 'when the list has no CustomFeedConfig' do
      let(:list) { Fabricate(:list, account: account, title: 'My Regular List') }

      it 'returns a ListFeed' do
        controller = controller_class.new
        controller.list = list

        expect(controller.send(:list_feed)).to be_a ListFeed
      end
    end
  end
end
