# frozen_string_literal: true

# == Schema Information
#
# Table name: custom_feed_pull_cursors
#
#  id                  :bigint(8)        not null, primary key
#  bucket              :string           default(""), not null
#  last_fetched_at     :datetime
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  custom_feed_step_id :bigint(8)        not null
#  last_fetched_id     :string
#

class CustomFeedPullCursor < ApplicationRecord
  belongs_to :custom_feed_step

  # Find or create the cursor for a given step + bucket.
  # @param [CustomFeedStep] step
  # @param [String]         bucket  e.g. "mastodon.social:nsfw" or "mastodon.social"
  # @return [CustomFeedPullCursor]
  def self.for_step_bucket(step, bucket = '')
    find_or_create_by!(custom_feed_step: step, bucket: bucket.to_s)
  end
end
