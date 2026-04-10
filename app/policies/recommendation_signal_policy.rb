# frozen_string_literal: true

class RecommendationSignalPolicy < ApplicationPolicy
  def index?
    role.can?(:manage_users)
  end

  def resubmit?
    role.can?(:manage_users)
  end

  def run_feed?
    role.can?(:manage_users)
  end
end
