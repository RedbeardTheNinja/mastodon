# Algorithmic Feeds

An **algorithmic feed** is a `CustomFeedConfig` variant (`feed_type: 'algorithmic'`) that stages candidates in a pending queue, scores them with a pluggable algorithm, applies score-aware filters, and only then promotes them into the feed — rather than the direct filter-then-push model used by standard custom feeds.

---

## How Algorithmic Feeds Differ From Standard Custom Feeds

### Standard custom feed pipeline

```
Sources → (standard filters) → feed:custom:{list_id}
```

### Algorithmic feed pipeline

```
Sources → (standard pre-filters) → feed:algo:{list_id}:pending
                                         ↓  (ScheduleAlgorithmicFeedsWorker every 5 min)
                                    AlgorithmicFeedWorker
                                         ↓
                                    score each candidate
                                         ↓
                               algorithmic filters (min_score, top_k_per_batch, min_signals)
                                         ↓
                               standard pipeline filters (final gate)
                                         ↓
                                  feed:custom:{list_id}
```

**Key differences from standard:**

- Candidates are staged in a pending queue rather than pushed directly to the feed
- The algorithm worker scores the queued batch and makes promotion decisions based on rank, not just binary include/exclude
- Algorithmic filters (`min_score`, `top_k_per_batch`) require a score; they run in the algorithm worker
- Standard filters (`blocked_tags`, `interacted_posts`, `friends_liked`) run as pre-filters at ingest time to reduce queue size
- The algorithm worker can observe the full pending batch before deciding, enabling relative ranking

---

## Pending Queue

```
Redis key:  feed:algo:{list_id}:pending
Type:       sorted set
Score:      unix timestamp of when the candidate arrived
Member:     status_id
```

- **Max size**: `FeedManager::MAX_ITEMS`. If full, the oldest entry is evicted before a new one is added.
- **Expiry**: candidates older than `max_pending_age_hours` (default 48h) are discarded by the algorithm worker without scoring.
- **Deduplication**: `ZSCORE` check before `ZADD` — same status is not queued twice; logs at debug on dedup hit.

`CustomFeeds::FeedManager` manages the queue: `pending_key(list_id)`, `enqueue_candidate(config, status)`, `dequeue_pending(list_id, limit:, max_age_hours:)`.

---

## Signal Collection

The algorithm learns from the account's interaction history. Three interaction types contribute signals:

| Interaction    | Weight | Reasoning                                    |
| -------------- | ------ | -------------------------------------------- |
| Reblog (boost) | 2.0    | Explicit endorsement; high-confidence signal |
| Reply          | 2.0    | Deep engagement; high-confidence signal      |
| Favourite      | 0.5    | Mild positive signal                         |

Features extracted per interaction:

```
tag:#{tag.name}          → weight        (for each tag on the original post)
account:#{account_id}    → weight        (author of the post)
domain:#{account.domain} → weight × 0.5  (remote server affinity; skipped for local accounts)
```

Signals are stored in `recommendation_signals` with accumulating upsert (`weight +=`, `observation_count += 1`, `last_observed_at` updated). One row per `(account, signal_type, entity_id)` keeps the table size bounded.

### Database Schema

```ruby
create_table :recommendation_signals do |t|
  t.references :account,           null: false, foreign_key: true
  t.string     :signal_type,       null: false  # 'tag' | 'account' | 'domain'
  t.string     :entity_id,         null: false  # tag name | account_id | domain
  t.float      :weight,            null: false, default: 0.0
  t.integer    :observation_count, null: false, default: 0
  t.datetime   :last_observed_at
  t.timestamps
  t.index [:account_id, :signal_type, :entity_id],
          unique: true, name: 'idx_rec_signals_lookup'
end
```

---

## Algorithm Plugin Interface

```ruby
# app/lib/recommendations/algorithms/base.rb
module Recommendations
  module Algorithms
    class Base
      include CustomFeeds::Registerable

      def initialize(account)
        @account = account
      end

      # Score a batch of candidates. Returns [{status:, score: Float}] sorted descending.
      def score_batch(candidates)
        candidates.map { |s| { status: s, score: score_one(s) } }.sort_by { |r| -r[:score] }
      end

      def score_one(_status) = 0.0
    end
  end
end
```

Uses `CustomFeeds::Registerable` — the same shared concern as all other plugin base classes. Registry accessed as `Recommendations::Algorithms::Base.registry['key']`.

---

## Implemented Algorithm: `affinity_score`

Weighted feature affinity with time decay. No ML library required. Works from the first interaction and improves over time.

### Scoring formula

```
score(status) =
  Σ tag_affinity[tag]         (first 5 tags)
  + account_affinity[author_id]
  + domain_affinity[author.domain] × 0.5  (local accounts: 0)
  × exp(−0.05 × age_in_hours)             (half-life ≈ 14 hours)
```

### Implementation

```ruby
# app/lib/recommendations/algorithms/affinity_score.rb
class AffinityScore < Base
  DECAY_LAMBDA = 0.05
  TAG_CAP      = 5

  def self.key = 'affinity_score'

  def score_batch(candidates)
    # Load all signals in a single query and partition in Ruby (was 3 separate queries)
    @tag_affinities = @account_affinities = @domain_affinities = {}
    RecommendationSignal.where(account: @account).pluck(:signal_type, :entity_id, :weight).each do |type, entity, weight|
      case type
      when 'tag'     then @tag_affinities[entity]     = weight
      when 'account' then @account_affinities[entity] = weight
      when 'domain'  then @domain_affinities[entity]  = weight
      end
    end
    super
  end

  def score_one(status)
    original    = status.original_status  # resolves reblog chain
    age_hours   = (Time.current - original.created_at) / 3600.0
    time_factor = Math.exp(-DECAY_LAMBDA * age_hours)

    tag_score = original.tags.first(TAG_CAP).sum { |tag| @tag_affinities[tag.name.downcase].to_f }
    account_score = @account_affinities[original.account_id.to_s].to_f
    domain_score  = original.account.domain.present? ?
                      @domain_affinities[original.account.domain].to_f * 0.5 : 0.0

    (tag_score + account_score + domain_score) * time_factor
  end
end
```

---

## Algorithmic Filters

These filters require a score and run in the algorithm worker, not at ingest time.

| `step_type`       | Phase                | Description                                                      | Key options                      |
| ----------------- | -------------------- | ---------------------------------------------------------------- | -------------------------------- |
| `min_signals`     | `algorithmic_filter` | Skip all scoring until the account has at least N signal records | `count: Integer` (default 5)     |
| `min_score`       | `algorithmic_filter` | Discard candidates below score threshold                         | `threshold: Float` (default 0.1) |
| `top_k_per_batch` | `algorithmic_filter` | Promote only the top K candidates per run                        | `k: Integer` (default 10)        |

`min_signals` is evaluated first (pre-scoring gate). `min_score` and `top_k_per_batch` run on the scored result set.

---

## Algorithm Worker

```ruby
# app/workers/recommendations/algorithmic_feed_worker.rb
module Recommendations
  class AlgorithmicFeedWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default', retry: 3

    def perform(config_id)
      config = CustomFeedConfig.where(feed_type: 'algorithmic', enabled: true).find_by(id: config_id)
      return unless config&.account&.user&.signed_in_recently?

      algo_step  = config.steps_for('algorithm').first
      algo_klass = Recommendations::Algorithms::Base.registry[algo_step&.step_type]
      return unless algo_klass

      account    = config.account
      candidates = CustomFeeds::FeedManager.instance.dequeue_pending(config.list_id, …)

      Rails.logger.info { "AlgorithmicFeedWorker: config=#{config_id} dequeued=#{candidates.size}" }
      return if candidates.empty?

      # min_signals gate
      if (step = config.steps_for('algorithmic_filter').find { |s| s.step_type == 'min_signals' })
        required = step.options.fetch('count', 5).to_i
        actual   = RecommendationSignal.where(account: account).count
        if actual < required
          Rails.logger.info { "AlgorithmicFeedWorker: skipped (min_signals: need #{required}, have #{actual})" }
          return
        end
      end

      scored = algo_klass.new(account).score_batch(candidates)
      # logs score distribution (min/max/p50) at info
      scored = apply_algorithmic_filters(scored, config)
      # apply_algorithmic_filters: iterates min_score and top_k_per_batch steps

      pipeline = CustomFeeds::Pipeline.new(config)
      scored.each do |result|
        if pipeline.passes_filters?(result[:status], account)
          CustomFeeds::FeedManager.instance.push_and_stream(config, result[:status])
        end
      end
      # logs promoted/filtered_score/filtered_pipeline counts at info
    end
  end
end
```

The worker logs score statistics (min/max/p50 via a private `percentile` helper) and final promotion counts at `info` level for each run.

### Scheduler

```ruby
# app/workers/recommendations/schedule_algorithmic_feeds_worker.rb
# Runs every 5 minutes via config/sidekiq.yml
class ScheduleAlgorithmicFeedsWorker
  def perform
    CustomFeedConfig.algorithmic.enabled
      .where("last_pulled_at IS NULL OR last_pulled_at + (pull_cadence_minutes * interval '1 minute') <= NOW()")
      .find_each { |config| AlgorithmicFeedWorker.perform_async(config.id) }
  end
end
```

---

## Signal Worker

```ruby
# app/workers/recommendations/signal_worker.rb
class SignalWorker
  WEIGHTS         = { 'reblog' => 2.0, 'reply' => 2.0, 'favourite' => 0.5 }.freeze
  DOMAIN_MULTIPLIER = 0.5

  def perform(interaction_type, status_id, account_id)
    account = Account.find(account_id)
    return unless CustomFeedConfig.where(account: account, feed_type: 'algorithmic').exists?(enabled: true)

    status   = Status.find(status_id)
    original = status.original_status  # resolves reblog chain
    weight   = WEIGHTS.fetch(interaction_type, 0.0)
    return if weight.zero?

    original.tags.each { |tag| upsert_signal(account, 'tag', tag.name.downcase, weight) }
    upsert_signal(account, 'account', original.account_id.to_s, weight)

    # Domain signals only for remote accounts — all local accounts share the same
    # server so domain is not a meaningful cross-account signal.
    if original.account.domain.present?
      upsert_signal(account, 'domain', original.account.domain, weight * DOMAIN_MULTIPLIER)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end
end
```

### Wiring

`FavouriteConcern` enqueues `SignalWorker('favourite', status_id, account_id)` on create.
`StatusConcern` enqueues `SignalWorker('reblog', …)` and `SignalWorker('reply', …)`.
Both guard themselves: `SignalWorker#perform` returns immediately if the account has no enabled algorithmic configs.

---

## Frontend

### Feed Type Selector

The settings form shows a "Feed type" toggle (Standard / Algorithmic) when creating a new config. Algorithmic configs show additional sections:

- **Algorithm picker** (required): `affinity_score`
- **Algorithm options**: `batch_size`, `max_pending_age_hours`
- **Pre-filters**: same filter section, labelled "Pre-filters (applied at ingest)"
- **Algorithmic filters**: `min_signals`, `min_score`, `top_k_per_batch`
- **Removal / overflow**: same as standard feeds

### Signals Settings (`/custom_feeds/signals`)

`app/javascript/mastodon/features/custom_feeds_signals/` — displays signals grouped by type with per-signal weight sliders. Backed by the `RecommendationSignalsController` API.

---

## Future Work: ML Upgrade Path

This section describes what to build after `affinity_score` is running in production. Do not start until signals have been collecting for several weeks and the score distribution is stable.

### Phase 1: Observe

Before adding new algorithms, verify via logs and the Grafana dashboard:

- Score distribution (min, max, p50) per config run is stable
- Promotion rate > 10% (if very low, `min_score` threshold may be too tight or signals too sparse)
- Pending queue depth is bounded and not growing unboundedly
- `observation_count` distribution on `recommendation_signals` (accounts with few observations need `min_signals` gating)

### Phase 2: Naive Bayes Classifier (`rumale`)

A per-account trained classifier producing calibrated probability-of-engagement scores. Pure Ruby via [`rumale`](https://github.com/yoshoku/rumale) (`Rumale::NaiveBayes::ComplementNB`) — no Python runtime required. Well-suited for sparse, imbalanced datasets (few positive interactions vs many candidates).

**Would require:**

- `recommendation_training_examples` table (positive = interacted, negative = promoted-but-not-interacted)
- `recommendation_models` table (serialised `Rumale` model per account)
- `ModelTrainingWorker` — triggers when N new positive examples accumulate; at most once per hour per account
- `Recommendations::Algorithms::NaiveBayes` — loads model in `score_batch`, falls back to `AffinityScore` if no model exists
- Gemfile: `gem 'rumale'`, `gem 'numo-narray'`

### Phase 3: Further Algorithm Ideas

- **Collaborative filtering** — score based on what accounts with similar signal profiles interacted with
- **TF-IDF / embeddings** — cosine similarity between candidate and user interest vector
- **Recency-aware diversity (MMR)** — penalise candidates whose tag set overlaps heavily with already-promoted posts in the same batch; implementable as an opt-in `algorithmic_filter` step
- **Two Towers** — neural model for large-traffic instances; the `Algorithms::Base` interface is already compatible (a `TwoTowers` class could call a local HTTP sidecar in `score_batch`)

---

## File List

| File                                                               | Purpose                                                      |
| ------------------------------------------------------------------ | ------------------------------------------------------------ |
| `app/lib/recommendations/algorithms/base.rb`                       | Algorithm interface (includes `CustomFeeds::Registerable`)   |
| `app/lib/recommendations/algorithms/affinity_score.rb`             | Weighted affinity + time decay; single DB query per batch    |
| `app/workers/recommendations/signal_worker.rb`                     | Records interaction signals; skips domain for local accounts |
| `app/workers/recommendations/algorithmic_feed_worker.rb`           | Dequeue, score, filter, promote; structured logging          |
| `app/workers/recommendations/schedule_algorithmic_feeds_worker.rb` | Periodic trigger for algorithm worker                        |
| `app/models/recommendation_signal.rb`                              | Signal weight model                                          |
| `app/controllers/api/v1/recommendation_signals_controller.rb`      | Signals CRUD API                                             |
| `app/serializers/rest/recommendation_signal_serializer.rb`         | Signals API serializer                                       |
| `app/javascript/mastodon/features/custom_feeds_signals/index.tsx`  | Signals settings page                                        |
| `db/migrate/*_add_feed_type_to_custom_feed_configs.rb`             | `feed_type` column                                           |
| `db/migrate/*_create_recommendation_signals.rb`                    | Signals table                                                |

---

## Key Design Decisions

**Single DB query in `AffinityScore#score_batch`.** Previously three separate `SELECT` queries (one per signal type). Now one query with Ruby-side partitioning into three hashes. Reduces DB round-trips proportionally to batch size.

**Domain signals skip local accounts.** All local accounts share the same domain (`account.domain` is `nil`/blank). A domain signal for a local account would conflate all local authors, diluting the signal. `SignalWorker` and `AffinityScore` both check `account.domain.present?` before recording/using domain affinity.

**`min_signals` as a gate, not a filter.** The worker returns early before any scoring if signal count is below threshold, avoiding unnecessary `score_batch` calls and DB queries for cold-start accounts.

**Algorithm worker logs score statistics.** Each run logs `dequeued`, skips (with reason), score min/max/p50, and final `promoted`/`filtered_score`/`filtered_pipeline` counts at `info` level. These correlate with the Grafana `custom_feed_algo_candidates_total` metric.

**Signals are additive with upsert.** Each new interaction increments `weight` and `observation_count` on the existing row. Table size is bounded at one row per `(account, signal_type, entity_id)`. Scoring is a single O(N signals) query rather than per-status lookups.
