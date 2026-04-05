# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::CustomFeeds' do
  let(:user)    { Fabricate(:user) }
  let(:account) { user.account }
  let(:token)   { Fabricate(:accessible_access_token, resource_owner_id: user.id, scopes: 'read:lists write:lists') }
  let(:headers) { { 'Authorization' => "Bearer #{token.token}" } }
  let(:list)    { Fabricate(:list, account: account) }

  describe 'GET /api/v1/custom_feeds' do
    before do
      config = CustomFeedConfig.create!(account: account, list: list, enabled: true)
      CustomFeedStep.create!(custom_feed_config: config, phase: 'source', step_type: 'followed_posts', position: 0)
    end

    it 'returns the user\'s custom feed configs' do
      get '/api/v1/custom_feeds', headers: headers

      expect(response).to have_http_status(200)
      body = response.parsed_body
      expect(body).to be_an Array
      expect(body.first['list_id']).to eq list.id.to_s
    end
  end

  describe 'POST /api/v1/custom_feeds' do
    let(:steps) do
      [
        { phase: 'source',            step_type: 'followed_posts',   position: 0 },
        { phase: 'filter',            step_type: 'interacted_posts', position: 0 },
        { phase: 'removal_strategy',  step_type: 'on_interaction',   position: 0 },
        { phase: 'overflow_strategy', step_type: 'oldest_first',     position: 0 },
      ]
    end

    it 'creates a custom feed config' do
      post '/api/v1/custom_feeds',
           params: { list_id: list.id, enabled: true, steps: steps },
           headers: headers

      expect(response).to have_http_status(200)
      body = response.parsed_body
      expect(body['list_id']).to eq list.id.to_s
      expect(body['enabled']).to be true
      expect(body['steps'].length).to eq 4
    end

    it 'returns 404 when the list does not belong to the user' do
      other_list = Fabricate(:list)

      post '/api/v1/custom_feeds',
           params: { list_id: other_list.id, steps: steps },
           headers: headers

      expect(response).to have_http_status(404)
    end
  end

  describe 'GET /api/v1/custom_feeds/:id' do
    let(:config) do
      c = CustomFeedConfig.create!(account: account, list: list, enabled: true)
      CustomFeedStep.create!(custom_feed_config: c, phase: 'source', step_type: 'followed_posts', position: 0)
      c
    end

    it 'returns the config' do
      get "/api/v1/custom_feeds/#{config.id}", headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body['id']).to eq config.id.to_s
    end

    it 'returns 404 for another user\'s config' do
      other_config = CustomFeedConfig.create!(
        account: Fabricate(:account),
        list: Fabricate(:list),
        enabled: true
      )

      get "/api/v1/custom_feeds/#{other_config.id}", headers: headers

      expect(response).to have_http_status(404)
    end
  end

  describe 'PATCH /api/v1/custom_feeds/:id' do
    let(:config) do
      c = CustomFeedConfig.create!(account: account, list: list, enabled: true)
      CustomFeedStep.create!(custom_feed_config: c, phase: 'source', step_type: 'followed_posts', position: 0)
      c
    end

    it 'updates the enabled flag' do
      patch "/api/v1/custom_feeds/#{config.id}",
            params: { enabled: false },
            headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body['enabled']).to be false
    end

    it 'replaces steps when provided' do
      new_steps = [
        { phase: 'source', step_type: 'followed_posts', position: 0 },
      ]

      patch "/api/v1/custom_feeds/#{config.id}",
            params: { steps: new_steps },
            headers: headers

      expect(response).to have_http_status(200)
      expect(response.parsed_body['steps'].length).to eq 1
    end
  end

  describe 'DELETE /api/v1/custom_feeds/:id' do
    let(:config) do
      CustomFeedConfig.create!(account: account, list: list, enabled: true)
    end

    it 'destroys the config' do
      delete "/api/v1/custom_feeds/#{config.id}", headers: headers

      expect(response).to have_http_status(200)
      expect(CustomFeedConfig.find_by(id: config.id)).to be_nil
    end
  end
end
