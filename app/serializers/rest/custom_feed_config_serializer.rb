# frozen_string_literal: true

class REST::CustomFeedConfigSerializer < ActiveModel::Serializer
  attributes :id, :list_id, :feed_type, :enabled, :pull_cadence_minutes, :steps

  def id
    object.id.to_s
  end

  def list_id
    object.list_id.to_s
  end

  def steps
    object.custom_feed_steps.order(:phase, :position).map do |step|
      {
        id: step.id.to_s,
        phase: step.phase,
        step_type: step.step_type,
        position: step.position,
        options: step.options,
      }
    end
  end
end
