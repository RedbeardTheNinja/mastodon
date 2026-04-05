# frozen_string_literal: true

class CreateCustomFeedConfigs < ActiveRecord::Migration[7.2]
  def change
    create_table :custom_feed_configs do |t|
      t.references :account, null: false, foreign_key: true
      t.references :list,    null: false, foreign_key: true, index: { unique: true }
      t.boolean    :enabled, null: false, default: true

      t.timestamps
    end
  end
end
