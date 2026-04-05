# frozen_string_literal: true

class CreateCustomFeedSteps < ActiveRecord::Migration[7.2]
  def change
    create_table :custom_feed_steps do |t|
      t.references :custom_feed_config, null: false, foreign_key: true
      t.string  :phase,     null: false
      t.string  :step_type, null: false
      t.jsonb   :options,   null: false, default: {}
      t.integer :position,  null: false, default: 0

      t.timestamps
    end

    add_index :custom_feed_steps, [:custom_feed_config_id, :phase, :position],
              name: 'index_custom_feed_steps_on_config_phase_position'
  end
end
