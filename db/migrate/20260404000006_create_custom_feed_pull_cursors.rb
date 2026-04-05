# frozen_string_literal: true

class CreateCustomFeedPullCursors < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    create_table :custom_feed_pull_cursors do |t|
      t.references :custom_feed_step, null: false, foreign_key: true, index: false
      t.string :bucket, null: false, default: ''
      t.string :last_fetched_id
      t.datetime :last_fetched_at

      t.timestamps
    end

    add_index :custom_feed_pull_cursors,
              [:custom_feed_step_id, :bucket],
              unique: true,
              name: 'index_pull_cursors_step_bucket',
              algorithm: :concurrently
  end
end
