# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'API V1 Timelines - New To Me', :inline_jobs do
  let(:user)    { Fabricate(:user) }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:lists') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:list)    { Fabricate(:list, account: user.account, title: 'New To Me') }

  let(:followed_account) { Fabricate(:account) }

  before do
    user.account.follow!(followed_account)
  end

  describe 'GET /api/v1/timelines/list/:id' do
    context 'when the feed has statuses' do
      let(:status) { Fabricate(:status, account: followed_account) }

      before do
        redis.zadd(
          NewToMe::FeedManager.instance.key(user.account.id),
          status.id,
          status.id
        )
      end

      it 'returns http success' do
        get "/api/v1/timelines/list/#{list.id}", headers: headers

        expect(response).to have_http_status(200)
      end

      it 'returns the statuses in the NTM feed' do
        get "/api/v1/timelines/list/#{list.id}", headers: headers

        ids = response.parsed_body.pluck('id')
        expect(ids).to include(status.id.to_s)
      end

      it 'does not return statuses not in the NTM Redis feed' do
        other_status = Fabricate(:status, account: followed_account)

        get "/api/v1/timelines/list/#{list.id}", headers: headers

        ids = response.parsed_body.pluck('id')
        expect(ids).not_to include(other_status.id.to_s)
      end
    end

    context 'when the user favourites a status' do
      let(:status) { Fabricate(:status, account: followed_account) }

      before do
        redis.zadd(
          NewToMe::FeedManager.instance.key(user.account.id),
          status.id,
          status.id
        )
      end

      it 'removes the status from the NTM feed after favouriting' do
        post "/api/v1/statuses/#{status.id}/favourite", headers: headers

        expect(redis.zscore(NewToMe::FeedManager.instance.key(user.account.id), status.id)).to be_nil
      end
    end

    context 'when the user reblogs a status' do
      let(:status) { Fabricate(:status, account: followed_account, visibility: :public) }

      before do
        redis.zadd(
          NewToMe::FeedManager.instance.key(user.account.id),
          status.id,
          status.id
        )
      end

      it 'removes the original status from the NTM feed after reblogging' do
        post "/api/v1/statuses/#{status.id}/reblog", headers: headers.merge('Authorization' => "Bearer #{Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:statuses').token}")

        expect(redis.zscore(NewToMe::FeedManager.instance.key(user.account.id), status.id)).to be_nil
      end
    end

    context 'when the user replies to a status' do
      let(:status) { Fabricate(:status, account: followed_account) }

      before do
        redis.zadd(
          NewToMe::FeedManager.instance.key(user.account.id),
          status.id,
          status.id
        )
      end

      it 'removes the parent status from the NTM feed after replying' do
        write_token = Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'write:statuses')
        post '/api/v1/statuses',
             params: { status: 'my reply', in_reply_to_id: status.id },
             headers: headers.merge('Authorization' => "Bearer #{write_token.token}")

        expect(redis.zscore(NewToMe::FeedManager.instance.key(user.account.id), status.id)).to be_nil
      end
    end
  end

  context 'with a non-NTM list' do
    let(:regular_list) { Fabricate(:list, account: user.account, title: 'Regular List') }

    it 'returns a normal list feed (not NTM)' do
      get "/api/v1/timelines/list/#{regular_list.id}", headers: headers

      expect(response).to have_http_status(200)
    end
  end
end
