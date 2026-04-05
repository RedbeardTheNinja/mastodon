# Custom Feeds Refactoring Plan

Code quality and maintainability improvements for the custom feeds system.
Scoped to what is currently implemented; the Naive Bayes / Two Towers algorithm
extensions are not addressed here.

Each item has a **Goal tag** mapping to one of the six objectives:

- **DUP** — Reduce duplication
- **SIM** — Simplify logic
- **TEST** — Increase test coverage
- **ISO** — Isolate from Mastodon / support gem extraction
- **LOG** — Increase log coverage
- **ERR** — Improve error handling

Items within each section are ordered by impact.

---

## 1. Shared Plugin Infrastructure _(DUP · ISO)_

### Problem

`Sources::Base`, `Filters::Base`, `RemovalStrategies::Base`,
`OverflowStrategies::Base`, and `Recommendations::Algorithms::Base` each
declare their own copy of:

```ruby
REGISTRY = {}

def self.key
  raise NotImplementedError
end

def self.register!
  REGISTRY[key] = self
end
```

This is seven copies of identical boilerplate and will need to grow again when
algorithmic filters are made pluggable (see §7).

### Fix

Extract a `Registerable` concern shared by all base classes:

```ruby
# app/lib/custom_feeds/registerable.rb
module CustomFeeds
  module Registerable
    def self.included(base)
      base.instance_variable_set(:@registry, {})
      base.extend(ClassMethods)
    end

    module ClassMethods
      def registry
        @registry
      end

      def key
        raise NotImplementedError, "#{name} must implement .key"
      end

      def register!
        registry[key] = self
      end
    end
  end
end
```

Each base class then does `include CustomFeeds::Registerable` and removes its
`REGISTRY` constant plus the three repeated methods. The constant reference
(`Sources::Base::REGISTRY`) is replaced with `Sources::Base.registry`, or the
base class can expose `REGISTRY = registry` as an alias for backwards
compatibility.

**Files affected:** `sources/base.rb`, `filters/base.rb`,
`removal_strategies/base.rb`, `overflow_strategies/base.rb`,
`recommendations/algorithms/base.rb`

---

## 2. Reblog Resolution Helper _(DUP · SIM)_

### Problem

The pattern `original = status.reblog? ? status.reblog : status` appears in at
least seven files:

- `custom_feeds/filters/interacted_posts.rb`
- `custom_feeds/filters/blocked_tags.rb`
- `custom_feeds/filters/friends_liked.rb`
- `recommendations/algorithms/affinity_score.rb`
- `recommendations/signal_worker.rb`
- `custom_feeds/feed_remove_worker.rb`
- `custom_feeds/status_concern.rb`

### Fix

Add a method to `Status` (or a Status decorator) via the existing
`CustomFeeds::StatusConcern`:

```ruby
# app/lib/custom_feeds/status_concern.rb
def original_status
  reblog? ? reblog : self
end
```

Every call site becomes `status.original_status`. This also makes it testable
in one place. If Mastodon upstream ever adds this helper, the `status_concern`
version can be removed without touching call sites.

**Files affected:** the seven listed above plus `status_concern.rb`

---

## 3. Remote Source Base Class _(DUP · ERR · LOG)_

### Problem

`RemoteTagTimeline` and `RemotePublicTimeline` duplicate:

- HTTP fetch with a hardcoded 10-second timeout
- Response success check
- JSON parse
- `max_id` / `max_remote_id` extraction
- URI batch resolution via `resolve_uris`
- `FetchResult` construction
- Bucket → source entry lookup with a fallback to `sources.first`

They also share a fragile bucket naming convention that must be kept in sync
between `buckets_for` and the matching logic inside `fetch_candidates`.

### Fix

Extract a `RemoteTimelineSource` base class:

```ruby
# app/lib/custom_feeds/sources/remote_timeline_source.rb
module CustomFeeds
  module Sources
    class RemoteTimelineSource < Base
      HTTP_TIMEOUT = Integer(ENV.fetch('CUSTOM_FEEDS_HTTP_TIMEOUT', '10'))

      def self.pull_source? = true

      # Subclasses implement:
      #   build_url(domain, options, params) → String
      #   entry_for_bucket(sources, bucket)  → Hash
      #   default_params(options)            → Hash

      def fetch_candidates(account, options, since_id: nil, bucket: '')
        sources = options['sources'].presence || []
        entry   = entry_for_bucket(sources, bucket)
        return FetchResult.new(nil, []) unless entry

        domain  = entry['domain'].to_s.strip
        return FetchResult.new(nil, []) if domain.blank?

        params = default_params(options).merge(limit: fetch_limit(options))
        params[:min_id] = since_id if since_id.present?

        url      = build_url(domain, entry, params)
        response = fetch(url, params)
        return FetchResult.new(nil, []) unless response

        parse_response(response, domain)
      rescue => e
        Rails.logger.warn(
          "CustomFeeds #{self.class.name} fetch failed " \
          "(bucket=#{bucket.inspect}): #{e.class}: #{e.message}"
        )
        FetchResult.new(nil, [])
      end

      private

      def fetch(url, _params)
        resp = HTTP.timeout(HTTP_TIMEOUT).get(url)
        unless resp.status.success?
          Rails.logger.debug { "CustomFeeds HTTP #{resp.status} for #{url}" }
          return nil
        end
        resp
      rescue HTTP::TimeoutError, HTTP::ConnectionError, SocketError => e
        Rails.logger.warn("CustomFeeds HTTP error for #{url}: #{e.message}")
        nil
      end

      def parse_response(response, domain)
        statuses = JSON.parse(response.body.to_s)
        uris     = statuses.filter_map { |s| s['uri'] }
        max_id   = statuses.last&.dig('id')

        Rails.logger.debug do
          "CustomFeeds #{self.class.name}: fetched #{uris.size} URIs " \
          "from #{domain}, max_id=#{max_id.inspect}"
        end

        resolved = resolve_uris(uris)
        FetchResult.new(max_id, resolved)
      rescue JSON::ParserError => e
        Rails.logger.warn("CustomFeeds #{self.class.name} JSON error: #{e.message}")
        FetchResult.new(nil, [])
      end

      def fetch_limit(options)
        raw = options['limit'].to_i
        raw.clamp(1, max_limit)
      end

      def max_limit = 80
    end
  end
end
```

`RemoteTagTimeline` and `RemotePublicTimeline` then only implement
`build_url`, `entry_for_bucket`, and `default_params`, eliminating ~80% of
their current code.

The configurable `HTTP_TIMEOUT` environment variable also removes a hardcoded
constant.

**Files affected:** `sources/remote_tag_timeline.rb`,
`sources/remote_public_timeline.rb`; new file
`sources/remote_timeline_source.rb`

---

## 4. FeedManager Logging and Cleanup _(LOG · ERR)_

### Problem

`CustomFeeds::FeedManager` performs all Redis mutations silently. When a
status is missing from a custom feed or appears unexpectedly, there is no trace
in the logs. Additionally, destroying a `CustomFeedConfig` does not clean up
any of its Redis keys, leaking sorted sets and hashes indefinitely.

### Fix — Logging

Add `Rails.logger` calls at key decision points:

```ruby
def push(config, status)
  feed_key = key(config.list_id)
  overflow = overflow_strategy_for(config)

  if overflow.at_capacity?(redis.zcard(feed_key), ::FeedManager::MAX_ITEMS)
    Rails.logger.debug do
      "CustomFeeds::FeedManager#push: feed #{config.list_id} at capacity, " \
      "overflow=#{overflow.class.name}"
    end
    return false
  end

  redis.zadd(feed_key, status.id, status.id)
  redis.hset(inserted_at_key(config.list_id), status.id, Time.now.to_i)
  overflow.trim(redis, feed_key, ::FeedManager::MAX_ITEMS)
  true
end

def enqueue_candidate(config, status)
  pkey = pending_key(config.list_id)
  if redis.zscore(pkey, status.id)
    Rails.logger.debug { "CustomFeeds: #{status.id} already in pending queue #{config.list_id}, skipping" }
    return
  end
  # ...
end
```

### Fix — Redis Cleanup

Add an `after_destroy` callback (or a Rails `dependent:` option) to
`CustomFeedConfig` that clears all feed keys:

```ruby
# app/models/custom_feed_config.rb
after_destroy :cleanup_redis_keys

private

def cleanup_redis_keys
  CustomFeeds::FeedManager.instance.delete_feed(list_id)
end
```

```ruby
# app/lib/custom_feeds/feed_manager.rb
def delete_feed(list_id)
  redis.del(key(list_id), inserted_at_key(list_id), pending_key(list_id))
  Rails.logger.info("CustomFeeds: deleted Redis keys for list #{list_id}")
end
```

**Files affected:** `feed_manager.rb`, `custom_feed_config.rb`

---

## 5. Pipeline Logging _(LOG)_

### Problem

When a status does not appear in a custom feed the only way to investigate is
to add `Rails.logger` calls manually and redeploy. `Pipeline#include?` and
`Pipeline#passes_filters?` are completely silent.

### Fix

Add structured debug logging at the phase level — gated with `Rails.logger.debug?`
to avoid string interpolation cost in production:

```ruby
def include?(status, account)
  push = @source_entries.reject { |e| e[:klass].pull_source? }
  if push.empty?
    Rails.logger.debug { "Pipeline: no push sources for config, skipping status #{status.id}" }
    return false
  end

  source_pass = push.any? { |e| e[:instance].includes?(status, account, e[:options]) }
  unless source_pass
    Rails.logger.debug { "Pipeline: status #{status.id} rejected by all sources" }
    return false
  end

  blocking_filter = @filter_entries.find { |e| e[:instance].exclude?(status, account, e[:options]) }
  if blocking_filter
    Rails.logger.debug do
      "Pipeline: status #{status.id} excluded by filter #{blocking_filter[:klass].key}"
    end
    return false
  end

  true
end
```

The same pattern applies to `passes_filters?`.

**Files affected:** `pipeline.rb`

---

## 6. Worker Error Handling _(ERR · LOG)_

### Problem

Worker error handling is inconsistent:

- `FeedInsertWorker`, `FeedRemoveWorker`, `SignalWorker` catch only
  `ActiveRecord::RecordNotFound` and silently return `true`.
- `PullSourceIngestWorker` can raise from HTTP errors, JSON parse failures, and
  Redis operations — none of which are caught.
- `TimeBasedRemovalWorker` has the best error handling (per-config rescue with
  log), but it is not the pattern used elsewhere.
- In `Sources::Base#resolve_uris`, a bare `rescue` swallows all errors
  including programming mistakes.

### Fix — Consistent Pattern

Adopt the `TimeBasedRemovalWorker` pattern across all workers:

```ruby
def perform(status_id, account_id)
  # ... setup ...
rescue ActiveRecord::RecordNotFound
  # Status or account was deleted before the job ran — expected, not an error.
  Rails.logger.debug { "#{self.class.name}: record not found (status=#{status_id} account=#{account_id})" }
end
```

For operations that iterate configs (RemoveWorker, TimeBasedRemovalWorker),
wrap each config in a rescue so one bad config doesn't abort the rest:

```ruby
configs.each do |config|
  process_config(config)
rescue => e
  Rails.logger.error(
    "#{self.class.name} failed for config #{config.id}: #{e.class}: #{e.message}",
    exception: e
  )
end
```

### Fix — resolve_uris

Replace bare `rescue` with specific exception types and a log:

```ruby
def resolve_uris(uris)
  Chewy.strategy(:bypass) do
    uris.filter_map do |uri|
      Status.find_by(uri: uri) || ResolveURLService.new.call(uri)
    rescue ActivityPub::FetchRemoteActorService::Error,
           Mastodon::UnexpectedResponseError,
           HTTP::Error,
           OpenSSL::SSL::SSLError => e
      Rails.logger.debug { "CustomFeeds: could not resolve #{uri}: #{e.message}" }
      nil
    end
  end
end
```

**Files affected:** `feed_insert_worker.rb`, `feed_remove_worker.rb`,
`signal_worker.rb`, `pull_source_ingest_worker.rb`,
`sources/base.rb`

---

## 7. Pluggable Algorithmic Filters _(SIM · DUP · ISO)_

### Problem

`AlgorithmicFeedWorker#apply_algorithmic_filters` is a hard-coded `case`
statement:

```ruby
when 'min_score'  → scored.select { ... }
when 'top_k_per_batch' → scored.first(k)
else → scored   # unrecognised filter silently passes everything through
```

This is the only part of the pipeline that is not registry-driven. Adding a
new algorithmic filter requires modifying the worker — the opposite of the
pluggable design everywhere else.

### Fix

Create `AlgorithmicFilters::Base` with the same registry pattern (or reuse
`Registerable` from §1):

```ruby
# app/lib/recommendations/algorithmic_filters/base.rb
module Recommendations
  module AlgorithmicFilters
    class Base
      include CustomFeeds::Registerable

      # @param [Array<{status:, score:}>] scored
      # @param [Hash] options
      # @return [Array<{status:, score:}>]
      def apply(scored, options)
        raise NotImplementedError
      end
    end
  end
end

# app/lib/recommendations/algorithmic_filters/min_score.rb
class MinScore < Base
  def self.key = 'min_score'
  def apply(scored, options)
    threshold = options.fetch('threshold', 0.1).to_f
    scored.select { |r| r[:score] >= threshold }
  end
end

# app/lib/recommendations/algorithmic_filters/top_k_per_batch.rb
class TopKPerBatch < Base
  def self.key = 'top_k_per_batch'
  def apply(scored, options)
    scored.first(options.fetch('k', 10).to_i)
  end
end
```

`AlgorithmicFeedWorker#apply_algorithmic_filters` becomes:

```ruby
def apply_algorithmic_filters(scored, config)
  config.steps_for('algorithmic_filter').each_with_object(scored) do |step, acc|
    filter = Recommendations::AlgorithmicFilters::Base.registry[step.step_type]
    if filter.nil?
      Rails.logger.warn("Unknown algorithmic filter: #{step.step_type.inspect}")
      next acc
    end
    acc.replace(filter.new.apply(acc, step.options))
  end
end
```

**Files affected:** `algorithmic_feed_worker.rb`; new directory
`app/lib/recommendations/algorithmic_filters/`; update
`config/initializers/custom_feeds.rb` to register the two built-in filters

---

## 8. Algorithm Logging and Score Observability _(LOG)_

### Problem

`AlgorithmicFeedWorker` scores and filters candidates with no log output.
When no posts appear in an algorithmic feed there is no way to tell whether the
issue is an empty pending queue, a min_signals gate, a min_score threshold, or
a pipeline filter rejection.

### Fix

Add structured log lines at each decision point:

```ruby
def perform(config_id)
  # ...
  Rails.logger.info do
    "AlgorithmicFeedWorker: config=#{config_id} account=#{account.id} " \
    "dequeued=#{candidates.size}"
  end

  # after min_signals check:
  Rails.logger.info do
    "AlgorithmicFeedWorker: config=#{config_id} skipped (min_signals: " \
    "need #{required}, have #{actual})"
  end

  # after scoring:
  scores = scored.map { |r| r[:score] }
  Rails.logger.info do
    "AlgorithmicFeedWorker: config=#{config_id} scored #{scored.size} candidates " \
    "min=#{scores.min&.round(3)} max=#{scores.max&.round(3)} " \
    "p50=#{percentile(scores, 50)&.round(3)}"
  end

  # after filter + promotion:
  Rails.logger.info do
    "AlgorithmicFeedWorker: config=#{config_id} promoted=#{promoted_count} " \
    "filtered_score=#{filtered_score_count} filtered_pipeline=#{filtered_pipeline_count}"
  end
end
```

Add a small private `percentile(array, pct)` helper.

**Files affected:** `algorithmic_feed_worker.rb`

---

## 9. StepOptions Validation _(ERR)_

### Problem

`CustomFeedStep#options` is a raw JSONB column with no validation. A
`remote_tag_timeline` step with a misspelled `'sources'` key silently produces
an empty feed with no indication of why. Options are validated by each source /
filter class but only at runtime during a feed operation.

### Fix

Add an options schema validation to `CustomFeedStep`. Each step class declares
a schema, and the model validates against it on save:

```ruby
# app/models/custom_feed_step.rb
validates :options, step_options: true

# app/validators/step_options_validator.rb
class StepOptionsValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    klass = registry_for(record.phase)&.[](record.step_type)
    return unless klass.respond_to?(:validate_options)

    errors = klass.validate_options(value || {})
    errors.each { |msg| record.errors.add(attribute, msg) }
  end

  private

  def registry_for(phase)
    {
      'source'              => CustomFeeds::Sources::Base.registry,
      'filter'              => CustomFeeds::Filters::Base.registry,
      'algorithm'           => Recommendations::Algorithms::Base.registry,
      'algorithmic_filter'  => Recommendations::AlgorithmicFilters::Base.registry,
      'removal_strategy'    => CustomFeeds::RemovalStrategies::Base.registry,
      'overflow_strategy'   => CustomFeeds::OverflowStrategies::Base.registry,
    }[phase]
  end
end
```

Each step class that has required options implements a class method:

```ruby
# app/lib/custom_feeds/sources/remote_tag_timeline.rb
def self.validate_options(opts)
  errors = []
  errors << "sources must be an array" unless opts['sources'].is_a?(Array)
  opts.fetch('sources', []).each_with_index do |s, i|
    errors << "sources[#{i}].domain is required" if s['domain'].blank?
    errors << "sources[#{i}].tag is required"    if s['tag'].blank?
  end
  errors
end
```

**Files affected:** `custom_feed_step.rb`; new
`app/validators/step_options_validator.rb`; each source/filter/strategy class
that has required options

---

## 10. Status Deletion Cleanup _(ERR)_

### Problem

When a `Status` is deleted from Mastodon, it is removed from home feeds via
existing hooks, but it is **not** removed from custom feeds. Deleted statuses
accumulate in `feed:custom:*` sorted sets and `feed:custom:*:inserted_at`
hashes until a feed operation eventually tries to render them.

### Fix

Extend `CustomFeeds::StatusConcern` with an `after_destroy_commit` hook:

```ruby
# app/lib/custom_feeds/status_concern.rb
after_destroy_commit :remove_from_custom_feeds

def remove_from_custom_feeds
  CustomFeedConfig
    .enabled
    .where(account_id: AccountFollow.where(target_account: account).select(:account_id))
    .find_each do |config|
      CustomFeeds::FeedManager.instance.remove(config, id)
    end
rescue => e
  Rails.logger.error("CustomFeeds: failed to remove status #{id} from custom feeds: #{e.message}")
end
```

This is intentionally conservative — it scopes to accounts that follow the
status author, which is the same set of accounts that could have the status in
their custom feeds. An alternative is to query Redis directly for membership,
which is cheaper at scale but requires a different Redis pattern.

**Files affected:** `status_concern.rb`

---

## 11. Mastodon Adapter Layer _(ISO)_

### Problem

The custom feeds code has deep runtime dependencies on Mastodon internals:

| Dependency                                    | Where used                                    | Extraction impact         |
| --------------------------------------------- | --------------------------------------------- | ------------------------- |
| `Redisable` mixin                             | `FeedManager`, `StatsCollectorWorker`         | Provides `redis` accessor |
| `::FeedManager.instance.filter(:home, ...)`   | `Sources::FollowedPosts`, `FeedInsertConcern` | Core gate logic           |
| `InlineRenderer.render(status, nil, :status)` | `FeedManager#push_and_stream`                 | JSON serialisation        |
| `ResolveURLService`                           | `Sources::Base#resolve_uris`                  | ActivityPub fetching      |
| `Chewy.strategy(:bypass)`                     | `Sources::Base#resolve_uris`                  | Search index suppression  |
| `DatabaseHelper`                              | `FeedInsertWorker`                            | Primary/replica routing   |
| Model callbacks injected at runtime           | `config/initializers/custom_feeds.rb`         | Hook discovery            |

If the goal is extracting this to a gem, the approach is an **Adapter module**
defined in the gem with a configurable implementation provided by the host app:

```ruby
# In the gem:
module CustomFeeds
  module Adapter
    class << self
      attr_writer :home_feed_filter, :status_serializer, :uri_resolver

      def passes_home_filter?(status, account)
        @home_feed_filter&.call(status, account) ?? true
      end

      def serialize_status(status)
        @status_serializer&.call(status) or raise NotImplementedError
      end

      def resolve_uri(uri)
        @uri_resolver&.call(uri)
      end
    end
  end
end

# In Mastodon's initializer:
CustomFeeds::Adapter.home_feed_filter = ->(status, account) {
  !::FeedManager.instance.filter(:home, status, account)
}
CustomFeeds::Adapter.status_serializer = ->(status) {
  InlineRenderer.render(status, nil, :status)
}
CustomFeeds::Adapter.uri_resolver = ->(uri) {
  Chewy.strategy(:bypass) { ResolveURLService.new.call(uri) }
}
```

This is a **preparatory step** — the actual gem extraction (described in
`plugin-plan.md`) requires this adapter to be in place first. It can be
introduced incrementally:

1. Add the `Adapter` module with only the `home_feed_filter` hook
2. Replace all direct `::FeedManager.instance.filter(:home, ...)` calls with
   `CustomFeeds::Adapter.passes_home_filter?`
3. Repeat for other dependencies one at a time

Each step is independently reviewable and low-risk.

**Files affected:** new `app/lib/custom_feeds/adapter.rb`;
`config/initializers/custom_feeds.rb`;
`sources/followed_posts.rb`, `feed_manager.rb`, `sources/base.rb`

---

## 12. Optimise TimeBasedRemovalWorker _(SIM · ERR)_

### Problem

`process_config` calls `redis.zrange(feed_key, 0, -1).to_set` which loads the
entire feed into memory to check hash entry membership. On a feed at capacity
(5 000 items) this is a 5 000-element Set allocation per config per run.

### Fix

Replace the full-feed load with a `ZSCORE` lookup per hash entry:

```ruby
def process_config(config)
  feed_key = CustomFeeds::FeedManager.instance.key(config.list_id)
  hash_key = CustomFeeds::FeedManager.instance.inserted_at_key(config.list_id)
  cutoff   = Time.now.to_i - (config.time_based_removal_minutes * 60)

  expired = []
  orphans = []

  # Scan the hash in cursor batches instead of loading all at once
  cursor = '0'
  loop do
    cursor, pairs = redis.hscan(hash_key, cursor, count: 200)
    pairs.each do |id_str, ts_str|
      if redis.zscore(feed_key, id_str)
        expired << id_str.to_i if ts_str.to_i <= cutoff
      else
        orphans << id_str
      end
    end
    break if cursor == '0'
  end

  config_obj = CustomFeedConfig.find(config_id)
  CustomFeeds::FeedManager.instance.remove_and_stream(config_obj, expired) if expired.any?
  redis.hdel(hash_key, *orphans) if orphans.any?

  Rails.logger.debug do
    "TimeBasedRemovalWorker: config=#{config_obj.id} " \
    "expired=#{expired.size} orphans=#{orphans.size}"
  end
end
```

This is O(N) in the number of **hash entries** (bounded by feed size), but
avoids creating a Ruby Set of all members. The `ZSCORE` calls are fast O(log N)
Redis operations.

**Files affected:** `time_based_removal_worker.rb`

---

## 13. AffinityScore — Single Signal Query _(SIM)_

### Problem

`AffinityScore#score_batch` issues three separate `SELECT` queries (one per
signal type) before scoring a batch.

### Fix

Load all signals for the account in one query and partition in Ruby:

```ruby
def score_batch(candidates)
  signals = RecommendationSignal
    .where(account: @account)
    .pluck(:signal_type, :entity_id, :weight)

  @tag_affinities     = {}
  @account_affinities = {}
  @domain_affinities  = {}

  signals.each do |type, entity, weight|
    case type
    when 'tag'     then @tag_affinities[entity]     = weight
    when 'account' then @account_affinities[entity] = weight
    when 'domain'  then @domain_affinities[entity]  = weight
    end
  end

  Rails.logger.debug do
    "AffinityScore: loaded #{signals.size} signals for account #{@account.id} " \
    "(tags=#{@tag_affinities.size} accounts=#{@account_affinities.size} " \
    "domains=#{@domain_affinities.size})"
  end

  super
end
```

**Files affected:** `recommendations/algorithms/affinity_score.rb`

---

## 14. FriendsLiked Filter — Cache Following IDs _(SIM)_

### Problem

`FriendsLiked#exclude?` calls `account.following.pluck(:id)` on every status
evaluation. In a pipeline evaluating 50 candidates this is 50 identical queries.

### Fix

The filter is instantiated once per pipeline build (in `Pipeline#build_entries`).
Cache the following IDs on the filter instance:

```ruby
# app/lib/custom_feeds/filters/friends_liked.rb
def exclude?(status, account, options = {})
  @following_ids_cache ||= {}
  following_ids = @following_ids_cache[account.id] ||=
    account.following.pluck(:id).to_set

  liked_by_ids = Favourite.where(status: status).pluck(:account_id)
  (liked_by_ids & following_ids.to_a).empty?
end
```

The cache is naturally scoped to the lifetime of the `Pipeline` object (which
is created per-worker-job), so it won't go stale.

**Files affected:** `filters/friends_liked.rb`

---

## 15. Test Coverage Gaps _(TEST)_

The following areas have no specs or only superficial coverage. Listed
roughly by risk and business value:

| Area                                          | Recommended spec                                                                             | File                                                             |
| --------------------------------------------- | -------------------------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| `Pipeline#include?` with all filter types     | Unit: verify each filter type blocks/passes correctly; verify multiple sources               | `spec/lib/custom_feeds/pipeline_spec.rb`                         |
| `Pipeline#passes_filters?` (algorithmic gate) | Unit: same filter combinations as above but via the filters-only path                        | same                                                             |
| `AlgorithmicFeedWorker` filter cascade        | Unit: stub candidates; verify min_signals gate, min_score, top_k each drop expected statuses | `spec/workers/recommendations/algorithmic_feed_worker_spec.rb`   |
| `AffinityScore#score_one`                     | Unit: verify time decay, tag cap, domain skip for local accounts, zero score for no signals  | `spec/lib/recommendations/algorithms/affinity_score_spec.rb`     |
| `SignalWorker` domain skip                    | Unit: verify domain signal is not recorded for local (blank domain) accounts                 | `spec/workers/recommendations/signal_worker_spec.rb`             |
| `FeedManager#push` overflow                   | Unit: verify `at_capacity?` path returns false; verify `trim` is called                      | `spec/lib/custom_feeds/feed_manager_spec.rb`                     |
| `FeedManager#enqueue_candidate` dedup         | Unit: verify same status is not re-queued; verify eviction when at MAX_ITEMS                 | same                                                             |
| `FeedManager#dequeue_pending` age expiry      | Unit: verify entries older than max_age_hours are dropped                                    | same                                                             |
| `TimeBasedRemovalWorker` orphan cleanup       | Unit: insert hash entries for statuses not in the sorted set; verify hdel is called          | `spec/workers/custom_feeds/time_based_removal_worker_spec.rb`    |
| `RemoteTagTimeline` fetch error handling      | Unit: mock HTTP 500; mock timeout; verify FetchResult.new(nil, []) returned                  | `spec/lib/custom_feeds/sources/remote_tag_timeline_spec.rb`      |
| `Sources::Base#resolve_uris` partial failure  | Unit: first URI resolves, second raises; verify first is returned and second is nil          | `spec/lib/custom_feeds/sources/base_spec.rb`                     |
| `CustomFeedConfig` Redis cleanup on destroy   | Integration: create config, push a status, destroy config; verify keys are gone              | `spec/models/custom_feed_config_spec.rb`                         |
| `CustomFeedStep` options validation           | Unit: invalid options for each step type should fail validation                              | `spec/models/custom_feed_step_spec.rb`                           |
| `RecommendationSignalsController` scoping     | Request: verify account A cannot update/delete account B's signals                           | `spec/requests/api/v1/recommendation_signals_controller_spec.rb` |

---

## 16. Pull Source Logging _(LOG)_

### Problem

`PullSourceIngestWorker` is the most complex worker but has no log output.
Cursor advancement, deduplication, and filter results are all invisible.

### Fix

```ruby
def perform(config_id)
  # ...
  Rails.logger.info { "PullSourceIngestWorker: config=#{config_id} starting" }

  # after cursor advancement:
  Rails.logger.debug do
    "PullSourceIngestWorker: config=#{config_id} bucket=#{bucket.inspect} " \
    "fetched=#{result.statuses.size} max_remote_id=#{result.max_remote_id.inspect}"
  end

  # after dedup:
  dupes = all_candidates.size - deduped.size
  Rails.logger.debug do
    "PullSourceIngestWorker: config=#{config_id} total=#{all_candidates.size} " \
    "after_dedup=#{deduped.size} (#{dupes} dupes removed)"
  end

  # after per-status processing:
  promoted  = deduped.count { |s| inserted.include?(s.id) }
  filtered  = deduped.size - promoted
  Rails.logger.info do
    "PullSourceIngestWorker: config=#{config_id} " \
    "promoted=#{promoted} filtered=#{filtered}"
  end
end
```

**Files affected:** `pull_source_ingest_worker.rb`

---

## Summary Table

| #   | Title                                   | Goals       | Effort | Risk   |
| --- | --------------------------------------- | ----------- | ------ | ------ |
| 1   | Shared `Registerable` concern           | DUP ISO     | Low    | Low    |
| 2   | `original_status` helper                | DUP SIM     | Low    | Low    |
| 3   | `RemoteTimelineSource` base class       | DUP ERR LOG | Medium | Low    |
| 4   | FeedManager logging + Redis cleanup     | LOG ERR     | Low    | Low    |
| 5   | Pipeline logging                        | LOG         | Low    | Low    |
| 6   | Worker error handling                   | ERR LOG     | Low    | Low    |
| 7   | Pluggable algorithmic filters           | SIM DUP ISO | Medium | Medium |
| 8   | Algorithm logging + score observability | LOG         | Low    | Low    |
| 9   | StepOptions validation                  | ERR         | Medium | Low    |
| 10  | Status deletion cleanup                 | ERR         | Low    | Medium |
| 11  | Mastodon Adapter layer                  | ISO         | High   | Medium |
| 12  | TimeBasedRemovalWorker optimise         | SIM ERR     | Low    | Low    |
| 13  | AffinityScore single query              | SIM         | Low    | Low    |
| 14  | FriendsLiked cache                      | SIM         | Low    | Low    |
| 15  | Test coverage gaps                      | TEST        | High   | Low    |
| 16  | PullSourceIngestWorker logging          | LOG         | Low    | Low    |

**Recommended order for a first pass:**
Items 2, 4, 5, 6, 8, 16 (all low-effort, low-risk improvements in error
handling and logging) → Items 12, 13, 14 (quick wins in logic) → Items 1, 3
(structural deduplication) → Item 9 (validation) → Item 10 (status cleanup) →
Items 7, 11, 15 (larger structural work and test coverage).
