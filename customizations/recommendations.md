# Recommendations as Custom Feed Plugins

Recommendation feeds are implemented as **custom feed sources and filters**, not as a separate parallel system. A "Recommendations" feed is an ordinary `CustomFeedConfig` tied to any Mastodon List, configured via the Custom Feeds settings page with one or more pull sources and a scoring filter.

This replaces the original standalone `Recommendations::*` architecture. The separate `recommendation_configs` table, `Recommendations::FeedManager`, `Recommendations::ListControllerConcern`, and `config/initializers/recommendations.rb` are all eliminated. Everything flows through the existing custom feeds pipeline.

---

## Status

| Layer                                | Status        |
| ------------------------------------ | ------------- |
| Pull sources (`remote_tag_timeline`, `remote_public_timeline`) | ✅ Shipped |
| Push source (`followed_posts`)        | ✅ Shipped |
| Filters: `friends_liked`, `interacted_posts`, `blocked_tags` | ✅ Shipped |
| Removal: `on_interaction`, `time_based` | ✅ Shipped |
| Overflow: `oldest_first`, `no_overflow` | ✅ Shipped |
| Multi-provider UI (add/remove steps per phase) | ✅ Shipped |
| Pull cadence + scheduler              | ✅ Shipped |
| Per-bucket cursors (`custom_feed_pull_cursors`) | ✅ Shipped |
| Insertion-time tracking (`inserted_at` hash) | ✅ Shipped |
| Home-feed isolation (feeds.remove event) | ✅ Shipped |
| `RecommendationScore` filter          | ❌ Not yet built |
| `Recommendations::Algorithms` namespace | ❌ Not yet built |
| `Recommendations::Algorithms::FriendsLikedScore` | ❌ Not yet built |
| `RecommendationSignal` model + table  | ❌ Not yet built |
| `Recommendations::LearnWorker`        | ❌ Not yet built |

---

## What the User Configures

In the Custom Feeds settings page, a user creates a config on any list and sets:

| Phase    | Option                          | Example                                                       |
| -------- | ------------------------------- | ------------------------------------------------------------- |
| Source   | `remote_public_timeline`        | mastodon.social public timeline (multi-server array)         |
| Source   | `remote_tag_timeline`           | mastodon.social posts tagged `#rustlang` (multi-server array) |
| Source   | `followed_posts`                | Home feed posts from accounts you follow                      |
| Filter   | `interacted_posts`              | Hide posts you've already interacted with                     |
| Filter   | `friends_liked`                 | Only posts that at least N follows have favourited or boosted |
| Filter   | `blocked_tags`                  | Exclude posts containing any configured tag                   |
| Filter   | `recommendation_score`          | ❌ Algorithmic scoring; exclude posts below threshold         |
| Removal  | `on_interaction`                | Remove once you favourite/boost/reply                         |
| Removal  | `time_based`                    | Remove after a configured number of minutes/hours             |
| Overflow | `oldest_first` or `no_overflow` | Standard overflow behaviour                                   |

Each source and filter step stores its parameters in `custom_feed_steps.options` (JSONB). No additional tables are required for configuration.

---

## What Is Already Built

### Pipeline Architecture

The full multi-provider pipeline is in production. Key design points as actually implemented:

- `Sources::Base` has `pull_source?` flag and `fetch_candidates` returning a `FetchResult` struct (not a plain array):
  ```ruby
  FetchResult = Struct.new(:max_remote_id, :statuses)
  ```
  `max_remote_id` is the highest raw API `id` seen in the response (advances the cursor even when statuses fail to resolve). `statuses` is the array of resolved `Status` records.

- `Sources::Base#resolve_uris` checks `Status.find_by(uri: uri)` before calling `ResolveURLService`. This avoids redundant HTTP round-trips and prevents `ActivityPub::Activity::Create#distribute` from triggering for already-known statuses (which would insert them into the home feeds of local followers).

- `PullSourceIngestWorker` uses explicit `account.blocking?` / `account.muting?` / `account.domain_blocking?` checks rather than `FeedManager.filter(:home, ...)`. The `filter_from_home` method applies home-feed-specific rules (language filters, exclusive-list skip flags) that are not appropriate for custom feeds.

- `CustomFeeds::FeedManager#remove_and_stream` publishes `event: 'feeds.remove'` (not `event: :delete`). The standard `delete` event calls `deleteFromTimelines()` in the frontend which removes the status from every timeline in the Redux store; `feeds.remove` only removes it from the specific list timeline.

- `CustomFeeds::FeedManager` maintains a companion Redis hash `feed:custom:{list_id}:inserted_at` mapping `status_id → unix_timestamp`. Written on `push`, deleted on `remove`. Used by `TimeBasedRemovalWorker` to measure how long a post has been in the feed (vs. when it was created, which is what the snowflake ID encodes).

### Existing Pipeline Entry Points

```
Home-feed delivery (push sources):
  FeedInsertWorker → FeedInsertConcern#perform_push → super (home feed) +
  CustomFeeds::FeedInsertWorker → Pipeline#include? → push to feed:custom:{list_id}

Scheduled pull sources:
  SchedulePullSourcesWorker (every 5 min) → PullSourceIngestWorker →
  Pipeline#pull_source_entries → fetch_candidates per bucket →
  FetchResult → cursor update → Pipeline#passes_filters? → push to feed:custom:{list_id}

Interaction removal:
  FavouriteConcern / StatusConcern → FeedRemoveWorker →
  Pipeline#remove_on? → FeedManager#remove_and_stream

Time-based removal:
  TimeBasedRemovalWorker (every 5 min) → inserted_at hash → remove expired posts
```

---

## Remaining Work: Recommendation Scoring

### `CustomFeeds::Filters::RecommendationScore`

A new filter plugin. Delegates scoring to a registered algorithm and excludes candidates below `min_score`.

```ruby
# app/lib/custom_feeds/filters/recommendation_score.rb
module CustomFeeds
  module Filters
    class RecommendationScore < Base
      def self.key
        'recommendation_score'
      end

      # options keys:
      #   algorithm  (string, default 'friends_liked_score')
      #   min_score  (float,  default 0.5)

      def exclude?(status, account, options = {})
        algo_key  = options.fetch('algorithm', 'friends_liked_score')
        min_score = options.fetch('min_score', 0.5).to_f
        algo      = Recommendations::Algorithms::REGISTRY[algo_key]
        return true if algo.nil? # unknown algorithm → exclude

        algo.new(account).score_one(status) < min_score
      end
    end
  end
end
```

Register in `config/initializers/custom_feeds.rb`:
```ruby
CustomFeeds::Filters::RecommendationScore.register!
```

Add to `PHASE_OPTIONS.filter` in `custom_feed_form.tsx` and create a `recommendation_score_options.tsx` component (algorithm selector + min_score slider/input).

---

### `Recommendations::Algorithms` Namespace

```ruby
# app/lib/recommendations.rb
module Recommendations
  module Algorithms
    REGISTRY = {} # rubocop:disable Style/MutableConstant
  end
end

# app/lib/recommendations/algorithms/base.rb
module Recommendations
  module Algorithms
    class Base
      def self.key
        raise NotImplementedError
      end

      def self.register!
        REGISTRY[key] = self
      end

      def initialize(account)
        @account = account
      end

      # Score a single status. Used by RecommendationScore filter.
      # @param [Status] status
      # @return [Float] 0.0 – 1.0+
      def score_one(status)
        0.0
      end

      # Called after user interactions to update RecommendationSignal rows.
      # @param [String] interaction_type  'favourite' | 'reblog' | 'reply'
      # @param [Status] status
      def learn(interaction_type, status); end
    end
  end
end
```

---

### `Recommendations::Algorithms::FriendsLikedScore`

Scores by follows' engagement weighted by time decay. The existing `friends_liked` filter is a binary gate; this algorithm scores for ranking so both can coexist independently.

```ruby
# app/lib/recommendations/algorithms/friends_liked_score.rb
module Recommendations
  module Algorithms
    class FriendsLikedScore < Base
      def self.key
        'friends_liked_score'
      end

      # score = (favs * 1.0 + reblogs * 2.0) * exp(-0.5 * age_in_days)
      # Falls back to a small base score from raw counts if no local signal found.
      def score_one(status)
        original       = status.reblog? ? status.reblog : status
        following_ids  = @account.following.pluck(:id)
        age_in_days    = (Time.now - original.created_at) / 86_400.0

        fav_count    = Favourite.where(account_id: following_ids, status_id: original.id).count
        reblog_count = Status.where(account_id: following_ids, reblog_of_id: original.id).count
        raw_score    = (fav_count * 1.0) + (reblog_count * 2.0)

        if raw_score > 0
          raw_score * Math.exp(-0.5 * age_in_days)
        else
          # No local signal — derive a small base score from public counts
          base = (original.favourites_count.to_f + original.reblogs_count.to_f * 2) / 100.0
          [base * Math.exp(-0.5 * age_in_days), 0.1].min
        end
      end
    end
  end
end
```

Register in `config/initializers/custom_feeds.rb` alongside the filter:
```ruby
Recommendations::Algorithms::FriendsLikedScore.register!
```

---

### `RecommendationSignal` Model + Table

Kept for learning algorithms that personalise over time. Not required for `FriendsLikedScore` (which queries live Mastodon data), but needed for any algorithm that learns from interaction history beyond what is already stored in `favourites` and `statuses`.

```ruby
# db/migrate/TIMESTAMP_create_recommendation_signals.rb
create_table :recommendation_signals do |t|
  t.references :account,         null: false, foreign_key: true
  t.string     :signal_type,     null: false  # 'author_affinity' | 'tag_affinity' | 'domain_affinity'
  t.string     :entity_type,     null: false  # 'account' | 'tag' | 'domain'
  t.string     :entity_id,       null: false
  t.float      :weight,          null: false, default: 0.0
  t.integer    :observation_count, null: false, default: 0
  t.datetime   :last_observed_at
  t.timestamps

  t.index [:account_id, :signal_type, :entity_type, :entity_id],
          unique: true, name: 'idx_rec_signals_lookup'
end
```

`FriendsLikedScore` does not require this table — it reads directly from `favourites` and `statuses`. Only implement this when building an algorithm that stores learned weights.

---

### `Recommendations::LearnWorker`

Enqueued by `CustomFeeds::FavouriteConcern` and `CustomFeeds::StatusConcern` when the account has a `recommendation_score` filter configured.

```ruby
# app/workers/recommendations/learn_worker.rb
module Recommendations
  class LearnWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default', retry: 3

    def perform(interaction_type, status_id, account_id)
      account = Account.find(account_id)
      status  = Status.find(status_id)

      has_score_filter = CustomFeedConfig
        .enabled
        .where(account: account)
        .joins(:custom_feed_steps)
        .where(custom_feed_steps: { phase: 'filter', step_type: 'recommendation_score' })
        .exists?
      return unless has_score_filter

      Algorithms::REGISTRY.each_value do |klass|
        klass.new(account).learn(interaction_type, status)
      end
    rescue ActiveRecord::RecordNotFound
      true
    end
  end
end
```

Hook into existing concerns:

```ruby
# app/lib/custom_feeds/favourite_concern.rb (addition)
after_create_commit :enqueue_learn_worker

def enqueue_learn_worker
  Recommendations::LearnWorker.perform_async('favourite', status_id, account_id)
end
```

```ruby
# app/lib/custom_feeds/status_concern.rb (addition, inside enqueue_custom_feed_remove_if_interaction)
if reblog?
  Recommendations::LearnWorker.perform_async('reblog', reblog_of_id, account_id)
elsif reply?
  Recommendations::LearnWorker.perform_async('reply', in_reply_to_id, account_id)
end
```

The guard check (`has_score_filter`) is intentionally inside the worker rather than the concerns, to avoid the DB query on every single interaction for users without scoring configured. If the queue is high-traffic this guard can be moved to the concerns at the cost of a per-interaction query.

---

## Frontend: `recommendation_score_options.tsx`

```tsx
// app/javascript/mastodon/features/custom_feeds_settings/components/step_options/recommendation_score_options.tsx
const ALGORITHM_OPTIONS = [
  { value: 'friends_liked_score', labelId: 'custom_feeds.algorithms.friends_liked_score' },
];

export const RecommendationScoreOptions: React.FC<Props> = ({ options, onChange }) => {
  const algorithm = (options.algorithm as string | undefined) ?? 'friends_liked_score';
  const minScore  = (options.min_score  as number | undefined) ?? 0.5;
  // ... algorithm selector + min_score number input (0.0–1.0)
};
```

Add to `PHASE_OPTIONS.filter` and `DEFAULT_OPTIONS` in `custom_feed_form.tsx`, and wire into `StepOptionsForm` in `phase_section.tsx`. Add i18n keys:

```json
"custom_feeds.filters.recommendation_score": "Recommendation scoring",
"custom_feeds.algorithms.friends_liked_score": "Friends' engagement (time-decayed)",
"custom_feeds.step_options.algorithm": "Algorithm",
"custom_feeds.step_options.min_score": "Minimum score"
```

---

## Implementation Order for Remaining Work

1. `app/lib/recommendations.rb` + `algorithms/base.rb` — namespace and base class
2. `app/lib/recommendations/algorithms/friends_liked_score.rb` — first algorithm
3. `app/lib/custom_feeds/filters/recommendation_score.rb` — filter plugin
4. Register both in `config/initializers/custom_feeds.rb`
5. Frontend: `recommendation_score_options.tsx` + wire into form
6. Verify: create a custom feed with `remote_public_timeline` + `recommendation_score` filter
7. *(Optional)* `db/migrate/*_create_recommendation_signals.rb` + `RecommendationSignal` model + `Recommendations::LearnWorker` — only needed for learning algorithms

`FriendsLikedScore` works entirely from existing Mastodon tables (`favourites`, `statuses`) so steps 1–6 can be completed without any migrations.

---

## What Is Not Built (and Why)

| Original Plan Item                           | Decision                                                                         |
| -------------------------------------------- | -------------------------------------------------------------------------------- |
| `recommendation_configs` table               | Replaced by `CustomFeedConfig` + `CustomFeedStep` (options JSONB) ✅            |
| `recommendation_server_cursors` table        | Replaced by `custom_feed_pull_cursors` (per-step + per-bucket) ✅               |
| `Recommendations::FeedManager`               | Replaced by `CustomFeeds::FeedManager` ✅                                        |
| `RecommendationsFeed` model                  | Replaced by `CustomFeedsFeed` ✅                                                  |
| `RecommendationConfig` ActiveRecord model    | Replaced by `CustomFeedConfig` ✅                                                 |
| `Recommendations::ListControllerConcern`     | Replaced by `CustomFeeds::ListControllerConcern` ✅                              |
| `config/initializers/recommendations.rb`     | Merged into `config/initializers/custom_feeds.rb` ✅                             |
| `LIST_TITLE = 'Recommendations'` magic title | Eliminated; any list with a `CustomFeedConfig` is a custom feed ✅               |
| `Recommendations::ScheduleIngestionWorker`   | Replaced by `CustomFeeds::SchedulePullSourcesWorker` ✅                          |
| `Recommendations::IngestCandidatesWorker`    | Replaced by `CustomFeeds::PullSourceIngestWorker` ✅                             |
| `event: :delete` for feed removal            | Changed to `event: 'feeds.remove'` to avoid purging from all timelines ✅       |
| Score-based feed ordering                    | Deferred — feed is currently chronological; a score-based overflow strategy is future work |
| `RecommendationSignal` table + LearnWorker   | Deferred — `FriendsLikedScore` uses live Mastodon data; learning layer only needed for personalised algorithms |

---

## Key Design Decisions

**Recommendation sources and filters are first-class custom feed plugins.** There is no separate management surface, no separate list controller intercept, and no separate Redis key namespace. A "Recommendations" feed is just a `CustomFeedConfig` with pull-source steps and scoring filter steps.

**`FetchResult` struct decouples cursor advancement from resolution success.** The raw API `id` is used to advance the cursor even if `ResolveURLService` fails to resolve the status. This prevents re-fetching statuses that are permanently unresolvable.

**Local DB pre-check before `ResolveURLService`.** `Sources::Base#resolve_uris` checks `Status.find_by(uri: uri)` first. For already-known statuses this avoids an HTTP round-trip and — more importantly — skips `ActivityPub::Activity::Create#distribute`, which would otherwise insert the status into home feeds of local followers via `DistributionWorker`.

**`FriendsLiked` is a binary filter, not a ranking algorithm.** The original design modelled it as a scoring algorithm. In the custom feeds model it is more natural as a gate: "include this post only if at least N follows have engaged." For ranked results implement a `FriendsLikedScore` algorithm (described above) and use it via the `RecommendationScore` filter.

**`RecommendationScore` filter delegates to algorithm objects.** The filter is the pipeline integration point; the algorithm objects (under `Recommendations::Algorithms::`) do the actual scoring. New algorithms can be added without touching the filter class.

**Cursor is per (step, bucket), not per (account, domain).** Pull source step options include the domain and tag, so the cursor is keyed by `custom_feed_step_id + bucket`. If the user changes the domain in the options, the step is replaced wholesale on update and the cursor naturally resets.

**Insertion-time tracking uses a companion Redis hash.** `feed:custom:{list_id}:inserted_at` maps `status_id → unix_timestamp` of when the post entered this specific feed. This powers `time_based` removal correctly — the timer measures time since inclusion, not time since the post was created (which is what the snowflake ID encodes).
