# Recommendations as Custom Feed Plugins

Recommendation feeds are implemented as **custom feed sources and filters**, not as a separate parallel system. A "Recommendations" feed is an ordinary `CustomFeedConfig` tied to any Mastodon List, configured via the Custom Feeds settings page with one or more pull sources and a scoring filter.

This replaces the original standalone `Recommendations::*` architecture. The separate `recommendation_configs` table, `Recommendations::FeedManager`, `Recommendations::ListControllerConcern`, and `config/initializers/recommendations.rb` are all eliminated. Everything flows through the existing custom feeds pipeline.

---

## What the User Configures

In the Custom Feeds settings page, a user creates a config on any list and sets:

| Phase    | Option                          | Example                                                       |
| -------- | ------------------------------- | ------------------------------------------------------------- |
| Source   | `remote_public_timeline`        | mastodon.social public timeline                               |
| Source   | `remote_tag_timeline`           | mastodon.social posts tagged `#rustlang`                      |
| Filter   | `friends_liked`                 | Only posts that at least 1 follow has favourited or reblogged |
| Filter   | `recommendation_score`          | Algorithmic scoring; exclude posts below threshold            |
| Removal  | `on_interaction`                | Remove once you favourite/boost/reply                         |
| Overflow | `oldest_first` or `no_overflow` | Standard overflow behavior                                    |

Sources and filters can be combined freely. A config with a `remote_public_timeline` source and a `friends_liked` filter gives a feed of posts from that server that your follows have already engaged with. Adding a `recommendation_score` filter narrows it further by score.

Each source and filter step stores its parameters in the `custom_feed_steps.options` JSONB column — no additional tables required for configuration.

---

## Push Sources vs Pull Sources

The existing pipeline has one trigger: `FeedInsertWorker` fires on home-feed delivery (push). Remote timeline sources cannot use this trigger because they pull from external HTTP APIs on a schedule.

The `Sources::Base` class gains a class-level flag:

```ruby
module CustomFeeds
  module Sources
    class Base
      REGISTRY = {}

      # Pull sources fetch candidates proactively via SchedulePullSourcesWorker.
      # Push sources are triggered reactively per home-feed delivery.
      def self.pull_source?
        false
      end

      def self.key; raise NotImplementedError; end
      def self.register!; REGISTRY[key] = self; end

      # Push source interface — called by FeedInsertWorker.
      def includes?(status, account, options = {}); raise NotImplementedError; end

      # Pull source interface — called by PullSourceIngestWorker.
      # Returns an array of resolved Status records to run through the filter pipeline.
      # since_id is the Mastodon ID from the last successful run (cursor).
      def fetch_candidates(account, options = {}, since_id: nil)
        raise NotImplementedError
      end
    end
  end
end
```

`FeedInsertWorker` already skips configs whose source steps are all pull sources. `PullSourceIngestWorker` only processes configs that have at least one pull source step.

A single config can mix both types (e.g., `followed_posts` push source + `remote_public_timeline` pull source on the same list). Each insertion path runs independently; the shared filter pipeline evaluates every candidate regardless of which source produced it.

---

## New Source Implementations

### `CustomFeeds::Sources::RemotePublicTimeline`

```ruby
# app/lib/custom_feeds/sources/remote_public_timeline.rb
module CustomFeeds
  module Sources
    class RemotePublicTimeline < Base
      def self.key; 'remote_public_timeline'; end
      def self.pull_source?; true; end

      # options keys:
      #   domain (string, required)  — e.g. 'mastodon.social'
      #   local_only (bool, default true) — fetch &local=true
      #   limit_per_run (int, default 40) — posts per fetch

      def fetch_candidates(account, options = {}, since_id: nil)
        domain    = options.fetch('domain')
        local     = options.fetch('local_only', true)
        limit     = [options.fetch('limit_per_run', 40).to_i, 80].min

        url = "https://#{domain}/api/v1/timelines/public"
        params = { limit: limit, local: local }
        params[:since_id] = since_id if since_id

        response = HTTP.timeout(10).get(url, params: params)
        return [] unless response.status.success?

        uris = JSON.parse(response.body).map { |s| s['uri'] }
        resolve_uris(uris)
      end

      private

      def resolve_uris(uris)
        uris.filter_map do |uri|
          ResolveStatusService.new.call(uri)
        rescue
          nil
        end
      end
    end
  end
end
```

### `CustomFeeds::Sources::RemoteTagTimeline`

```ruby
# app/lib/custom_feeds/sources/remote_tag_timeline.rb
module CustomFeeds
  module Sources
    class RemoteTagTimeline < Base
      def self.key; 'remote_tag_timeline'; end
      def self.pull_source?; true; end

      # options keys:
      #   domain (string, required)
      #   tag    (string, required)  — without the leading #
      #   limit_per_run (int, default 40)

      def fetch_candidates(account, options = {}, since_id: nil)
        domain = options.fetch('domain')
        tag    = options.fetch('tag').delete_prefix('#')
        limit  = [options.fetch('limit_per_run', 40).to_i, 80].min

        url = "https://#{domain}/api/v1/timelines/tag/#{CGI.escape(tag)}"
        params = { limit: limit }
        params[:since_id] = since_id if since_id

        response = HTTP.timeout(10).get(url, params: params)
        return [] unless response.status.success?

        uris = JSON.parse(response.body).map { |s| s['uri'] }
        uris.filter_map { |uri| ResolveStatusService.new.call(uri) rescue nil }
      end
    end
  end
end
```

---

## New Filter Implementations

### `CustomFeeds::Filters::FriendsLiked`

Excludes a post unless at least `min_interactions` of the user's follows have favourited or reblogged it. Queries local Mastodon data only — no external API calls.

```ruby
# app/lib/custom_feeds/filters/friends_liked.rb
module CustomFeeds
  module Filters
    class FriendsLiked < Base
      def self.key; 'friends_liked'; end

      # options keys:
      #   min_interactions (int, default 1)

      def exclude?(status, account, options = {})
        min = options.fetch('min_interactions', 1).to_i
        original = status.reblog? ? status.reblog : status
        following_ids = account.following.pluck(:id)

        fav_count = Favourite.where(account_id: following_ids, status_id: original.id).count
        return false if fav_count >= min

        reblog_count = Status.where(account_id: following_ids, reblog_of_id: original.id).count
        (fav_count + reblog_count) < min
      end
    end
  end
end
```

When used as a filter on a `remote_public_timeline` source, this produces a feed of "posts from that server that people you follow have already engaged with" — the FriendsLiked algorithm, implemented as a filter.

**Performance note:** For batch ingest runs, `PullSourceIngestWorker` passes candidates through the pipeline one by one, but the two `COUNT` queries per candidate can be expensive at high volumes. A future optimisation is to batch-load the interaction sets before the loop and check in-memory.

### `CustomFeeds::Filters::RecommendationScore`

Scores candidates using a registered algorithm and excludes those below `min_score`.

```ruby
# app/lib/custom_feeds/filters/recommendation_score.rb
module CustomFeeds
  module Filters
    class RecommendationScore < Base
      def self.key; 'recommendation_score'; end

      # options keys:
      #   algorithm  (string, default 'friends_liked_score')
      #   min_score  (float,  default 0.5)

      def exclude?(status, account, options = {})
        algo_key   = options.fetch('algorithm', 'friends_liked_score')
        min_score  = options.fetch('min_score', 0.5).to_f
        algo_class = Recommendations::Algorithms::REGISTRY[algo_key]
        return true if algo_class.nil?  # unknown algorithm → exclude

        score = algo_class.new(account).score_one(status)
        score < min_score
      end
    end
  end
end
```

The algorithm classes live in `app/lib/recommendations/algorithms/` and are registered in a separate `REGISTRY` hash (not the custom feeds source/filter registries). They expose a `score_one(status)` method in addition to the existing batch `score(candidates)` method.

This filter works for both push-source and pull-source pipelines, but it is only cost-effective on pull-source feeds where candidates are pre-selected by a source (e.g., `remote_public_timeline`). Applying it to a `followed_posts` push source would score every incoming home-feed post in real time — acceptable for simple algorithms like `FriendsLiked`, but expensive for anything involving ML inference.

---

## Recommendation Algorithms

Algorithms are kept in `app/lib/recommendations/algorithms/` as a separate registry under the `Recommendations` namespace. They are not custom feed source/filter classes themselves; instead they are called by `RecommendationScore` filter. This keeps scoring logic isolated from the pipeline infrastructure.

### `Recommendations::Algorithms::REGISTRY`

```ruby
# app/lib/recommendations.rb
module Recommendations
  module Algorithms
    REGISTRY = {}
  end
end
```

### `Recommendations::Algorithms::Base`

```ruby
module Recommendations
  module Algorithms
    class Base
      def self.key; raise NotImplementedError; end
      def self.register!; REGISTRY[key] = self; end

      def initialize(account)
        @account = account
      end

      # Score a single status. Used by the RecommendationScore filter in real-time or batch pipelines.
      def score_one(status)
        0.0
      end

      # Score a batch of statuses. Returns [{status_id:, score:}].
      # Default implementation calls score_one for each; subclasses can override for batch efficiency.
      def score(candidates)
        candidates.map { |s| { status_id: s.id, score: score_one(s) } }
      end

      # Called after user interactions to update RecommendationSignal rows.
      def learn(interaction_type, status); end
    end
  end
end
```

### `Recommendations::Algorithms::FriendsLikedScore`

Scores by follows' engagement weighted by time decay. Same logic as the old `Recommendations::Algorithms::FriendsLiked`.

```
score = (fav_count_by_following * 1.0 + reblog_count_by_following * 2.0)
        * exp(-0.5 * age_in_days)
```

Falls back to a small base score derived from the post's raw `favourites_count` / `reblogs_count` stats if no local signal is found. Used by the `recommendation_score` filter when `algorithm: 'friends_liked_score'`.

---

## Cursor Tracking for Pull Sources

Pull sources need a per-(step, run) cursor so each ingest only fetches posts newer than the last run.

### New table: `custom_feed_pull_cursors`

```ruby
create_table :custom_feed_pull_cursors do |t|
  t.references :custom_feed_step, null: false, foreign_key: true, index: { unique: true }
  t.string  :last_fetched_id    # Mastodon status ID used as since_id in the next fetch
  t.datetime :last_fetched_at
  t.timestamps
end
```

One row per pull-source step. The cursor is updated atomically at the end of a successful ingest run for that step.

---

## Recommendation Signal Table

Kept from the original design for learning algorithms.

```ruby
create_table :recommendation_signals do |t|
  t.references :account, null: false, foreign_key: true
  t.string  :signal_type,       null: false  # 'author_affinity' | 'tag_affinity' | 'domain_affinity'
  t.string  :entity_type,       null: false  # 'account' | 'tag' | 'domain'
  t.string  :entity_id,         null: false
  t.float   :weight,            null: false, default: 0.0
  t.integer :observation_count, null: false, default: 0
  t.datetime :last_observed_at
  t.timestamps
  t.index [:account_id, :signal_type, :entity_type, :entity_id],
          unique: true, name: 'idx_rec_signals_lookup'
end
```

`RecommendationSignal.for_account(account_id, signal_type)` returns `{entity_id => weight}` for efficient lookup during scoring. Algorithms call this in `score_one` / `score` to personalise results over time.

---

## Workers

### `app/workers/custom_feeds/schedule_pull_sources_worker.rb`

Sidekiq queue: `scheduler`, retry: 0. Runs on a cron schedule (e.g. every 15 minutes).

Finds all enabled `CustomFeedConfig` records that have at least one pull-source step, and enqueues `PullSourceIngestWorker` per config, staggered to avoid thundering herd:

```ruby
configs = CustomFeedConfig
  .enabled
  .joins(:custom_feed_steps)
  .where(custom_feed_steps: { phase: 'source' })
  .where(
    CustomFeedStep
      .where('custom_feed_steps.custom_feed_config_id = custom_feed_configs.id')
      .where(phase: 'source')
      .where(step_type: CustomFeeds::Sources::Base::REGISTRY
               .select { |_, klass| klass.pull_source? }.keys)
      .arel.exists
  )
  .distinct

configs.each_with_index do |config, i|
  PullSourceIngestWorker.perform_in(i * 2.seconds, config.id)
end
```

### `app/workers/custom_feeds/pull_source_ingest_worker.rb`

Sidekiq queue: `recommendations`, retry: 3.

**Flow:**

1. Load `CustomFeedConfig`; return if not found or disabled.
2. Return unless account user is recently active (`signed_in_recently?`).
3. Build pipeline: `pipeline = CustomFeeds::Pipeline.new(config)`.
4. For each pull-source step in `config.steps_for('source')`:
   a. Instantiate source class: `source = Sources::Base::REGISTRY[step.step_type].new`.
   b. Load or create `CustomFeedPullCursor` for the step.
   c. Call `source.fetch_candidates(account, step.options, since_id: cursor.last_fetched_id)`.
   d. Collect resolved `Status` candidates.
   e. Update cursor `last_fetched_id` (max ID from fetched statuses) and `last_fetched_at`.
5. Deduplicate candidates across all pull sources in this config.
6. Apply home feed filter guard: skip candidates that would fail `::FeedManager.filter(:home, status, account)`.
7. For each candidate: run through the shared filter pipeline via `pipeline.include?(status, account)`.
8. Insert passing candidates: `CustomFeeds::FeedManager.instance.push_and_stream(config, status)`.

**Error handling:** HTTP errors per source step are rescued and logged; the worker continues with remaining steps. `ResolveStatusService` failures are silently skipped. Cursor is only updated if the fetch succeeded.

### `app/workers/recommendations/learn_worker.rb`

Unchanged from the original design. Enqueued by `CustomFeeds::FavouriteConcern` and `CustomFeeds::StatusConcern` (in addition to their existing FeedRemoveWorker enqueueing). Loads the account's relevant algorithm via `RecommendationSignal`, calls `algo.learn(interaction_type, status)`.

The learn worker is kept in the `Recommendations::` namespace because it is specific to the signal/learning system, not the core custom feeds pipeline.

---

## Learning Integration

`CustomFeeds::FavouriteConcern` and `CustomFeeds::StatusConcern` already enqueue `FeedRemoveWorker`. They gain an additional `after_create_commit` that enqueues `Recommendations::LearnWorker` if the account has any `recommendation_score` filter steps:

```ruby
# in CustomFeeds::FavouriteConcern
after_create_commit :enqueue_learn_worker

def enqueue_learn_worker
  return unless recommendation_score_filter_configured?
  Recommendations::LearnWorker.perform_async('favourite', status_id, account_id)
end
```

`recommendation_score_filter_configured?` checks whether the account has any enabled `CustomFeedConfig` with a `recommendation_score` filter step. This avoids enqueueing learn jobs for users who haven't configured any scoring filters.

---

## Registering the New Types

`config/initializers/custom_feeds.rb` (extended):

```ruby
Rails.application.config.to_prepare do
  # Existing push source
  CustomFeeds::Sources::FollowedPosts.register!

  # New pull sources
  CustomFeeds::Sources::RemotePublicTimeline.register!
  CustomFeeds::Sources::RemoteTagTimeline.register!

  # Existing filters
  CustomFeeds::Filters::InteractedPosts.register!

  # New recommendation filters
  CustomFeeds::Filters::FriendsLiked.register!
  CustomFeeds::Filters::RecommendationScore.register!

  # Algorithms (separate registry under Recommendations namespace)
  Recommendations::Algorithms::FriendsLikedScore.register!

  # Overflow strategies
  CustomFeeds::OverflowStrategies::OldestFirst.register!
  CustomFeeds::OverflowStrategies::NoOverflow.register!

  # Concerns (existing)
  Api::V1::Timelines::ListController.prepend(CustomFeeds::ListControllerConcern)
  FeedInsertWorker.prepend(CustomFeeds::FeedInsertConcern)
  Favourite.include(CustomFeeds::FavouriteConcern)
  Status.include(CustomFeeds::StatusConcern)
end
```

No separate `recommendations.rb` initializer. No separate `ListControllerConcern` — `CustomFeeds::ListControllerConcern` already intercepts any list with a `CustomFeedConfig`, regardless of list title.

---

## Scheduler Entry

`config/schedule.yml` (or sidekiq-cron equivalent):

```yaml
custom_feeds_pull_sources:
  cron: '*/15 * * * *'
  class: 'CustomFeeds::SchedulePullSourcesWorker'
  queue: scheduler
```

---

## Frontend Changes

### New Phase Options

`PHASE_OPTIONS` in `custom_feed_form.tsx` is extended:

**Sources:**

| `step_type`              | Label                           |
| ------------------------ | ------------------------------- |
| `followed_posts`         | Followed accounts (home feed)   |
| `remote_public_timeline` | Remote server — public timeline |
| `remote_tag_timeline`    | Remote server — tag timeline    |

**Filters:**

| `step_type`            | Label                                 |
| ---------------------- | ------------------------------------- |
| ``                     | None                                  |
| `interacted_posts`     | Hide already-interacted posts         |
| `friends_liked`        | Only posts liked by people you follow |
| `recommendation_score` | Recommendation analysis               |

### Step Options Fields

Some source and filter types require additional configuration stored in `step.options`. The form renders conditional fields below the phase `SelectField` when an options-bearing type is selected:

**`remote_public_timeline` options:**

- `domain` — text input, required (e.g. `mastodon.social`)
- `local_only` — toggle, default on
- `limit_per_run` — number input, default 40

**`remote_tag_timeline` options:**

- `domain` — text input, required
- `tag` — text input, required (without `#`)
- `limit_per_run` — number input, default 40

**`friends_liked` options:**

- `min_interactions` — number input, default 1 ("at least N of your follows must have interacted")

**`recommendation_score` options:**

- `algorithm` — `SelectField`: `friends_liked_score` (and future options)
- `min_score` — number input, 0–1 range, default 0.5

The step options are serialised into `ApiCustomFeedStepInputJSON.options` and sent to the API. The `CustomFeedStep#options` JSONB column stores them. Source and filter classes read them via `options.fetch(...)`.

### Form State for Options

`custom_feed_form.tsx` tracks per-phase options state alongside the `step_type` selections:

```ts
const [sourceOptions, setSourceOptions] = useState<Record<string, unknown>>(
  () => config?.steps.find((s) => s.phase === 'source')?.options ?? {},
);
// similarly for filterOptions
```

When `buildSteps()` constructs the payload, it includes the options:

```ts
if (source)
  steps.push({
    phase: 'source',
    step_type: source,
    position: 0,
    options: sourceOptions,
  });
```

The form renders phase-specific option fields after the `SelectField` using a helper component per step type (e.g. `<RemoteTimelineOptions>`, `<FriendsLikedOptions>`, `<RecommendationScoreOptions>`).

---

## What is Removed

The following from the original `recommendations.md` design are **not implemented**:

| Removed                                      | Replaced by                                                      |
| -------------------------------------------- | ---------------------------------------------------------------- |
| `recommendation_configs` table               | `CustomFeedConfig` + `CustomFeedStep` (options JSONB)            |
| `recommendation_server_cursors` table        | `custom_feed_pull_cursors` table (per step, not per user+domain) |
| `Recommendations::FeedManager`               | `CustomFeeds::FeedManager`                                       |
| `RecommendationsFeed` model                  | `CustomFeedsFeed` (already handles any list with a config)       |
| `RecommendationConfig` ActiveRecord model    | `CustomFeedConfig`                                               |
| `Recommendations::ListControllerConcern`     | `CustomFeeds::ListControllerConcern` (already active)            |
| `config/initializers/recommendations.rb`     | Merged into `config/initializers/custom_feeds.rb`                |
| `LIST_TITLE = 'Recommendations'` magic title | Unnecessary; any list with a `CustomFeedConfig` is a custom feed |
| `Recommendations::ScheduleIngestionWorker`   | `CustomFeeds::SchedulePullSourcesWorker`                         |
| `Recommendations::IngestCandidatesWorker`    | `CustomFeeds::PullSourceIngestWorker`                            |

---

## File List

### New Backend Files

| File                                                        | Purpose                                                         |
| ----------------------------------------------------------- | --------------------------------------------------------------- |
| `app/lib/custom_feeds/sources/remote_public_timeline.rb`    | Pull source: fetches remote server public timeline              |
| `app/lib/custom_feeds/sources/remote_tag_timeline.rb`       | Pull source: fetches remote server tag timeline                 |
| `app/lib/custom_feeds/filters/friends_liked.rb`             | Filter: exclude unless ≥ N follows have engaged                 |
| `app/lib/custom_feeds/filters/recommendation_score.rb`      | Filter: exclude if algorithm score < threshold                  |
| `app/lib/recommendations.rb`                                | Module namespace; `Algorithms::REGISTRY`                        |
| `app/lib/recommendations/algorithms/base.rb`                | Algorithm interface: `score_one`, `score`, `learn`, `register!` |
| `app/lib/recommendations/algorithms/friends_liked_score.rb` | Friends-engagement + time-decay scoring                         |
| `app/models/recommendation_signal.rb`                       | Per-user learned signal weights                                 |
| `app/workers/custom_feeds/schedule_pull_sources_worker.rb`  | Periodic scheduler for pull-source configs                      |
| `app/workers/custom_feeds/pull_source_ingest_worker.rb`     | Core pull ingest: fetch → filter → push                         |
| `app/workers/recommendations/learn_worker.rb`               | Updates `RecommendationSignal` after user interactions          |
| `db/migrate/*_create_custom_feed_pull_cursors.rb`           | New cursor table for pull source steps                          |
| `db/migrate/*_create_recommendation_signals.rb`             | Signal weights table (kept from original design)                |

### Modified Backend Files

| File                                        | Change                                                                    |
| ------------------------------------------- | ------------------------------------------------------------------------- |
| `app/lib/custom_feeds/sources/base.rb`      | Add `pull_source?` class method and `fetch_candidates` interface          |
| `app/lib/custom_feeds/favourite_concern.rb` | Also enqueue `Recommendations::LearnWorker` if scoring filters configured |
| `app/lib/custom_feeds/status_concern.rb`    | Same                                                                      |
| `config/initializers/custom_feeds.rb`       | Register new pull sources, recommendation filters, and algorithm          |
| `config/schedule.yml`                       | Add `custom_feeds_pull_sources` cron entry                                |

### New Frontend Files

| File                                                                                                              | Purpose                                                                    |
| ----------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| `app/javascript/mastodon/features/custom_feeds_settings/components/step_options/remote_timeline_options.tsx`      | `domain`, `local_only`, `limit_per_run` fields for remote timeline sources |
| `app/javascript/mastodon/features/custom_feeds_settings/components/step_options/friends_liked_options.tsx`        | `min_interactions` field                                                   |
| `app/javascript/mastodon/features/custom_feeds_settings/components/step_options/recommendation_score_options.tsx` | `algorithm` dropdown + `min_score` field                                   |

### Modified Frontend Files

| File                                                                                     | Change                                                                                                                                                        |
| ---------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `app/javascript/mastodon/features/custom_feeds_settings/components/custom_feed_form.tsx` | Add new options to `PHASE_OPTIONS`; add `sourceOptions`/`filterOptions` state; render step-options sub-forms conditionally; include options in `buildSteps()` |
| `app/javascript/mastodon/locales/en.json`                                                | New i18n keys for new source/filter labels and option field labels                                                                                            |

### Test Files

| File                                                              | Covers                                                                                   |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `spec/lib/custom_feeds/sources/remote_public_timeline_spec.rb`    | HTTP fetch mock, cursor usage, `ResolveStatusService` integration, error handling        |
| `spec/lib/custom_feeds/sources/remote_tag_timeline_spec.rb`       | Same for tag endpoint                                                                    |
| `spec/lib/custom_feeds/filters/friends_liked_spec.rb`             | `exclude?` with varying `min_interactions`; follow interaction counts; reblog resolution |
| `spec/lib/custom_feeds/filters/recommendation_score_spec.rb`      | Delegates to algorithm `score_one`; unknown algorithm → exclude; threshold logic         |
| `spec/lib/recommendations/algorithms/friends_liked_score_spec.rb` | `score_one` with following engagements, time decay, base score fallback                  |
| `spec/models/recommendation_signal_spec.rb`                       | `for_account` lookup, upsert behaviour                                                   |
| `spec/workers/custom_feeds/schedule_pull_sources_worker_spec.rb`  | Enqueues only configs with pull sources; disabled configs skipped                        |
| `spec/workers/custom_feeds/pull_source_ingest_worker_spec.rb`     | HTTP fetch mock, resolve, filter pipeline, push, cursor update                           |
| `spec/workers/recommendations/learn_worker_spec.rb`               | Signal upsert on favourite/reblog/reply                                                  |

---

## Key Design Decisions

**Recommendation sources and filters are first-class custom feed plugins.** There is no separate management surface, no separate list controller intercept, and no separate Redis key namespace. A "Recommendations" feed is just a `CustomFeedConfig` with pull-source steps and scoring filter steps.

**`pull_source?` flag on the source base class cleanly separates the two insertion paths.** `FeedInsertWorker` ignores pull-source configs. `PullSourceIngestWorker` ignores push-source configs. A config can mix both types; each path runs independently and shares the same filter pipeline.

**`FriendsLiked` is a filter, not a separate algorithm.** The original design modelled it as an algorithm that scored and ranked candidates. In the custom feeds model it is more natural as a binary filter: "include this post only if at least N follows have engaged with it." This is simpler, stateless, and composable with other filters. For ranked results (rather than filtered-then-chronological), implement a score-based overflow strategy in a future iteration.

**`RecommendationScore` filter delegates to algorithm objects.** The filter is the pipeline-integration point; the algorithm objects (under `Recommendations::Algorithms::`) do the actual scoring. This keeps the scoring logic separate from the pipeline infrastructure and allows new algorithms to be added without touching the filter class.

**Cursor is per step, not per (account, domain).** The old `recommendation_server_cursors` table was keyed by `(account_id, server_domain)`. Pull source step options include the domain, so the cursor can simply be keyed by `custom_feed_step_id`. If the user changes the domain in the options, the step is replaced (steps are replaced wholesale on update), so the cursor naturally resets.

**Learning still uses `RecommendationSignal` rows.** The signal table is the shared mutable state for all scoring algorithms. It is written by `Recommendations::LearnWorker` after user interactions and read by algorithm `score_one` implementations. This is kept in the `Recommendations::` namespace rather than `CustomFeeds::` because it is concern of the algorithm layer, not the pipeline layer.

**No score-based Redis ordering in this iteration.** The custom feeds `FeedManager` uses status ID as score (chronological order). Recommendation filters act as binary gates; posts that pass are inserted in arrival order. If ranked display is needed in future, the `CustomFeeds::FeedManager` could be extended to accept an optional score override, or a new overflow strategy could sort on insertion.

**Applying `RecommendationScore` to `followed_posts` is valid but expensive.** It calls `score_one` for every incoming home-feed post in real time. This is acceptable for `FriendsLikedScore` (two SQL count queries). Algorithms that call ML inference should only be used with pull-source configs, not `followed_posts`.
