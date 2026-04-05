# frozen_string_literal: true

module CustomFeeds
  module ListControllerConcern
    private

    def list_feed
      config = CustomFeedConfig.find_by(list: @list, enabled: true)
      return CustomFeedsFeed.new(@list) if config

      super
    end
  end
end
