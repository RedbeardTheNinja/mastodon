# frozen_string_literal: true

# == Schema Information
#
# Table name: recommendation_signals
#
#  id                :bigint(8)        not null, primary key
#  last_observed_at  :datetime
#  observation_count :integer          default(0), not null
#  signal_type       :string           not null
#  weight            :float            default(0.0), not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  account_id        :bigint(8)        not null
#  entity_id         :string           not null
#

class RecommendationSignal < ApplicationRecord
  belongs_to :account

  validates :signal_type, inclusion: { in: %w(tag account domain) }
  validates :entity_id, presence: true
  validates :account_id, uniqueness: { scope: [:signal_type, :entity_id] }
end
