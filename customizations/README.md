# Customizations

Server-specific features and modifications built on top of the Mastodon source code for redbeardthe.ninja. Each entry below links to a document describing the feature, the files it touches, and relevant design decisions.

## Features

| Feature                                                      | Description                                                                                                                                                                                                                                           |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Custom Feeds System](custom-feeds.md)                       | Extensible pluggable-pipeline system for custom algorithmic feeds backed by any Mastodon List. Includes push and pull sources, multiple filter types, removal strategies, overflow strategies, and algorithmic feeds.                                 |
| [Algorithmic Feeds](recommendations.md)                      | `algorithmic` feed type that stages candidates in a pending queue, scores them with pluggable algorithms (affinity scoring implemented; Naive Bayes future work), and applies score-aware filters. Signals collected from boosts, replies, and likes. |
| [Monitoring](monitoring.md)                                  | Prometheus/Grafana stack measuring custom feed performance impact vs home feed baseline. Scrapes Rails, Sidekiq, Redis, and system metrics from the production server.                                                                                |
| [Plugin Plan](plugin-plan.md)                                | Plan for extracting Custom Feeds into a standalone Rails Engine gem (`mastodon-custom-feeds`)                                                                                                                                                         |
| [Multi-Provider & Pull Sources Plan](multi-provider-plan.md) | **Fully implemented.** Pull source workers, multiple providers per lifecycle phase, singleton enforcement, NSFW seed task — all shipped.                                                                                                              |

---

## Unclassified Customizations

Changes that do not belong to a specific named feature — configuration, tooling, documentation, and minor patches.

### Claude Code configuration (`.claude/`)

AI assistant context files checked into the repo so Claude Code has accurate environment knowledge across sessions.

| File                           | Purpose                                                                                                                                                                       |
| ------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `CLAUDE.md`                    | Root project instructions: stack overview, command reference, architecture notes, key conventions (constant resolution, reblog normalisation, etc.)                           |
| `.claude/env-dev-container.md` | Environment guide for the Windows/Docker dev container (`devcontainer-app-1`). Describes how to run commands, apply migrations, restart services, and deploy.                 |
| `.claude/env-production.md`    | Environment guide for the production server (`redbeardthe.ninja`). Covers rbenv Ruby, systemd service management, deploy commands, and default `sudo -u mastodon` convention. |
| `.claude/settings.local.json`  | Local Claude Code settings (tool permissions, hooks). Not committed on main — present only on `personal`.                                                                     |

### Rubocop overrides (`.rubocop.yml`)

Added `db/schema.rb` and `db/migrate/**/*` to the `AllCops` exclusion list so the auto-annotator and generated migration files do not trigger lint failures.

### Timeline architecture explainer (`timeline_explainer.md`)

Root-level reference document tracing the full journey of a remote post from ActivityPub ingestion through fan-out into Redis home-feed sorted sets. Written as a codebase orientation aid; not user-facing.

### Custom Feeds UI wiring

The Custom Feeds settings page is a new React route added to the main SPA. The following files were changed to integrate it:

| File                                                                | Change                                                                                                                                              |
| ------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `app/javascript/mastodon/features/navigation_panel/index.tsx`       | Added "Custom Feeds" nav link (tune icon, `/custom_feeds` route)                                                                                    |
| `app/javascript/mastodon/features/ui/index.jsx`                     | Registered `<WrappedRoute path='/custom_feeds'>` pointing to `CustomFeedsSettings`                                                                  |
| `app/javascript/mastodon/features/ui/util/async-components.js`      | Added `CustomFeedsSettings` async import for code-splitting                                                                                         |
| `app/javascript/mastodon/actions/streaming.js`                      | Added `feeds.remove` streaming event handler — removes a status only from the specific list timeline (not all timelines) via `timelineDeleteStatus` |
| `app/javascript/styles/mastodon/components.scss`                    | Added `.phase-section` styles for the custom feed step editor                                                                                       |
| `app/javascript/styles/mastodon/forms.scss`                         | Minor `color-scheme: inherit` fix for select inputs in the feed settings form                                                                       |
| `app/javascript/mastodon/components/form_fields/select.module.scss` | Select field stylesheet used by the custom feed form                                                                                                |

### Development seed task (`lib/tasks/dev.rake` — `dev:seed_custom_feeds`)

Replaces the old `dev:setup_new_to_me` task. Seeds two custom feeds for the admin account:

- **New To Me** (standard feed) — `followed_posts` source, `interacted_posts` filter, `on_interaction` removal. 4 test posts pushed directly into Redis.
- **Algorithm Test** (algorithmic feed) — `followed_posts` source routed to pending queue, `affinity_score` algorithm, `min_signals: 2`, `min_score: 5.0`. Pre-seeds `tag:algorithmtest` and `account:algo_poster` signals with weight 6.0 each (simulating 3 reblogs). Two posts tagged `#algorithmtest` score ~12.0 and are promoted; two posts from an unknown author score ~0.0 and are filtered out. Set `ALGO_FEED_RUN_WORKER=1` to run the algorithm worker inline and print promoted vs expected IDs. Safe to run multiple times.

### NSFW feed seed task (`lib/tasks/custom_feeds_seed.rake` — `custom_feeds:seed_nsfw`)

One-shot task that creates an NSFW custom feed on the admin account backed by `remote_tag_timeline` sources pulling `#nsfw` from `mastodon.social` and `mastodon.art`. Intended for initial server setup.
