# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewToMe::ListControllerConcern do
  # Test the concern in isolation using a minimal fake controller.
  let(:controller_class) do
    Class.new do
      prepend NewToMe::ListControllerConcern

      attr_writer :list

      def list_feed
        ListFeed.new(@list)
      end
    end
  end

  let(:account) { Fabricate(:account) }

  describe '#list_feed' do
    context 'when the list title is "New To Me"' do
      let(:list) { Fabricate(:list, account: account, title: 'New To Me') }

      it 'returns a NewToMeFeed' do
        controller = controller_class.new
        controller.list = list

        expect(controller.list_feed).to be_a NewToMeFeed
      end

      it 'the NewToMeFeed is scoped to the list owner account' do
        controller = controller_class.new
        controller.list = list

        feed = controller.list_feed
        expect(feed).to be_a NewToMeFeed
      end
    end

    context 'when the list title is "new to me" (different case)' do
      let(:list) { Fabricate(:list, account: account, title: 'new to me') }

      it 'still returns a NewToMeFeed (case-insensitive)' do
        controller = controller_class.new
        controller.list = list

        expect(controller.list_feed).to be_a NewToMeFeed
      end
    end

    context 'when the list title is anything else' do
      let(:list) { Fabricate(:list, account: account, title: 'My Custom List') }

      it 'returns a ListFeed' do
        controller = controller_class.new
        controller.list = list

        expect(controller.list_feed).to be_a ListFeed
      end
    end
  end
end
