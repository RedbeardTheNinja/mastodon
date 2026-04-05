# Customizations

Server-specific features and modifications built on top of the Mastodon source code for redbeardthe.ninja. Each entry below links to a document describing the feature, the files it touches, and relevant design decisions.

## Index

| Feature                                                      | Description                                                                                                                                                       |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Custom Feeds System](custom-feeds.md)                       | Extensible pluggable-pipeline system for custom algorithmic feeds backed by any Mastodon List                                                                     |
| [Algorithmic Feeds](recommendations.md)                      | New `algorithmic` feed type that stages candidates in a pending queue, scores them with pluggable algorithms (affinity scoring, optional Naive Bayes via `rumale`), and applies score-aware filters before promotion. Signals are collected from boosts, replies, and likes. |
| [Plugin Plan](plugin-plan.md)                                | Plan for extracting Custom Feeds into a standalone Rails Engine gem (`mastodon-custom-feeds`)                                                                     |
| [Multi-Provider & Pull Sources Plan](multi-provider-plan.md) | **Fully implemented.** Pull source workers, multiple providers per lifecycle phase, singleton enforcement, NSFW seed task — all shipped.                          |
