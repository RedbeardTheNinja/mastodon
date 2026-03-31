# frozen_string_literal: true

class NewToMeFeed < Feed
  def initialize(account)
    super(:new_to_me, account.id)
  end

  private

  def key
    NewToMe::FeedManager.instance.key(@id)
  end
end
