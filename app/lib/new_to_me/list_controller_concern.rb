# frozen_string_literal: true

module NewToMe
  module ListControllerConcern
    private

    def list_feed
      return NewToMeFeed.new(@list.account) if @list.title.casecmp?(NewToMe::LIST_TITLE)

      super
    end
  end
end
