# Custom Feeds System

An extensible system that lets users configure any of their Mastodon Lists as a **custom feed** with a pluggable pipeline of four lifecycle phases:

1. **Sources** — where posts originate (`followed_posts`, `remote_tag_timeline`, `remote_public_timeline`)
2. **Filters** — which posts to exclude before insertion (`interacted_posts`, `blocked_tags`, `friends_liked`)
3. **Removal Strategies** — when to remove posts already in the feed (`on_interaction`, `time_based`)
4. **Overflow Strategies** — what to do when the feed exceeds its capacity (`oldest_first`, `no_overflow`)

The New To Me feed is migrated to this system: a custom feed with `followed_posts` source + `interacted_posts` filter + `on_interaction` removal strategy + `oldest_first` overflow strategy. All NTM-specific code is deleted.

---

## Architecture Overview

```
FeedInsertWorker (home feed delivery)
  └─ CustomFeeds::FeedInsertConcern (prepended)
       └─ CustomFeeds::FeedInsertWorker.perform_async(status_id, account_id)
            ├─ Load all enabled CustomFeedConfig for account with 'followed_posts' source
            └─ For each config:
                 ├─ ::FeedManager.filter(:home, ...) guard
                 ├─ Pipeline#include?(status, account) → sources + filters
                 └─ standard: FeedManager#push_and_stream(config, status)
                    algorithmic: FeedManager#enqueue_candidate(config, status)

Scheduled pull (every pull_cadence_minutes)
  └─ CustomFeeds::PullSourceIngestWorker.perform_async(config_id)
       ├─ For each pull source step, fetch candidates per bucket
       ├─ Advance CustomFeedPullCursor
       └─ pipeline.passes_filters? → push_and_stream or enqueue_candidate

Scheduled algorithm run (every 5 minutes via Recommendations::ScheduleAlgorithmicFeedsWorker)
  └─ Recommendations::AlgorithmicFeedWorker.perform_async(config_id)
       ├─ FeedManager#dequeue_pending → candidates
       ├─ Algorithm#score_batch → scored candidates
       ├─ Algorithmic filters (min_score, top_k_per_batch)
       └─ pipeline.passes_filters? → push_and_stream

User interaction (favourite / reblog / reply)
  └─ CustomFeeds::FavouriteConcern / StatusConcern
       └─ CustomFeeds::FeedRemoveWorker.perform_async(status_id, account_id, 'favourite')
            ├─ Load all enabled CustomFeedConfig for account
            └─ For each config with matching removal strategy:
                 └─ FeedManager#remove_and_stream(config, [status_id + reblogs])

GET /api/v1/timelines/list/:id
  └─ CustomFeeds::ListControllerConcern (prepended)
       ├─ CustomFeedConfig.find_by(list: @list, enabled: true) present?
       └─ yes → CustomFeedsFeed.new(@list) — reads feed:custom:{list_id}
```

---

## Database Schema

### `custom_feed_configs`

One record per custom feed. The unique index on `list_id` enforces one custom feed per list.

```ruby
create_table :custom_feed_configs do |t|
  t.references :account, null: false, foreign_key: true
  t.references :list,    null: false, foreign_key: true, index: { unique: true }
  t.boolean    :enabled, null: false, default: true
  t.string     :feed_type, null: false, default: 'standard'  # 'standard' | 'algorithmic'
  t.datetime   :last_pulled_at
  t.integer    :pull_cadence_minutes, null: false, default: 15
  t.timestamps
end
```

### `custom_feed_steps`

Each step in the pipeline. `phase` disambiguates the four lifecycle stages. `options` holds step-specific config without requiring additional migrations.

```ruby
create_table :custom_feed_steps do |t|
  t.references :custom_feed_config, null: false, foreign_key: true
  t.string  :phase,     null: false   # 'source' | 'filter' | 'removal_strategy' | 'overflow_strategy' | 'algorithm' | 'algorithmic_filter'
  t.string  :step_type, null: false
  t.jsonb   :options,   null: false, default: {}
  t.integer :position,  null: false, default: 0
  t.timestamps
  t.index [:custom_feed_config_id, :phase, :position]
end
```

### `custom_feed_pull_cursors`

Tracks the last-fetched remote ID per pull source step and bucket, enabling incremental fetching.

```ruby
create_table :custom_feed_pull_cursors do |t|
  t.references :custom_feed_step, null: false, foreign_key: true
  t.string     :bucket,           null: false, default: ''
  t.string     :last_fetched_id
  t.datetime   :last_fetched_at
  t.timestamps
  t.index [:custom_feed_step_id, :bucket], unique: true
end
```

---

## Plugin Architecture

All step types live under `app/lib/custom_feeds/`.

### Shared `Registerable` Concern

All base classes share a single registry pattern via `CustomFeeds::Registerable` (`app/lib/custom_feeds/registerable.rb`):

```ruby
module CustomFeeds
  module Registerable
    def self.included(base)
      base.instance_variable_set(:@registry, {})
      base.extend(ClassMethods)
    end

    module ClassMethods
      def registry = @registry
      def key      = raise NotImplementedError, "#{name} must implement .key"
      def register! = registry[key] = self
    end
  end
end
```

Each base class does `include CustomFeeds::Registerable`. The registry is accessed as `SomeBase.registry['key']`. This replaces the old pattern of duplicating `REGISTRY = {}`, `self.key`, and `self.register!` in every base class.

### Source Interface

```ruby
# app/lib/custom_feeds/sources/base.rb
module CustomFeeds
  module Sources
    class Base
      include CustomFeeds::Registerable

      FetchResult = Struct.new(:max_remote_id, :statuses)

      # Override to true for sources that run on a schedule.
      def self.pull_source? = false

      # Push source interface
      def includes?(status, account, options = {}); raise NotImplementedError; end

      # Pull source interface
      # @return [FetchResult]
      def fetch_candidates(account, options = {}, since_id: nil, bucket: ''); raise NotImplementedError; end

      # Returns all bucket strings for multi-source steps (e.g. multiple domains).
      def self.buckets_for(_options) = ['']
    end
  end
end
```

Implemented sources:

| `step_type`              | Class                  | Type | Description                                                       |
| ------------------------ | ---------------------- | ---- | ----------------------------------------------------------------- |
| `followed_posts`         | `FollowedPosts`        | push | Any post that passes `::FeedManager.filter(:home, ...)`           |
| `remote_tag_timeline`    | `RemoteTagTimeline`    | pull | Fetches posts tagged with configured tag(s) from remote instances |
| `remote_public_timeline` | `RemotePublicTimeline` | pull | Fetches public timeline posts from remote instances               |

### Filter Interface

```ruby
# app/lib/custom_feeds/filters/base.rb
module CustomFeeds
  module Filters
    class Base
      include CustomFeeds::Registerable

      # Return true to EXCLUDE this status from the feed.
      def exclude?(status, account, options = {}); raise NotImplementedError; end
    end
  end
end
```

Implemented filters:

| `step_type`        | Description                                                                                          |
| ------------------ | ---------------------------------------------------------------------------------------------------- |
| `interacted_posts` | Excludes posts the account has already favourited, reblogged, or replied to                          |
| `blocked_tags`     | Excludes posts containing any of the configured tags (case-insensitive)                              |
| `friends_liked`    | Excludes posts unless at least `min_interactions` of the account's follows have liked/reblogged them |

### Removal Strategy Interface

```ruby
# app/lib/custom_feeds/removal_strategies/base.rb
module CustomFeeds
  module RemovalStrategies
    class Base
      include CustomFeeds::Registerable

      # Return true to remove the status after this interaction.
      # interaction_type: 'favourite' | 'reblog' | 'reply'
      def remove_on?(interaction_type, options = {}); raise NotImplementedError; end
    end
  end
end
```

Implemented strategies:

| `step_type`      | Description                                                                                                                  |
| ---------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `on_interaction` | Removes on any interaction (favourite, reblog, or reply)                                                                     |
| `time_based`     | Removes posts older than `duration_minutes` from their feed insertion time (checked every 5 min by `TimeBasedRemovalWorker`) |

### Overflow Strategy Interface

```ruby
# app/lib/custom_feeds/overflow_strategies/base.rb
module CustomFeeds
  module OverflowStrategies
    class Base
      include CustomFeeds::Registerable

      # Return true to block insertion when the feed is already at capacity.
      def at_capacity?(current_count, max_items, options = {}) = false

      # Called AFTER zadd to trim the feed if needed.
      def trim(redis, key, max_items, options = {}) = nil  # no-op by default
    end
  end
end
```

Two-method interface lets strategies either block insertion up-front or evict after insertion.

- **`OldestFirst`** (default): `at_capacity?` always false; `trim` calls `zremrangebyrank(key, 0, -(max_items+1))` — removes lowest-scored (oldest) entries.
- **`NoOverflow`**: `at_capacity?` returns `current_count >= max_items` — blocks new insertions once full. Useful for stable snapshot feeds.

`FeedManager#push` falls back to `OldestFirst` when no overflow strategy step is configured.

---

## Core Components

### `app/lib/custom_feeds/registerable.rb`

Shared `Registerable` concern (described above). All plugin base classes include it.

### `app/lib/custom_feeds/feed_manager.rb`

Singleton owning all Redis operations. Includes `Redisable` for the `redis` accessor.

**Redis keys:**

- `feed:custom:{list_id}` — sorted set (score = status_id, member = status_id)
- `feed:custom:{list_id}:inserted_at` — hash (status_id → unix timestamp of feed insertion)
- `feed:algo:{list_id}:pending` — sorted set for algorithmic pending queue (score = arrival timestamp)

**Methods:**

- `key(list_id)`, `inserted_at_key(list_id)`, `pending_key(list_id)` — key constructors
- `push(config, status)` — overflow-aware insert; logs at debug if at capacity; returns `false` if blocked
- `remove(config, status_id)` — `zrem` + `hdel`
- `push_and_stream(config, status)` — push + `redis.publish("timeline:list:#{list_id}", event: :update)`
- `remove_and_stream(config, ids)` — remove each + `redis.publish(…, event: 'feeds.remove', payload: id)` (uses `feeds.remove` not `delete` so the frontend removes the post only from this list timeline, not all feeds)
- `enqueue_candidate(config, status)` — adds to pending queue with dedup check and capacity eviction (logs at debug on both)
- `dequeue_pending(list_id, limit:, max_age_hours:)` — pops up to `limit` candidates younger than `max_age_hours`
- `delete_feed(list_id)` — deletes all three Redis keys; called by `CustomFeedConfig#after_destroy`

### `app/models/custom_feed_config.rb`

ActiveRecord model. `after_destroy` calls `CustomFeeds::FeedManager.instance.delete_feed(list_id)` to clean up Redis keys when a config is deleted.

Scopes: `enabled`, `standard`, `algorithmic`. Method: `steps_for(phase)`.

### `app/models/custom_feeds_feed.rb`

```ruby
class CustomFeedsFeed < Feed
  def initialize(list)
    super(:custom, list.id)
  end

  private

  def key
    CustomFeeds::FeedManager.instance.key(@id)
  end
end
```

### `app/lib/custom_feeds/pipeline.rb`

Wraps a `CustomFeedConfig`, evaluates sources/filters/removal/overflow for a status. Adds debug logging at each decision point (source rejection, filter exclusion).

```ruby
def initialize(config)
  @algorithmic     = config.feed_type == 'algorithmic'
  @source_entries  = build_entries(config, 'source',           Sources::Base.registry)
  @filter_entries  = build_entries(config, 'filter',           Filters::Base.registry)
  @removal_entries = build_entries(config, 'removal_strategy', RemovalStrategies::Base.registry)
  overflow_step    = config.steps_for('overflow_strategy').first
  overflow_klass   = overflow_step ? OverflowStrategies::Base.registry[overflow_step.step_type] : nil
  @overflow        = (overflow_klass || OverflowStrategies::OldestFirst).new
end

def include?(status, account)      # push sources + all filters; logs rejection reason
def passes_filters?(status, account) # filters only; used by pull ingest and algo worker
def pull_sources?                  # true if any pull source step
def pull_source_entries            # [{instance:, klass:, options:, step:}] for pull steps
def remove_on?(interaction_type)   # delegates to removal strategy instances
def algorithmic?                   # true for algorithmic feeds
attr_reader :overflow
```

---

## Workers

### `app/workers/custom_feeds/feed_insert_worker.rb`

Queue: `push`, retry: 3. Called once per home-feed delivery; handles **all** custom feeds for the account in a single job.

```
perform(status_id, account_id)
  with_primary: load status, account
  with_read_replica:
    return unless account.user&.signed_in_recently?
    return if ::FeedManager.instance.filter(:home, status, account)
    for each enabled config with 'followed_posts' source:
      pipeline = Pipeline.new(config)
      next unless pipeline.include?(status, account)
      if algorithmic: FeedManager#enqueue_candidate   (→ pending queue)
      else:           FeedManager#push_and_stream      (→ live feed)
rescue ActiveRecord::RecordNotFound → log at debug
```

### `app/workers/custom_feeds/feed_remove_worker.rb`

Queue: `default`, retry: 3. Handles **all** custom feeds for the account. Per-config errors are caught and logged without aborting the loop.

```
perform(status_id, account_id, interaction_type)
  account = Account.find(account_id)
  ids_to_remove = [status_id] + Status.where(reblog_of_id: status_id).pluck(:id)
  for each enabled config:
    pipeline = Pipeline.new(config)
    next unless pipeline.remove_on?(interaction_type)
    FeedManager#remove_and_stream(config, ids_to_remove)
  rescue (per-config) → log at error
rescue ActiveRecord::RecordNotFound → log at debug
```

### `app/workers/custom_feeds/pull_source_ingest_worker.rb`

Queue: `pull`, retry: 3. Fetches candidates from pull sources, advances cursors, runs filter pipeline, and pushes/enqueues. Logs start, per-bucket fetch counts, dedup, and final promoted/filtered summary.

```
perform(config_id)
  config = CustomFeedConfig.find_by(id: config_id) — return unless enabled
  return unless account.user&.signed_in_recently?
  pipeline = Pipeline.new(config)
  return unless pipeline.pull_sources?

  for each pull_source_entry:
    for each bucket:
      cursor = CustomFeedPullCursor.for_step_bucket(step, bucket)
      result = source.fetch_candidates(…, since_id: cursor.last_fetched_id)
      cursor.update!(last_fetched_id: result.max_remote_id)
      all_candidates.concat(result.statuses)

  config.update_column(:last_pulled_at, Time.current)
  deduped = all_candidates deduplicated by id

  for each status in deduped:
    next if blocking/muting/domain-blocking
    next unless pipeline.passes_filters?(status, account)
    if algorithmic: enqueue_candidate  else: push_and_stream
rescue ActiveRecord::RecordNotFound → log at debug
```

### `app/workers/custom_feeds/time_based_removal_worker.rb`

Queue: `scheduler`, retry: 1. Runs every 5 minutes. Uses `HSCAN` + per-entry `ZSCORE` to avoid loading the full feed into memory (avoids the N×5000 Ruby Set allocation of the previous implementation). Also cleans up orphaned `inserted_at` hash entries left by overflow trimming.

### `app/workers/custom_feeds/stats_collector_worker.rb`

Queue: `scheduler`, retry: false. Runs every 5 minutes. Scans Redis for feed keys, samples per-key memory usage, queries PostgreSQL table sizes, and emits Prometheus gauges via `CustomFeeds::Metrics`.

---

## Concerns

### `app/lib/custom_feeds/feed_insert_concern.rb`

Prepended into `FeedInsertWorker`. Triggers `CustomFeeds::FeedInsertWorker` on every `:home` delivery.

### `app/lib/custom_feeds/favourite_concern.rb`

Included into `Favourite`. Enqueues `FeedRemoveWorker` with `'favourite'` and `SignalWorker` on create.

### `app/lib/custom_feeds/status_concern.rb`

Included into `Status`. On create by a local account:

- reblog → `FeedRemoveWorker('reblog')` + `SignalWorker('reblog')`
- reply → `FeedRemoveWorker('reply')` + `SignalWorker('reply')`

Also adds a public `original_status` instance method to `Status`:

```ruby
def original_status
  reblog? ? reblog : self
end
```

This replaces the inline `status.reblog? ? status.reblog : status` pattern previously duplicated across filters, workers, and algorithms.

### `app/lib/custom_feeds/list_controller_concern.rb`

Prepended into `Api::V1::Timelines::ListController`. Checks the database for a `CustomFeedConfig`; any list with one becomes a custom feed regardless of its title.

---

## Settings API

Controller at `app/controllers/api/v1/custom_feeds_controller.rb`.

```
GET    /api/v1/custom_feeds       — index: all configs for current user
POST   /api/v1/custom_feeds       — create
GET    /api/v1/custom_feeds/:id   — show
PATCH  /api/v1/custom_feeds/:id   — update
DELETE /api/v1/custom_feeds/:id   — destroy
```

Steps are replaced wholesale on update. Authorization: Pundit `CustomFeedConfigPolicy` — owner-only.

### Recommendation Signals API

Controller at `app/controllers/api/v1/recommendation_signals_controller.rb`.

```
GET    /api/v1/recommendation_signals       — index: all signals for current user
POST   /api/v1/recommendation_signals       — create / upsert
PATCH  /api/v1/recommendation_signals/:id   — update weight
DELETE /api/v1/recommendation_signals/:id   — destroy
```

Used by the Signals settings page to let users view and adjust their algorithm's learned affinities.

---

## Settings Page (Frontend)

React feature at `app/javascript/mastodon/features/custom_feeds_settings/`.

Route: `/custom_feeds`. Linked from the navigation panel with a `TuneIcon`, below Followed Tags. The column header has a settings cog that links to `/custom_feeds/signals`.

### Components

| Component                         | Purpose                                                                                                                                           |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `index.tsx`                       | Page container: `Column` + `ColumnHeader` + `ScrollableList`. Fetches configs and lists on mount.                                                 |
| `components/custom_feed_card.tsx` | Row showing list name + "Disabled" badge. Edit/delete buttons. Clicking list title links to the list timeline. Inline edit expands below the row. |
| `components/custom_feed_form.tsx` | Create/edit form with `SelectField` dropdowns per phase. Supports inline list creation.                                                           |

### Form Layout

Each phase is a `SelectField` dropdown:

| Field             | Phase               | Options                                                                           |
| ----------------- | ------------------- | --------------------------------------------------------------------------------- |
| List picker       | —                   | User's lists without an existing config (create only) or inline new list creation |
| Post source       | `source`            | Followed accounts (home feed)                                                     |
| Filter            | `filter`            | None · Hide already-interacted posts                                              |
| Removal strategy  | `removal_strategy`  | None · Remove on interaction · Remove after set time                              |
| When feed is full | `overflow_strategy` | Remove oldest first · Stop adding when full                                       |
| Feed enabled      | —                   | `ToggleField` (edit only)                                                         |

The "Remove after set time" option renders a number input + unit select inline. Both fields use `flex: 1; min-width: 60px` for equal width and visible input.

### Algorithm Signals Settings (`/custom_feeds/signals`)

React feature at `app/javascript/mastodon/features/custom_feeds_signals/`. Displays the account's `recommendation_signals` grouped by type (tag, account, domain) with per-signal weight controls. Allows manual weight overrides and deletion.

### Redux

- `app/javascript/mastodon/actions/custom_feeds.ts` — `fetchCustomFeeds`, `createCustomFeed`, `updateCustomFeed`, `deleteCustomFeed`
- `app/javascript/mastodon/reducers/custom_feeds.ts` — normalised by config ID
- `app/javascript/mastodon/actions/streaming.js` — handles `feeds.remove` event: calls `timelineDeleteStatus` scoped to `list:${listId}` so only that list timeline is updated (not home, public, etc.)

### i18n

All strings under `custom_feeds.*` in `en.json`. Key groups: `heading`, `form.*`, `sources.*`, `filters.*`, `removal_strategies.*`, `overflow.*`, `option.none`, `card.*`, `signals.*`.

---

## Initializer

`config/initializers/custom_feeds.rb`:

```ruby
Rails.application.config.to_prepare do
  # Sources
  CustomFeeds::Sources::FollowedPosts.register!
  CustomFeeds::Sources::RemoteTagTimeline.register!
  CustomFeeds::Sources::RemotePublicTimeline.register!
  # Filters
  CustomFeeds::Filters::InteractedPosts.register!
  CustomFeeds::Filters::FriendsLiked.register!
  CustomFeeds::Filters::BlockedTags.register!
  # Removal strategies
  CustomFeeds::RemovalStrategies::OnInteraction.register!
  CustomFeeds::RemovalStrategies::TimeBased.register!
  # Overflow strategies
  CustomFeeds::OverflowStrategies::OldestFirst.register!
  # Algorithms
  Recommendations::Algorithms::AffinityScore.register!

  # Wire concerns into existing classes
  Api::V1::Timelines::ListController.prepend(CustomFeeds::ListControllerConcern)
  FeedInsertWorker.prepend(CustomFeeds::FeedInsertConcern)
  Favourite.include(CustomFeeds::FavouriteConcern)
  Status.include(CustomFeeds::StatusConcern)
end
```

---

## Metrics

`app/lib/custom_feeds/metrics.rb` — thin client wrapper around `PrometheusExporter::Client`. Guards with `enabled?` and bare `rescue` so metrics never raise into the main execution path.

`app/workers/custom_feeds/stats_collector_worker.rb` — samples Redis memory and PostgreSQL table sizes every 5 minutes.

See `customizations/monitoring.md` for the full metric reference and Grafana dashboard details.

---

## File List

### Backend — `app/lib/custom_feeds/`

| File                                   | Purpose                                                                                    |
| -------------------------------------- | ------------------------------------------------------------------------------------------ |
| `registerable.rb`                      | Shared REGISTRY/key/register! concern for all base classes                                 |
| `feed_manager.rb`                      | Redis operations (push, remove, stream, pending queue, delete_feed)                        |
| `pipeline.rb`                          | Evaluates sources, filters, removal/overflow strategies with debug logging                 |
| `metrics.rb`                           | Prometheus metrics client helper                                                           |
| `sources/base.rb`                      | Source interface; `FetchResult` struct; `resolve_uris`                                     |
| `sources/followed_posts.rb`            | Home-feed delivery source                                                                  |
| `sources/remote_tag_timeline.rb`       | Pull source: fetches tag timeline from remote instance                                     |
| `sources/remote_public_timeline.rb`    | Pull source: fetches public timeline from remote instance                                  |
| `filters/base.rb`                      | Filter interface                                                                           |
| `filters/interacted_posts.rb`          | Exclude if already interacted                                                              |
| `filters/blocked_tags.rb`              | Exclude if post contains blocked tags                                                      |
| `filters/friends_liked.rb`             | Include only if min N follows liked/reblogged (caches following IDs per instance lifetime) |
| `removal_strategies/base.rb`           | Removal strategy interface                                                                 |
| `removal_strategies/on_interaction.rb` | Remove on any interaction                                                                  |
| `removal_strategies/time_based.rb`     | Descriptor; logic in TimeBasedRemovalWorker                                                |
| `overflow_strategies/base.rb`          | Overflow strategy interface                                                                |
| `overflow_strategies/oldest_first.rb`  | Evict oldest on overflow (default)                                                         |
| `overflow_strategies/no_overflow.rb`   | Block insertion when at capacity                                                           |
| `feed_insert_concern.rb`               | Prepended into FeedInsertWorker                                                            |
| `list_controller_concern.rb`           | Intercepts list timeline API                                                               |
| `favourite_concern.rb`                 | Enqueues FeedRemoveWorker + SignalWorker on favourite                                      |
| `status_concern.rb`                    | Enqueues FeedRemoveWorker + SignalWorker on reblog/reply; adds `original_status` to Status |

### Backend — `app/lib/recommendations/algorithms/`

| File                | Purpose                                                                           |
| ------------------- | --------------------------------------------------------------------------------- |
| `base.rb`           | Algorithm interface (includes `CustomFeeds::Registerable`); `score_batch` default |
| `affinity_score.rb` | Weighted tag/account/domain affinity with time decay; single DB query per batch   |

### Backend — Models / Controllers / Workers

| File                                                               | Purpose                                       |
| ------------------------------------------------------------------ | --------------------------------------------- |
| `app/models/custom_feeds_feed.rb`                                  | Feed model                                    |
| `app/models/custom_feed_config.rb`                                 | Config model; `after_destroy` → Redis cleanup |
| `app/models/custom_feed_step.rb`                                   | Pipeline step model                           |
| `app/models/custom_feed_pull_cursor.rb`                            | Per-step-bucket fetch cursor                  |
| `app/models/recommendation_signal.rb`                              | Signal weight storage                         |
| `app/workers/custom_feeds/feed_insert_worker.rb`                   | Push-path insert worker                       |
| `app/workers/custom_feeds/feed_remove_worker.rb`                   | Removal worker                                |
| `app/workers/custom_feeds/pull_source_ingest_worker.rb`            | Pull-source scheduled worker                  |
| `app/workers/custom_feeds/time_based_removal_worker.rb`            | Time-based removal scheduler (HSCAN/ZSCORE)   |
| `app/workers/custom_feeds/stats_collector_worker.rb`               | Prometheus metric sampler                     |
| `app/workers/recommendations/signal_worker.rb`                     | Records interaction signals                   |
| `app/workers/recommendations/algorithmic_feed_worker.rb`           | Scores and promotes pending candidates        |
| `app/workers/recommendations/schedule_algorithmic_feeds_worker.rb` | Periodic algo worker trigger                  |
| `app/controllers/api/v1/custom_feeds_controller.rb`                | Custom feeds CRUD API                         |
| `app/controllers/api/v1/recommendation_signals_controller.rb`      | Signals CRUD API                              |
| `app/policies/custom_feed_config_policy.rb`                        | Pundit: owner-only access                     |
| `app/serializers/rest/custom_feed_config_serializer.rb`            | API serializer                                |
| `app/serializers/rest/recommendation_signal_serializer.rb`         | Signals API serializer                        |
| `config/initializers/custom_feeds.rb`                              | Registers all step types; wires concerns      |
| `lib/mastodon/prometheus_exporter/custom_feeds_collector.rb`       | TypeCollector for custom feed metrics         |
| `lib/mastodon/prometheus_exporter/local_server.rb`                 | Extended: `register_collector` for dev mode   |

---

## Key Design Decisions

**`Registerable` concern.** A single module replaces the identical `REGISTRY = {}` / `self.key` / `self.register!` boilerplate that existed in every base class. Registry is accessed as `SomeBase.registry['key']`.

**`original_status` on Status.** `StatusConcern` injects a public `original_status` helper that resolves reblogs. Filters and algorithms use this instead of inline `status.reblog? ? status.reblog : status`. If Mastodon upstream ever adds an equivalent, it can be removed from the concern without touching call sites.

**Redis keyed by `list_id`, not `account_id`.** Avoids collisions when an account has multiple custom feeds; the key is derivable from the list object alone.

**One `FeedInsertWorker` job per delivery handles all configs.** Cuts Sidekiq queue volume proportionally as users add more custom feeds.

**`delete_feed` on config destroy.** `CustomFeedConfig#after_destroy` calls `FeedManager#delete_feed`, which removes all three Redis keys (`feed:custom:*`, `feed:custom:*:inserted_at`, `feed:algo:*:pending`). Prevents Redis key leaks.

**`feeds.remove` streaming event.** `remove_and_stream` publishes `event: 'feeds.remove'` instead of the standard `'delete'`. The frontend handler calls `timelineDeleteStatus` scoped to the specific list timeline, so the post is not purged from the home feed or other timelines.

**`TimeBasedRemovalWorker` uses HSCAN + ZSCORE.** Avoids loading the entire feed into a Ruby `Set` (previously O(5000) allocation per config per run). The HSCAN loop visits hash entries in cursor batches; each entry is checked with a single O(log N) `ZSCORE` call.

**`FriendsLiked` caches following IDs.** The filter is instantiated once per pipeline build (one worker job). `@following_ids_cache[account.id]` avoids repeated `account.following.pluck(:id)` calls across candidates in the same batch.

**Pull sources use bucket cursors.** `CustomFeedPullCursor` tracks `last_fetched_id` per step+bucket, enabling incremental fetching. Cursors are always advanced from the raw API response ID (not the resolved status ID) so transient federation gaps don't cause re-fetching.

**Overflow strategy defaults to `OldestFirst`.** `Pipeline` falls back when no overflow strategy step is configured, so feeds created before overflow strategies were added continue to behave correctly.

**Constant resolution.** Inside `module CustomFeeds`, bare `FeedManager` resolves to `CustomFeeds::FeedManager`. All references to the stock Mastodon feed manager use `::FeedManager`.
