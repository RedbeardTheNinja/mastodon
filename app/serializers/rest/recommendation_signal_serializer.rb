# frozen_string_literal: true

class REST::RecommendationSignalSerializer < ActiveModel::Serializer
  attributes :id, :signal_type, :entity_id, :weight, :observation_count, :last_observed_at

  def id
    object.id.to_s
  end

  def last_observed_at
    object.last_observed_at&.iso8601
  end
end
