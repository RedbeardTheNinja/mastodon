# frozen_string_literal: true

Rails.application.config.to_prepare do
  # Register all step types
  CustomFeeds::Sources::FollowedPosts.register!
  CustomFeeds::Sources::RemoteTagTimeline.register!
  CustomFeeds::Sources::RemotePublicTimeline.register!
  CustomFeeds::Filters::HomeFilters.register!
  CustomFeeds::Filters::InteractedPosts.register!
  CustomFeeds::Filters::FriendsLiked.register!
  CustomFeeds::Filters::BlockedTags.register!
  CustomFeeds::Filters::FollowedAccounts.register!
  CustomFeeds::RemovalStrategies::OnInteraction.register!
  CustomFeeds::RemovalStrategies::TimeBased.register!
  CustomFeeds::OverflowStrategies::OldestFirst.register!
  Recommendations::Algorithms::AffinityScore.register!

  # Wire concerns into existing classes
  Api::V1::Timelines::ListController.prepend(CustomFeeds::ListControllerConcern)
  FeedInsertWorker.prepend(CustomFeeds::FeedInsertConcern)
  Favourite.include(CustomFeeds::FavouriteConcern)
  Status.include(CustomFeeds::StatusConcern)
end
