# frozen_string_literal: true

class CreateRecommendationSignals < ActiveRecord::Migration[7.2]
  def change
    create_table :recommendation_signals do |t|
      t.references :account,           null: false, foreign_key: true
      t.string     :signal_type,       null: false  # 'tag' | 'account' | 'domain'
      t.string     :entity_id,         null: false  # tag name | account_id | domain
      t.float      :weight,            null: false, default: 0.0
      t.integer    :observation_count, null: false, default: 0
      t.datetime   :last_observed_at
      t.timestamps
    end

    add_index :recommendation_signals,
              [:account_id, :signal_type, :entity_id],
              unique: true,
              name: 'idx_rec_signals_lookup'
  end
end
