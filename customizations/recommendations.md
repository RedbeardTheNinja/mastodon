# Algorithmic Feeds

An **algorithmic feed** is a new variant of `CustomFeedConfig` that routes candidates through a scoring pipeline before deciding what enters the feed, rather than the direct filter-then-push model used by standard custom feeds. This document covers everything that has not yet been built.

---

## What Is Already Built

The full standard custom feed pipeline is shipped (pull sources, push sources, standard filters, removal strategies, overflow strategies, frontend UI, workers, cursors). Algorithmic feeds extend this foundation; they share all source types and standard filters but add a new pipeline stage between ingest and feed insertion.

---

## How Algorithmic Feeds Differ From Standard Custom Feeds

### Standard custom feed pipeline
```
Sources → (standard filters) → feed:custom:{list_id}
```

### Algorithmic feed pipeline
```
Sources → (standard pre-filters) → feed:algo:{list_id}:pending
                                         ↓  (periodic algorithm worker)
                                    score each candidate
                                         ↓
                               (algorithmic filters, e.g. min_score)
                                         ↓
                                  feed:custom:{list_id}
```

**Key differences:**
- Candidates are staged in a pending queue rather than pushed directly to the feed
- The algorithm worker runs on its own schedule, scores queued candidates, and makes promotion decisions
- Algorithmic filters (min_score, top_k_per_batch) require a score, so they are evaluated by the algorithm worker, not the ingest worker
- Standard filters (blocked_tags, interacted_posts, friends_liked) can still be applied as pre-filters at ingest time to reduce queue size
- The algorithm worker can observe the full pending batch before deciding, enabling relative ranking (e.g. "top 10 from this batch") rather than per-post binary decisions

---

## New Database Columns

### `feed_type` on `custom_feed_configs`

```ruby
# db/migrate/TIMESTAMP_add_feed_type_to_custom_feed_configs.rb
add_column :custom_feed_configs, :feed_type, :string, null: false, default: 'standard'
add_index  :custom_feed_configs, :feed_type
```

Values: `'standard'` (existing behaviour) | `'algorithmic'`. The existing pipeline is completely unchanged for `standard` configs.

---

## New Phase: `algorithm`

Algorithmic feeds gain a new pipeline phase between sources and filters:

| Phase               | Standard feeds | Algorithmic feeds |
| ------------------- | -------------- | ----------------- |
| `source`            | ✅             | ✅ (same types)   |
| `filter`            | ✅ (standard filters) | ✅ pre-filter at ingest |
| `algorithm`         | ❌ not applicable | ✅ one step, required |
| algorithmic filters | ❌             | ✅ evaluated by algorithm worker |
| `removal_strategy`  | ✅             | ✅ (same types)   |
| `overflow_strategy` | ✅             | ✅ (same types)   |

`Pipeline` detects algorithmic feeds via `config.feed_type == 'algorithmic'` and routes accordingly. `PullSourceIngestWorker` checks `pipeline.algorithmic?` and pushes to the pending queue instead of the feed.

---

## Pending Queue

```
Redis key:  feed:algo:{list_id}:pending
Type:       sorted set
Score:      unix timestamp of when the candidate arrived
Member:     status_id
```

The pending queue is a Redis sorted set scored by arrival time. It acts as a bounded staging area:

- **Max size**: same `FeedManager::MAX_ITEMS` cap. If the queue is full, the oldest entry is evicted before the new one is added (same `OldestFirst` trim logic used by the main feed).
- **Expiry**: candidates older than `max_pending_age_hours` (configurable per config, default 48h) are discarded by the algorithm worker without scoring. This prevents the worker from spending time scoring stale content.
- **Deduplication**: `ZSCORE` check before `ZADD` — same status is not queued twice.

`CustomFeeds::FeedManager` gains `pending_key(list_id)`, `enqueue_candidate(config, status)`, and `dequeue_pending(list_id, limit:, max_age_hours:)` methods.

---

## Signal Collection

The algorithm learns from the configured account's interaction history. Three interaction types contribute signals with different weights:

| Interaction | Weight | Reasoning |
| ----------- | ------ | --------- |
| Reblog (boost) | 2.0 | Explicit endorsement; high confidence signal |
| Reply | 2.0 | Deep engagement; high confidence signal |
| Favourite (like) | 0.5 | Mild positive signal; lower confidence |

When an interaction occurs, signals are extracted from the interacted post:

```
features = {
  "tag:#{tag.name}"          → weight  (for each tag on the post)
  "account:#{account_id}"    → weight  (author of the post)
  "domain:#{account.domain}" → weight * 0.5  (server-level affinity)
}
```

Signals are stored in `recommendation_signals` with upsert (accumulate `weight`, increment `observation_count`, update `last_observed_at`). The table design is unchanged from the earlier plan:

```ruby
create_table :recommendation_signals do |t|
  t.references :account,          null: false, foreign_key: true
  t.string     :signal_type,      null: false  # 'tag' | 'account' | 'domain'
  t.string     :entity_id,        null: false  # tag name | account_id | domain
  t.float      :weight,           null: false, default: 0.0
  t.integer    :observation_count, null: false, default: 0
  t.datetime   :last_observed_at
  t.timestamps
  t.index [:account_id, :signal_type, :entity_id],
          unique: true, name: 'idx_rec_signals_lookup'
end
```

`FavouriteConcern` and `StatusConcern` are extended to also enqueue `Recommendations::SignalWorker` when the account has any `algorithmic` feed configs.

---

## Algorithm Plugin Interface

```ruby
# app/lib/recommendations/algorithms/base.rb
module Recommendations
  module Algorithms
    REGISTRY = {} # rubocop:disable Style/MutableConstant

    class Base
      def self.key
        raise NotImplementedError
      end

      def self.register!
        REGISTRY[key] = self
      end

      # @param [Account] account  — the account who owns the feed
      def initialize(account)
        @account = account
      end

      # Score a batch of candidates. Returns [{status:, score: Float}] sorted
      # descending by score. Subclasses can override for batch efficiency.
      # @param [Array<Status>] candidates
      # @return [Array<{status: Status, score: Float}>]
      def score_batch(candidates)
        candidates
          .map { |s| { status: s, score: score_one(s) } }
          .sort_by { |r| -r[:score] }
      end

      # Score a single status.
      # @param [Status] status
      # @return [Float]
      def score_one(status)
        0.0
      end
    end
  end
end
```

The algorithm worker instantiates `klass.new(account)`, calls `score_batch(candidates)`, then evaluates algorithmic filters on each scored result.

---

## Initial Algorithm: `affinity_score`

Weighted feature affinity with time decay. No ML library required. Works from the first interaction and gets more accurate over time.

### Scoring

```
score(status) =
  Σ tag_affinity[tag]     (for each tag on the post, capped at 5 tags)
  + account_affinity[author_id]
  + domain_affinity[author.domain] × 0.5
  × exp(-λ × age_in_hours)   where λ = 0.05  (≈ half-life of 14 hours)
```

All affinity values are loaded from `recommendation_signals` for the account and cached in-memory for the duration of a single `score_batch` call (no per-post queries).

```ruby
# app/lib/recommendations/algorithms/affinity_score.rb
module Recommendations
  module Algorithms
    class AffinityScore < Base
      DECAY_LAMBDA = 0.05
      TAG_CAP      = 5

      def self.key
        'affinity_score'
      end

      def score_batch(candidates)
        # Load all signals once, cache for the batch
        @tag_affinities     = load_signals('tag')
        @account_affinities = load_signals('account')
        @domain_affinities  = load_signals('domain')
        super
      end

      def score_one(status)
        original    = status.reblog? ? status.reblog : status
        age_hours   = (Time.now - original.created_at) / 3600.0
        time_factor = Math.exp(-DECAY_LAMBDA * age_hours)

        tag_score = original.tags.first(TAG_CAP).sum do |tag|
          @tag_affinities[tag.name.downcase].to_f
        end

        account_score = @account_affinities[original.account_id.to_s].to_f
        domain_score  = @domain_affinities[original.account.domain.to_s].to_f * 0.5

        (tag_score + account_score + domain_score) * time_factor
      end

      private

      def load_signals(signal_type)
        RecommendationSignal
          .where(account: @account, signal_type: signal_type)
          .pluck(:entity_id, :weight)
          .to_h
      end
    end
  end
end
```

---

## ML Upgrade Path: `naive_bayes` via `rumale`

Once an account has accumulated enough interactions (suggested threshold: 30+ positive examples), the affinity score can be replaced or augmented with a trained classifier using the [`rumale`](https://github.com/yoshoku/rumale) gem — a Ruby scikit-learn equivalent.

**Why `rumale` + Naive Bayes:**
- Pure Ruby, no Python or native extensions beyond `numo-narray`
- **Complement Naive Bayes** (`Rumale::NaiveBayes::ComplementNB`) is specifically designed for imbalanced datasets, which this is (few positives, many negatives — most candidates are not interacted with)
- Feature vectors are sparse (tag presence + known account/domain booleans) — exactly the domain where Naive Bayes excels
- Training is fast (one pass over examples) and can run inside a Sidekiq worker
- Model is small (just class-conditional log-probabilities, serialisable as JSON)

### Feature vector structure

```
[
  tag_1_present?,   # 1 or 0 for each known tag in vocabulary
  tag_2_present?,
  ...
  is_known_account?,     # 1 if account seen in positive examples
  is_known_domain?,      # 1 if domain seen in positive examples
  log_followers_count,   # normalised popularity signal
]
```

Vocabulary (known tags + known accounts) is built from the account's `recommendation_signals`.

### Training schedule

`Recommendations::ModelTrainingWorker` runs:
- After every N new signal records (threshold configurable, default 10)
- At most once per hour per account (debounced)

Trained model is serialised and stored in a `recommendation_models` table or as a JSON blob on the config.

### Serving

At scoring time, the algorithm worker deserialises the model and calls `model.predict_proba(feature_matrix)` to get probability-of-engagement for each candidate. This replaces or supplements the affinity score once the model is available.

**Fallback:** if no trained model exists, fall back to `affinity_score`.

---

## Algorithmic Filters (exclusive to algorithmic feeds)

These filters are only meaningful in the algorithm worker where a score is available. They cannot be used in standard feeds.

| `step_type`       | Description                                              | Key options                        |
| ----------------- | -------------------------------------------------------- | ---------------------------------- |
| `min_score`       | Discard candidates below a score threshold               | `threshold: Float` (default 0.1)   |
| `top_k_per_batch` | Only promote the top K candidates from each worker run   | `k: Integer` (default 10)          |
| `min_signals`     | Skip scoring until the account has N signal records      | `count: Integer` (default 5)       |

These live in `Recommendations::AlgorithmicFilters::` (separate namespace from `CustomFeeds::Filters::` so the UI can distinguish them).

---

## Algorithm Worker

```ruby
# app/workers/recommendations/algorithmic_feed_worker.rb
module Recommendations
  class AlgorithmicFeedWorker
    include Sidekiq::Worker
    include Redisable

    sidekiq_options queue: 'default', retry: 3

    # Called periodically by ScheduleAlgorithmicFeedsWorker, or triggered
    # when the pending queue crosses a size threshold.
    def perform(config_id)
      config = CustomFeedConfig.algorithmic.enabled.find_by(id: config_id)
      return unless config&.account&.user&.signed_in_recently?

      algo_step = config.steps_for('algorithm').first
      return unless algo_step

      algo_klass = Recommendations::Algorithms::REGISTRY[algo_step.step_type]
      return unless algo_klass

      account    = config.account
      algo       = algo_klass.new(account)
      candidates = dequeue_candidates(config, algo_step.options)
      return if candidates.empty?

      # Check min_signals gate before any scoring
      min_signals_filter = config.steps_for('algorithmic_filter')
                                 .find { |s| s.step_type == 'min_signals' }
      if min_signals_filter
        required = min_signals_filter.options.fetch('count', 5).to_i
        actual   = RecommendationSignal.where(account: account).count
        return if actual < required
      end

      scored = algo.score_batch(candidates)

      # Apply algorithmic filters (min_score, top_k)
      scored = apply_algorithmic_filters(scored, config)

      # Apply standard pipeline filters (blocked_tags etc.) — last gate before promotion
      pipeline = CustomFeeds::Pipeline.new(config)
      scored.each do |result|
        next unless pipeline.passes_filters?(result[:status], account)

        CustomFeeds::FeedManager.instance.push_and_stream(config, result[:status])
      end
    end

    private

    def dequeue_candidates(config, options)
      max_age_hours = options.fetch('max_pending_age_hours', 48).to_i
      CustomFeeds::FeedManager.instance.dequeue_pending(
        config.list_id,
        limit:         options.fetch('batch_size', 100).to_i,
        max_age_hours: max_age_hours
      )
    end

    def apply_algorithmic_filters(scored, config)
      config.steps_for('algorithmic_filter').each do |step|
        scored = case step.step_type
                 when 'min_score'
                   threshold = step.options.fetch('threshold', 0.1).to_f
                   scored.select { |r| r[:score] >= threshold }
                 when 'top_k_per_batch'
                   k = step.options.fetch('k', 10).to_i
                   scored.first(k)
                 else
                   scored
                 end
      end
      scored
    end
  end
end
```

### Scheduler

```ruby
# app/workers/recommendations/schedule_algorithmic_feeds_worker.rb
module Recommendations
  class ScheduleAlgorithmicFeedsWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'scheduler', retry: 0

    def perform
      CustomFeedConfig
        .algorithmic
        .enabled
        .where(
          "last_pulled_at IS NULL OR " \
          "last_pulled_at + (pull_cadence_minutes * interval '1 minute') <= NOW()"
        )
        .find_each { |config| AlgorithmicFeedWorker.perform_async(config.id) }
    end
  end
end
```

Add to `config/sidekiq.yml`:
```yaml
recommendations_algorithmic_feeds:
  every: '5m'
  class: Recommendations::ScheduleAlgorithmicFeedsWorker
  queue: scheduler
```

---

## Signal Worker

```ruby
# app/workers/recommendations/signal_worker.rb
module Recommendations
  class SignalWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default', retry: 3

    WEIGHTS = {
      'reblog'    => 2.0,
      'reply'     => 2.0,
      'favourite' => 0.5,
    }.freeze

    DOMAIN_MULTIPLIER = 0.5

    def perform(interaction_type, status_id, account_id)
      account = Account.find(account_id)
      return unless CustomFeedConfig.algorithmic.enabled.where(account: account).exists?

      status   = Status.find(status_id)
      original = status.reblog? ? status.reblog : status
      weight   = WEIGHTS.fetch(interaction_type, 0.0)
      return if weight.zero?

      # Tag signals
      original.tags.each do |tag|
        upsert_signal(account, 'tag', tag.name.downcase, weight)
      end

      # Account signal
      upsert_signal(account, 'account', original.account_id.to_s, weight)

      # Domain signal (lower weight)
      upsert_signal(account, 'domain', original.account.domain.to_s, weight * DOMAIN_MULTIPLIER)
    rescue ActiveRecord::RecordNotFound
      true
    end

    private

    def upsert_signal(account, signal_type, entity_id, weight)
      RecommendationSignal.upsert(
        {
          account_id:        account.id,
          signal_type:       signal_type,
          entity_id:         entity_id,
          weight:            weight,
          observation_count: 1,
          last_observed_at:  Time.current,
          created_at:        Time.current,
          updated_at:        Time.current,
        },
        on_duplicate: Arel.sql(
          "weight = recommendation_signals.weight + EXCLUDED.weight, " \
          "observation_count = recommendation_signals.observation_count + 1, " \
          "last_observed_at = EXCLUDED.last_observed_at, " \
          "updated_at = EXCLUDED.updated_at"
        ),
        unique_by: :idx_rec_signals_lookup
      )
    end
  end
end
```

### Wiring into existing concerns

`FavouriteConcern` and `StatusConcern` already hook into every interaction. Add a second enqueue:

```ruby
# app/lib/custom_feeds/favourite_concern.rb (addition)
after_create_commit :enqueue_signal_worker

def enqueue_signal_worker
  Recommendations::SignalWorker.perform_async('favourite', status_id, account_id)
end

# app/lib/custom_feeds/status_concern.rb (addition inside enqueue_custom_feed_remove_if_interaction)
Recommendations::SignalWorker.perform_async('reblog', reblog_of_id, account_id) if reblog?
Recommendations::SignalWorker.perform_async('reply', in_reply_to_id, account_id) if reply?
```

The signal worker guards itself: it returns immediately if the account has no enabled algorithmic feed configs.

---

## Frontend: Algorithmic Feed Configuration

The settings UI needs to handle algorithmic feeds differently from standard feeds:

1. **Feed type selector** — when creating a config, the user picks Standard or Algorithmic. This sets `feed_type` on the config.

2. **Algorithm-first layout for algorithmic feeds:**
   - Algorithm picker (required, single selection)
   - Algorithm options (e.g. `batch_size`, `max_pending_age_hours`)
   - Sources (same multi-provider section as standard feeds)
   - Standard pre-filters (blocked_tags, interacted_posts, friends_liked — same section but labelled "Pre-filters")
   - Algorithmic filters (min_score, top_k_per_batch, min_signals — new section, only shown for algorithmic feeds)
   - Removal strategy (same)
   - Overflow strategy (same)

3. **Algorithm options component** (`algorithm_options.tsx`):
   - For `affinity_score`: no options needed (decay constant is fixed)
   - For `naive_bayes`: `min_training_examples` setting

4. **Algorithmic filter components** (`algorithmic_filter_section.tsx`):
   - `min_score`: slider or number input (0.0–2.0 range; affinity scores are unbounded above 1.0)
   - `top_k_per_batch`: number input, default 10
   - `min_signals`: number input, default 5

---

## Implementation Order

| Step | Work | Prerequisites |
| ---- | ---- | ------------- |
| 1 | Migration: `feed_type` column on `custom_feed_configs` | — |
| 2 | Migration: `recommendation_signals` table | — |
| 3 | `RecommendationSignal` model with `upsert_signal` helper | Step 2 |
| 4 | `Recommendations::Algorithms::Base` + `REGISTRY` | — |
| 5 | `Recommendations::Algorithms::AffinityScore` | Steps 3–4 |
| 6 | Register `affinity_score` in initializer | Step 5 |
| 7 | `Recommendations::SignalWorker` | Step 3 |
| 8 | Wire signal worker into `FavouriteConcern` + `StatusConcern` | Step 7 |
| 9 | `CustomFeeds::FeedManager` pending queue methods | — |
| 10 | Extend `CustomFeeds::Pipeline` with `algorithmic?` flag | Step 1 |
| 11 | Extend `PullSourceIngestWorker` to route to pending queue for algorithmic configs | Steps 9–10 |
| 12 | `Recommendations::AlgorithmicFeedWorker` | Steps 5, 9 |
| 13 | `Recommendations::ScheduleAlgorithmicFeedsWorker` + sidekiq.yml entry | Step 12 |
| 14 | Frontend: feed type selector + algorithmic layout | — |
| 15 | Frontend: algorithm options + algorithmic filter components | Step 14 |
| 16 | API: permit `feed_type` + `algorithmic_filter` phase | — |
| 17 | *(Optional)* `Recommendations::Algorithms::NaiveBayes` + `rumale` gem + training worker | Steps 3–5 |
| 18 | Update `customizations/README.md`, `recommendations.md`, and `custom-feeds.md` to document algorithmic feeds: Redis key patterns, new DB tables, worker architecture, and signal collection | Steps 1–16 |

Steps 1–13 are backend only and fully testable before the frontend work.

---

## File List

### New Backend Files

| File | Purpose |
| ---- | ------- |
| `db/migrate/*_add_feed_type_to_custom_feed_configs.rb` | `feed_type` column |
| `db/migrate/*_create_recommendation_signals.rb` | Signal weights table |
| `app/models/recommendation_signal.rb` | Signal model |
| `app/lib/recommendations/algorithms/base.rb` | Algorithm interface + REGISTRY |
| `app/lib/recommendations/algorithms/affinity_score.rb` | Weighted affinity algorithm |
| `app/lib/recommendations/algorithms/naive_bayes.rb` | *(optional)* rumale classifier |
| `app/workers/recommendations/signal_worker.rb` | Writes signals on interaction |
| `app/workers/recommendations/algorithmic_feed_worker.rb` | Score + promote candidates |
| `app/workers/recommendations/schedule_algorithmic_feeds_worker.rb` | Periodic trigger |

### Modified Backend Files

| File | Change |
| ---- | ------ |
| `app/lib/custom_feeds/feed_manager.rb` | Add `pending_key`, `enqueue_candidate`, `dequeue_pending` |
| `app/lib/custom_feeds/pipeline.rb` | Add `algorithmic?` flag |
| `app/workers/custom_feeds/pull_source_ingest_worker.rb` | Route to pending queue for algorithmic configs |
| `app/lib/custom_feeds/favourite_concern.rb` | Enqueue `SignalWorker` |
| `app/lib/custom_feeds/status_concern.rb` | Enqueue `SignalWorker` |
| `config/initializers/custom_feeds.rb` | Register `AffinityScore` algorithm |
| `config/sidekiq.yml` | Add algorithmic feeds scheduler |

### New Frontend Files

| File | Purpose |
| ---- | ------- |
| `custom_feeds_settings/components/algorithmic_feed_form.tsx` | Algorithm-first layout for algorithmic configs |
| `step_options/algorithm_options.tsx` | Per-algorithm options |
| `step_options/algorithmic_filter_options.tsx` | min_score / top_k / min_signals controls |

---

## Key Design Decisions

**Pending queue enables batch ranking.** Pushing directly to the feed (standard pipeline) means each post is evaluated in isolation. The pending queue lets the algorithm worker see N candidates together and pick the best K — which is qualitatively different from a per-post binary decision.

**Affinity score works from the first interaction; Naive Bayes waits for enough data.** The `min_signals` algorithmic filter lets users gate the feed until the algorithm has enough signal to be meaningful. Before that threshold, the pending queue accumulates but nothing is promoted.

**`rumale` for Naive Bayes — no Python runtime required.** `Rumale::NaiveBayes::ComplementNB` is pure Ruby (backed by `numo-narray`). It handles the imbalanced dataset characteristic of this problem (few positive interactions vs. many candidates). The trained model is a small Ruby object that can be serialised to JSON and cached. Add `gem 'rumale'` and `gem 'numo-narray'` to the Gemfile.

**Signals are additive with upsert.** Each new interaction increments `weight` and `observation_count` on the existing row rather than creating a new row. This keeps the table size bounded (one row per account × signal_type × entity_id) and makes scoring queries simple: one `SELECT` per signal type loads everything into a hash.

**Standard filters run at ingest time (pre-filter); algorithmic filters run after scoring.** `blocked_tags` and `interacted_posts` are cheap binary decisions that can reduce queue size early. Algorithmic filters like `min_score` need the score and so run in the algorithm worker. Both filter types appear in the same UI section for algorithmic feeds but are clearly labelled.

**Feed type is on the config, not the list.** A list can be repurposed from a standard feed to an algorithmic feed by changing `feed_type`. The list itself carries no semantics. This is consistent with the existing design where `CustomFeedConfig` is the only entity that controls feed behaviour.

---

## Algorithm Extension Plan

This section describes what to build after `AffinityScore` is running and producing results. Do not start this work until step 16 is complete and the feed is being used in production — measure first, then extend.

### Phase 1: Observe and Instrument (no code changes required)

Before adding new algorithms, instrument what's already there:

- Log the score distribution (min, max, p50, p95) each time `AlgorithmicFeedWorker` runs, tagged by `config_id`. This tells you whether `min_score` thresholds need adjustment and whether the affinity values have stabilised.
- Log promotion rate per run (candidates dequeued vs. candidates promoted). A very low rate suggests the `min_score` threshold is too tight or signals are sparse.
- Log pending queue depth over time. Growing queues indicate the worker cadence is too slow or the sources are over-producing.
- Track `observation_count` distribution on `recommendation_signals`. Accounts with very few observations will have unreliable scores — `min_signals` should gate them out.

When these metrics look healthy (stable score distribution, >10% promotion rate, bounded queue depth), move to Phase 2.

### Phase 2: Naive Bayes Classifier

This is step 17 in the implementation order. The goal is a trained per-account classifier that produces calibrated probability-of-engagement scores rather than raw affinity sums.

**Training data design:**
- Positive examples: statuses that the account reblogged, replied to, or liked (already in `recommendation_signals` — reconstruct from `entity_id` where `signal_type = 'account'` and join to `Status`). A cleaner approach is to log a `training_example` row at signal time with `(account_id, status_id, label: 'positive')`.
- Negative examples: statuses that passed filters but were _not_ interacted with. These need to be sampled. A `training_examples` table with `label: 'negative'` should be populated by the `AlgorithmicFeedWorker` when it promotes candidates — log a negative for each promoted-but-later-ignored post (i.e. posts that were in the feed and expired without interaction).
- Ratio: aim for ~5:1 negative:positive to reflect realistic class imbalance. `ComplementNB` tolerates higher imbalance but scores become harder to threshold.

**Training table:**

```ruby
create_table :recommendation_training_examples do |t|
  t.references :account,  null: false, foreign_key: true
  t.bigint     :status_id, null: false
  t.string     :label,    null: false  # 'positive' | 'negative'
  t.timestamps
  t.index [:account_id, :status_id, :label], unique: true,
          name: 'idx_training_examples_lookup'
end
```

**Model storage:**

```ruby
create_table :recommendation_models do |t|
  t.references :account,       null: false, foreign_key: true
  t.string     :algorithm_key, null: false  # 'naive_bayes'
  t.text       :serialized,    null: false  # Marshal.dump or JSON
  t.integer    :positive_count, null: false, default: 0
  t.integer    :negative_count, null: false, default: 0
  t.datetime   :trained_at
  t.timestamps
  t.index [:account_id, :algorithm_key], unique: true
end
```

Use `Marshal.dump` for the `Rumale` model object (it serialises cleanly). Store as base64 in a `text` column or a `bytea` column.

**Training worker:**

```ruby
# app/workers/recommendations/model_training_worker.rb
# Triggered when: new training examples are logged AND the count crosses a
# threshold (default 10 new examples since last training).
# Debounce: at most once per hour per account.
class ModelTrainingWorker
  include Sidekiq::Worker
  sidekiq_options queue: 'default', retry: 2

  MIN_POSITIVE = 30   # don't train until we have enough positive examples
  RETRAIN_AFTER_NEW = 10  # retrain after this many new examples since last train

  def perform(account_id)
    account  = Account.find(account_id)
    examples = RecommendationTrainingExample.where(account: account)

    pos_count = examples.where(label: 'positive').count
    return if pos_count < MIN_POSITIVE

    # Build feature matrix and label vector
    # (feature extraction identical to NaiveBayes#build_features)
    x, y = build_training_data(account, examples)
    model = Rumale::NaiveBayes::ComplementNB.new(smoothing_param: 1.0)
    model.fit(x, y)

    RecommendationModel.upsert(
      {
        account_id:     account.id,
        algorithm_key:  'naive_bayes',
        serialized:     Base64.strict_encode64(Marshal.dump(model)),
        positive_count: pos_count,
        negative_count: examples.where(label: 'negative').count,
        trained_at:     Time.current,
        created_at:     Time.current,
        updated_at:     Time.current,
      },
      on_duplicate: Arel.sql(
        "serialized = EXCLUDED.serialized, " \
        "positive_count = EXCLUDED.positive_count, " \
        "negative_count = EXCLUDED.negative_count, " \
        "trained_at = EXCLUDED.trained_at, " \
        "updated_at = EXCLUDED.updated_at"
      ),
      unique_by: [:account_id, :algorithm_key]
    )
  end
end
```

**Retraining cadence:** the training worker is enqueued by `SignalWorker` after every `RETRAIN_AFTER_NEW` new positive signals. A Redis counter per account (`rec:signal_count:{account_id}`) tracks signals since last training; when it crosses the threshold the worker is enqueued and the counter resets. Add `sidekiq-unique-jobs` or a Redis `SET NX` lock to enforce the per-hour debounce.

**Fallback:** `NaiveBayes#score_one` loads the model from `recommendation_models` at the start of each `score_batch` call. If no model exists (or it's older than 7 days), it delegates to `AffinityScore#score_one` for that account.

### Phase 3: Further Algorithm Ideas

These are not planned for immediate implementation but worth considering once Naive Bayes is working:

**Collaborative filtering (user-based):**
- Find accounts with similar signal profiles (cosine similarity over tag affinity vectors).
- Score candidates based on what similar accounts interacted with.
- Requires an offline similarity computation job; expensive at scale but effective for cold-start accounts with few personal signals.
- Could use Mastodon's existing follow graph as a similarity proxy (follows → similar taste → weight their interactions).

**Content similarity (TF-IDF or embeddings):**
- Build a TF-IDF document vector per status from its text + tags.
- Maintain a "user interest vector" (weighted average of interacted-post vectors).
- Score candidates by cosine similarity to the interest vector.
- Works for accounts that interact with specific topics whose tag coverage is sparse.
- Embeddings (sentence-transformers via a small Ruby FFI or HTTP sidecar) would improve this significantly but add infrastructure complexity.

**Two Towers (deferred):**
- Only worth considering if the server has enough traffic to justify a trained neural model.
- Requires: positive/negative interaction logs, a Python training pipeline, periodic retraining, and a serving path (likely HTTP sidecar or pre-computed embedding index).
- The `Algorithms::Base` interface is already compatible — a `TwoTowers` class could call a local HTTP endpoint in `score_batch`.
- Recommended approach if/when adopted: train offline on PostgreSQL interaction data via `pg` gem or CSV export, serve via a lightweight FastAPI endpoint on the same host, call it from `AlgorithmicFeedWorker` with a short timeout and an `AffinityScore` fallback.

**Recency-aware diversity:**
- After scoring, apply a Maximal Marginal Relevance (MMR) step to reduce redundancy in the promoted batch: prefer candidates that are both high-scoring and dissimilar to already-promoted posts in the same run.
- Tag-based dissimilarity is a cheap proxy: penalise candidates whose tag set overlaps heavily with already-selected posts.
- Implement as an additional `algorithmic_filter` step so it's opt-in per config.
