# frozen_string_literal: true

# == Schema Information
#
# Table name: custom_feed_configs
#
#  id                   :bigint(8)        not null, primary key
#  enabled              :boolean          default(TRUE), not null
#  feed_type            :string           default("standard"), not null
#  last_pulled_at       :datetime
#  pull_cadence_minutes :integer          default(15), not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint(8)        not null
#  list_id              :bigint(8)        not null
#

class CustomFeedConfig < ApplicationRecord
  belongs_to :account
  belongs_to :list

  has_many :custom_feed_steps, dependent: :destroy

  after_destroy :cleanup_redis_keys

  validates :list_id, uniqueness: true

  scope :enabled,      -> { where(enabled: true) }
  scope :standard,     -> { where(feed_type: 'standard') }
  scope :algorithmic,  -> { where(feed_type: 'algorithmic') }

  validates :feed_type, inclusion: { in: %w(standard algorithmic) }

  # Returns steps for a given phase, ordered by position.
  # @param [String] phase one of 'source', 'filter', 'removal_strategy', 'overflow_strategy'
  # @return [ActiveRecord::Relation<CustomFeedStep>]
  def steps_for(phase)
    custom_feed_steps.where(phase: phase).order(:position)
  end

  private

  def cleanup_redis_keys
    CustomFeeds::FeedManager.instance.delete_feed(list_id)
  end
end
