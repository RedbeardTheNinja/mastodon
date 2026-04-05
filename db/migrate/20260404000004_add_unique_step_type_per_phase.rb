# frozen_string_literal: true

class AddUniqueStepTypePerPhase < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  def change
    add_index :custom_feed_steps,
              [:custom_feed_config_id, :phase, :step_type],
              unique: true,
              name: 'index_custom_feed_steps_unique_type_per_phase',
              algorithm: :concurrently
  end
end
