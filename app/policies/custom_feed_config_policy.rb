# frozen_string_literal: true

class CustomFeedConfigPolicy < ApplicationPolicy
  def index?
    !current_account.nil?
  end

  def show?
    owner?
  end

  def create?
    !current_account.nil?
  end

  def update?
    owner?
  end

  def destroy?
    owner?
  end

  private

  def owner?
    record.account_id == current_account&.id
  end
end
