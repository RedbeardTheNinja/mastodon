# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Timelines::List (custom feed)' do
  let(:user)    { Fabricate(:user) }
  let(:account) { user.account }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:lists') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:list)    { Fabricate(:list, account: account) }
  let(:config) do
    c = CustomFeedConfig.create!(account: account, list: list, enabled: true)
    CustomFeedStep.create!(custom_feed_config: c, phase: 'source', step_type: 'followed_posts', position: 0)
    c
  end

  describe 'GET /api/v1/timelines/list/:id (custom feed)' do
    let(:statuses) { Fabricate.times(2, :status) }

    before do
      config
      statuses.each do |status|
        redis.zadd(CustomFeeds::FeedManager.instance.key(list.id), status.id, status.id)
      end
    end

    after do
      redis.del(CustomFeeds::FeedManager.instance.key(list.id))
    end

    it 'returns statuses from the custom feed Redis key' do
      get "/api/v1/timelines/list/#{list.id}", headers: headers

      expect(response).to have_http_status(200)
      ids = response.parsed_body.pluck('id')
      expect(ids).to match_array(statuses.map { |s| s.id.to_s })
    end
  end

  describe 'GET /api/v1/timelines/list/:id (regular list, no config)' do
    let(:regular_list) { Fabricate(:list, account: account) }

    it 'serves the regular list feed (no custom feed config)' do
      get "/api/v1/timelines/list/#{regular_list.id}", headers: headers

      expect(response).to have_http_status(200)
    end
  end
end
