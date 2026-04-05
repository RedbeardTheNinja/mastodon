# frozen_string_literal: true

class AddFeedTypeToCustomFeedConfigs < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_column :custom_feed_configs, :feed_type, :string, null: false, default: 'standard'
    add_index  :custom_feed_configs, :feed_type, algorithm: :concurrently
  end
end
