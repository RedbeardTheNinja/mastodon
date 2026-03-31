# frozen_string_literal: true

Rails.application.config.to_prepare do
  Api::V1::Timelines::ListController.prepend(NewToMe::ListControllerConcern)
  FeedInsertWorker.prepend(NewToMe::FeedInsertConcern)
  Favourite.include(NewToMe::FavouriteConcern)
  Status.include(NewToMe::StatusConcern)
end
