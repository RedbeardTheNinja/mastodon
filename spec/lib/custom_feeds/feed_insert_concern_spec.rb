# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CustomFeeds::FeedInsertConcern do
  let(:worker_class) do
    Class.new do
      prepend CustomFeeds::FeedInsertConcern

      attr_accessor :type, :status, :follower

      def initialize(type:, status:, follower:)
        @type     = type
        @status   = status
        @follower = follower
      end

      def perform_push
        # base no-op
      end
    end
  end

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe '#perform_push' do
    before do
      allow(CustomFeeds::FeedInsertWorker).to receive(:perform_async)
    end

    context 'when type is :home' do
      let(:worker) { worker_class.new(type: :home, status: status, follower: account) }

      it 'enqueues CustomFeeds::FeedInsertWorker' do
        worker.perform_push

        expect(CustomFeeds::FeedInsertWorker).to have_received(:perform_async).with(status.id, account.id)
      end
    end

    context 'when type is :tags' do
      let(:worker) { worker_class.new(type: :tags, status: status, follower: account) }

      it 'does not enqueue CustomFeeds::FeedInsertWorker' do
        worker.perform_push

        expect(CustomFeeds::FeedInsertWorker).to_not have_received(:perform_async)
      end
    end

    context 'when type is :list' do
      let(:worker) { worker_class.new(type: :list, status: status, follower: account) }

      it 'does not enqueue CustomFeeds::FeedInsertWorker' do
        worker.perform_push

        expect(CustomFeeds::FeedInsertWorker).to_not have_received(:perform_async)
      end
    end
  end
end
