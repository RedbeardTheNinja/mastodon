# frozen_string_literal: true

class Api::V1::CustomFeedsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read, :'read:lists' }, only: [:index, :show]
  before_action -> { doorkeeper_authorize! :write, :'write:lists' }, except: [:index, :show]

  before_action :require_user!
  before_action :set_config, only: [:show, :update, :destroy]

  def index
    configs = CustomFeedConfig.where(account: current_account).includes(:custom_feed_steps)
    render json: configs, each_serializer: REST::CustomFeedConfigSerializer
  end

  def show
    render json: @config, serializer: REST::CustomFeedConfigSerializer
  end

  def create
    list = List.where(account: current_account).find(params[:list_id])

    @config = CustomFeedConfig.new(
      account: current_account,
      list: list,
      feed_type: params.fetch(:feed_type, 'standard'),
      enabled: params.fetch(:enabled, true),
      pull_cadence_minutes: params.fetch(:pull_cadence_minutes, 15).to_i
    )

    ActiveRecord::Base.transaction do
      @config.save!
      upsert_steps(@config, steps_params)
    end

    render json: @config, serializer: REST::CustomFeedConfigSerializer
  end

  def update
    @config.enabled = params[:enabled] if params.key?(:enabled)
    @config.feed_type = params[:feed_type] if params.key?(:feed_type)
    @config.pull_cadence_minutes = params[:pull_cadence_minutes].to_i if params.key?(:pull_cadence_minutes)

    ActiveRecord::Base.transaction do
      @config.save!
      upsert_steps(@config, steps_params) if params.key?(:steps)
    end

    render json: @config, serializer: REST::CustomFeedConfigSerializer
  end

  def destroy
    @config.destroy!
    render_empty
  end

  private

  def set_config
    @config = CustomFeedConfig.where(account: current_account).find(params[:id])
  end

  # Replace the steps for this config wholesale.
  def upsert_steps(config, steps)
    config.custom_feed_steps.destroy_all
    steps.each do |step_attrs|
      config.custom_feed_steps.create!(
        phase: step_attrs[:phase],
        step_type: step_attrs[:step_type],
        position: step_attrs.fetch(:position, 0),
        options: step_attrs.fetch(:options, {})
      )
    end
  end

  def steps_params
    return [] unless params[:steps].is_a?(Array)

    params[:steps].map do |s|
      s.permit(:phase, :step_type, :position, options: {}).to_h.with_indifferent_access
    end
  end
end
