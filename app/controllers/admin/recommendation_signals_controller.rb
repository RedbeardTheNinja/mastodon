# frozen_string_literal: true

class Admin::RecommendationSignalsController < Admin::BaseController
  def index
    authorize :recommendation_signal, :index?

    algorithmic_account_ids = CustomFeedConfig
      .where(feed_type: 'algorithmic')
      .select(:account_id)

    @accounts = Account
      .where(id: algorithmic_account_ids)
      .page(params[:page])

    @signal_counts = RecommendationSignal
      .where(account: @accounts)
      .group(:account_id)
      .count

    @configs_by_account = CustomFeedConfig
      .where(account: @accounts)
      .includes(:custom_feed_steps, :list)
      .group_by(&:account_id)
  end

  def resubmit
    authorize :recommendation_signal, :resubmit?

    account = Account.find(params[:account_id])

    Favourite.where(account: account).find_in_batches(batch_size: 100) do |batch|
      batch.each do |fav|
        Recommendations::SignalWorker.perform_async('favourite', fav.status_id, account.id)
      end
    end

    redirect_to admin_recommendation_signals_path,
                notice: "Signal resubmission enqueued for #{account.username}"
  end

  def run_feed
    authorize :recommendation_signal, :run_feed?

    config = CustomFeedConfig.find(params[:config_id])
    CustomFeeds::PullSourceIngestWorker.perform_async(config.id)

    redirect_to admin_recommendation_signals_path,
                notice: "Pull source re-run enqueued for feed ##{config.id}"
  end
end
