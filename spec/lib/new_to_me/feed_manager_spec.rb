# frozen_string_literal: true

require 'rails_helper'

RSpec.describe NewToMe::FeedManager do
  subject { described_class.instance }

  let(:account) { Fabricate(:account) }
  let(:status)  { Fabricate(:status) }

  describe '#key' do
    it 'returns the correct Redis key for an account' do
      expect(subject.key(account.id)).to eq "feed:new_to_me:#{account.id}"
    end
  end

  describe '#push' do
    context 'when the user has signed in recently' do
      before { account.user.update!(current_sign_in_at: 1.hour.ago) }

      it 'adds the status id to the Redis sorted set' do
        subject.push(account, status)

        expect(redis.zscore(subject.key(account.id), status.id)).to_not be_nil
      end

      it 'uses the status id as the score' do
        subject.push(account, status)

        expect(redis.zscore(subject.key(account.id), status.id)).to eq status.id.to_f
      end

      it 'returns true' do
        expect(subject.push(account, status)).to be true
      end

      context 'when the feed exceeds MAX_ITEMS' do
        before do
          stub_const('FeedManager::MAX_ITEMS', 3)
          redis.zadd(subject.key(account.id), [[1, 1], [2, 2], [3, 3]])
        end

        it 'trims the feed to MAX_ITEMS' do
          subject.push(account, status)

          expect(redis.zcard(subject.key(account.id))).to eq FeedManager::MAX_ITEMS
        end
      end

      context 'when the account has already favourited the status' do
        before { Fabricate(:favourite, account: account, status: status) }

        it 'does not add the status to the feed' do
          subject.push(account, status)

          expect(redis.zscore(subject.key(account.id), status.id)).to be_nil
        end

        it 'returns false' do
          expect(subject.push(account, status)).to be false
        end
      end

      context 'when the account has already reblogged the status' do
        before { Fabricate(:status, account: account, reblog: status) }

        it 'does not add the status to the feed' do
          subject.push(account, status)

          expect(redis.zscore(subject.key(account.id), status.id)).to be_nil
        end

        it 'returns false' do
          expect(subject.push(account, status)).to be false
        end
      end

      context 'when the account has already replied to the status' do
        before { Fabricate(:status, account: account, in_reply_to_id: status.id, in_reply_to_account_id: status.account_id) }

        it 'does not add the status to the feed' do
          subject.push(account, status)

          expect(redis.zscore(subject.key(account.id), status.id)).to be_nil
        end

        it 'returns false' do
          expect(subject.push(account, status)).to be false
        end
      end
    end

    context 'when the user has not signed in recently' do
      before { account.user.update!(current_sign_in_at: (User::Activity::ACTIVE_DURATION + 1.day).ago) }

      it 'does not add the status to the feed' do
        subject.push(account, status)

        expect(redis.zscore(subject.key(account.id), status.id)).to be_nil
      end

      it 'returns false' do
        expect(subject.push(account, status)).to be false
      end
    end

    context 'when the account has no user (bot/remote)' do
      let(:account) { Fabricate(:account, domain: 'example.com') }

      it 'returns false' do
        expect(subject.push(account, status)).to be false
      end
    end
  end

  describe '#remove' do
    before do
      redis.zadd(subject.key(account.id), status.id, status.id)
    end

    it 'removes the status id from the Redis sorted set' do
      subject.remove(account, status.id)

      expect(redis.zscore(subject.key(account.id), status.id)).to be_nil
    end

    context 'when the status is not in the feed' do
      it 'does not raise an error' do
        expect { subject.remove(account, 99999) }.not_to raise_error
      end
    end
  end

  describe '#interacted?' do
    context 'when the account has favourited the status' do
      before { Fabricate(:favourite, account: account, status: status) }

      it 'returns true' do
        expect(subject.interacted?(account, status)).to be true
      end
    end

    context 'when the account has reblogged the status' do
      before { Fabricate(:status, account: account, reblog: status) }

      it 'returns true' do
        expect(subject.interacted?(account, status)).to be true
      end
    end

    context 'when the account has replied to the status' do
      before { Fabricate(:status, account: account, in_reply_to_id: status.id, in_reply_to_account_id: status.account_id) }

      it 'returns true' do
        expect(subject.interacted?(account, status)).to be true
      end
    end

    context 'when the account has not interacted with the status' do
      it 'returns false' do
        expect(subject.interacted?(account, status)).to be false
      end
    end
  end
end
