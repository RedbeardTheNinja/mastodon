# Customizations

Server-specific features and modifications built on top of the Mastodon source code for redbeardthe.ninja. Each entry below links to a document describing the feature, the files it touches, and relevant design decisions.

## Index

| Feature                                                      | Description                                                                                                                                                       |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Custom Feeds System](custom-feeds.md)                       | Extensible pluggable-pipeline system for custom algorithmic feeds backed by any Mastodon List                                                                     |
| [Recommendations](recommendations.md)                        | Scoring filters that extend the custom feeds pipeline to surface posts ranked by follows' engagement. Pull sources, filters, and workers are fully implemented; `RecommendationScore` filter + `FriendsLikedScore` algorithm are the remaining work. |
| [Plugin Plan](plugin-plan.md)                                | Plan for extracting Custom Feeds into a standalone Rails Engine gem (`mastodon-custom-feeds`)                                                                     |
| [Multi-Provider & Pull Sources Plan](multi-provider-plan.md) | **Fully implemented.** Pull source workers, multiple providers per lifecycle phase, singleton enforcement, NSFW seed task — all shipped.                          |
