# Customizations

Server-specific features and modifications built on top of the Mastodon source code for redbeardthe.ninja. Each entry below links to a document describing the feature, the files it touches, and relevant design decisions.

## Index

| Feature                                                      | Description                                                                                                                                                       |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Custom Feeds System](custom-feeds.md)                       | Extensible pluggable-pipeline system for custom algorithmic feeds backed by any Mastodon List                                                                     |
| [Recommendations](recommendations.md)                        | Pull sources and scoring filters that extend the custom feeds pipeline to surface posts from remote servers, ranked by follows' engagement or algorithmic scoring |
| [Plugin Plan](plugin-plan.md)                                | Plan for extracting Custom Feeds into a standalone Rails Engine gem (`mastodon-custom-feeds`)                                                                     |
| [Multi-Provider & Pull Sources Plan](multi-provider-plan.md) | Implementation plan for pull source workers, multiple providers per lifecycle phase, singleton enforcement, and NSFW seed task                                    |
