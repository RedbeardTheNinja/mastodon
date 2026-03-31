# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewToMe::FeedInsertConcern do
  # Test the concern by building a minimal class that mirrors FeedInsertWorker's
  # interface and prepending the concern onto it.
  let(:worker_class) do
    Class.new do
      prepend NewToMe::FeedInsertConcern

      attr_accessor :type, :status, :follower

      def initialize(type:, status:, follower:)
        @type     = type
        @status   = status
        @follower = follower
      end

      def perform_push
        # base no-op — overridden by concern
      end
    end
  end

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe '#perform_push' do
    before do
      allow(NewToMe::FeedInsertWorker).to receive(:perform_async)
    end

    context 'when type is :home' do
      let(:worker) { worker_class.new(type: :home, status: status, follower: account) }

      it 'enqueues NewToMe::FeedInsertWorker' do
        worker.perform_push

        expect(NewToMe::FeedInsertWorker).to have_received(:perform_async).with(status.id, account.id)
      end

      it 'does not raise an error (super chain runs)' do
        expect { worker.perform_push }.not_to raise_error
      end
    end

    context 'when type is :tags' do
      let(:worker) { worker_class.new(type: :tags, status: status, follower: account) }

      it 'does not enqueue NewToMe::FeedInsertWorker' do
        worker.perform_push

        expect(NewToMe::FeedInsertWorker).not_to have_received(:perform_async)
      end
    end

    context 'when type is :list' do
      let(:worker) { worker_class.new(type: :list, status: status, follower: account) }

      it 'does not enqueue NewToMe::FeedInsertWorker' do
        worker.perform_push

        expect(NewToMe::FeedInsertWorker).not_to have_received(:perform_async)
      end
    end
  end
end
