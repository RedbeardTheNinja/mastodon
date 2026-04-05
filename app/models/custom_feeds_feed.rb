# frozen_string_literal: true

class CustomFeedsFeed < Feed
  def initialize(list)
    super(:custom, list.id)
  end

  private

  def key
    CustomFeeds::FeedManager.instance.key(@id)
  end
end
