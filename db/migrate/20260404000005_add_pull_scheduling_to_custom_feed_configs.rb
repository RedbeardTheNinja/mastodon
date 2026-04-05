# frozen_string_literal: true

class AddPullSchedulingToCustomFeedConfigs < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_column :custom_feed_configs, :pull_cadence_minutes, :integer, null: false, default: 15
    add_column :custom_feed_configs, :last_pulled_at, :datetime
    add_index :custom_feed_configs, :last_pulled_at, algorithm: :concurrently
  end
end
