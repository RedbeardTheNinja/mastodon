# frozen_string_literal: true

# == Schema Information
#
# Table name: custom_feed_steps
#
#  id                    :bigint(8)        not null, primary key
#  options               :jsonb            not null
#  phase                 :string           not null
#  position              :integer          default(0), not null
#  step_type             :string           not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  custom_feed_config_id :bigint(8)        not null
#

class CustomFeedStep < ApplicationRecord
  VALID_PHASES = %w(source filter algorithm algorithmic_filter removal_strategy overflow_strategy).freeze

  belongs_to :custom_feed_config
  has_many :custom_feed_pull_cursors, dependent: :destroy

  validates :phase,     presence: true, inclusion: { in: VALID_PHASES }
  validates :step_type, presence: true
  validates :position,  presence: true, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
