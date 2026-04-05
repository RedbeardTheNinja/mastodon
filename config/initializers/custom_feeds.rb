# frozen_string_literal: true

Rails.application.config.to_prepare do
  # Register all step types
  CustomFeeds::Sources::FollowedPosts.register!
  CustomFeeds::Sources::RemoteTagTimeline.register!
  CustomFeeds::Sources::RemotePublicTimeline.register!
  CustomFeeds::Filters::InteractedPosts.register!
  CustomFeeds::Filters::FriendsLiked.register!
  CustomFeeds::RemovalStrategies::OnInteraction.register!
  CustomFeeds::OverflowStrategies::OldestFirst.register!

  # Wire concerns into existing classes
  Api::V1::Timelines::ListController.prepend(CustomFeeds::ListControllerConcern)
  FeedInsertWorker.prepend(CustomFeeds::FeedInsertConcern)
  Favourite.include(CustomFeeds::FavouriteConcern)
  Status.include(CustomFeeds::StatusConcern)
end
