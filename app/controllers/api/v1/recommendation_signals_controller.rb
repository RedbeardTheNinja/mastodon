# frozen_string_literal: true

class Api::V1::RecommendationSignalsController < Api::BaseController
  before_action -> { doorkeeper_authorize! :read,  :'read:lists'  }, only: [:index]
  before_action -> { doorkeeper_authorize! :write, :'write:lists' }, except: [:index]

  before_action :require_user!
  before_action :set_signal, only: [:update, :destroy]

  # GET /api/v1/recommendation_signals
  def index
    @signals = RecommendationSignal
      .where(account: current_account)
      .order(:signal_type, weight: :desc)
    render json: @signals, each_serializer: REST::RecommendationSignalSerializer
  end

  # PATCH /api/v1/recommendation_signals/:id
  def update
    @signal.update!(weight: params[:weight].to_f)
    render json: @signal, serializer: REST::RecommendationSignalSerializer
  end

  # DELETE /api/v1/recommendation_signals/:id
  def destroy
    @signal.destroy!
    render_empty
  end

  # DELETE /api/v1/recommendation_signals  (delete all for the account)
  def destroy_all
    RecommendationSignal.where(account: current_account).delete_all
    render_empty
  end

  private

  def set_signal
    @signal = RecommendationSignal.where(account: current_account).find(params[:id])
  end
end
