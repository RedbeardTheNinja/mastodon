# Multi-Provider Lifecycle & Pull Sources — Implementation Plan

This document is the ordered implementation plan for two related changes:

1. **Multiple providers per lifecycle phase** — a feed config can have more than one step in each phase (e.g. `followed_posts` + `remote_tag_timeline` as sources). Each provider (step_type) remains a singleton within its phase.
2. **Pull sources** — two new source types (`remote_public_timeline`, `remote_tag_timeline`) that fetch candidates from external Mastodon APIs on a schedule rather than reacting to home-feed delivery.

The immediate concrete deliverable that drives both requirements is a rake seed task that creates a "NSFW" list with a single `remote_tag_timeline` source step whose options cover both `mastodon.social` and `mastodon.art` via a `sources` array.

---

## Current State

| Concept          | Current behaviour                                                                         | Gap                                   |
| ---------------- | ----------------------------------------------------------------------------------------- | ------------------------------------- |
| Steps per phase  | Any number of `CustomFeedStep` rows allowed per phase per config                          | No uniqueness enforcement             |
| Pipeline options | `build_steps` instantiates plugins without options; `includes?` is called with no options | Options stored in DB but never passed |
| Source types     | Only `followed_posts` (push-triggered via `FeedInsertWorker`)                             | No pull sources                       |
| UI               | One `SelectField` per phase; one step per phase                                           | Cannot add/remove multiple providers  |
| Pull worker      | None                                                                                      | Nothing fetches remote timelines      |

---

## Phase 1 — Database

### 1a. Unique index: singleton-per-type constraint

```ruby
# db/migrate/TIMESTAMP_add_unique_step_type_per_phase.rb
add_index :custom_feed_steps,
          [:custom_feed_config_id, :phase, :step_type],
          unique: true,
          name: 'index_custom_feed_steps_unique_type_per_phase'
```

This enforces the singleton rule at the database level. The API and UI enforce it first, but the index is the safety net.

### 1b. Pull scheduling columns on `custom_feed_configs`

```ruby
# db/migrate/TIMESTAMP_add_pull_scheduling_to_custom_feed_configs.rb
add_column :custom_feed_configs, :pull_cadence_minutes, :integer, null: false, default: 15
add_column :custom_feed_configs, :last_pulled_at, :datetime
add_index  :custom_feed_configs, :last_pulled_at
```

`pull_cadence_minutes` — how often (in minutes) the ingest worker should run for this config. Default 15. User-configurable in the feed settings form.

`last_pulled_at` — timestamp updated by `PullSourceIngestWorker` at the end of each successful run. `SchedulePullSourcesWorker` uses this to decide whether to enqueue a run without needing to know which step_types are pull sources at class load time.

### 1c. Pull cursors table

```ruby
# db/migrate/TIMESTAMP_create_custom_feed_pull_cursors.rb
create_table :custom_feed_pull_cursors do |t|
  t.references :custom_feed_step, null: false, foreign_key: true
  t.string  :bucket,           null: false, default: ''
  # bucket = '' for single-source steps; domain or "domain:tag" for multi-source steps
  t.string  :last_fetched_id   # Mastodon snowflake ID used as since_id on next run
  t.datetime :last_fetched_at
  t.timestamps
  t.index [:custom_feed_step_id, :bucket], unique: true, name: 'index_pull_cursors_step_bucket'
end
```

**Why `bucket`?** `remote_tag_timeline` is a singleton step but its `sources` array covers multiple `{domain, tag}` pairs. Each pair needs its own cursor so incremental fetching works per source. The bucket value is `"#{domain}:#{tag}"` for tag timelines and `domain` for public timelines.

Model:

```ruby
# app/models/custom_feed_pull_cursor.rb
class CustomFeedPullCursor < ApplicationRecord
  belongs_to :custom_feed_step

  # Find or create the cursor for a given step + bucket.
  def self.for_step_bucket(step, bucket = '')
    find_or_create_by!(custom_feed_step: step, bucket: bucket)
  end
end
```

---

## Phase 2 — Backend: Sources::Base Extension

```ruby
# app/lib/custom_feeds/sources/base.rb  (replace existing)
module CustomFeeds
  module Sources
    class Base
      REGISTRY = {}

      def self.key; raise NotImplementedError; end
      def self.register!; REGISTRY[key] = self; end

      # Override to true for sources that run on a schedule (not home-feed delivery).
      def self.pull_source?; false; end

      # Push source interface — called by Pipeline#include? via FeedInsertWorker.
      # @param [Status]  status
      # @param [Account] account
      # @param [Hash]    options  step.options
      # @return [Boolean]
      def includes?(status, account, options = {})
        raise NotImplementedError
      end

      # Pull source interface — called by PullSourceIngestWorker per source step.
      # Returns an array of resolved Status records.
      # @param [Account] account
      # @param [Hash]    options   step.options
      # @param [String]  since_id  cursor from previous run (may be nil)
      # @param [String]  bucket    identifies which sub-source this call is for
      # @return [Array<Status>]
      def fetch_candidates(account, options = {}, since_id: nil, bucket: '')
        raise NotImplementedError
      end
    end
  end
end
```

---

## Phase 3 — Backend: Pipeline Fix (pass options)

The existing `Pipeline` never passes `step.options` to plugin instances. Fix by storing `(instance, options)` pairs:

```ruby
# app/lib/custom_feeds/pipeline.rb  (replace existing)
module CustomFeeds
  class Pipeline
    def initialize(config)
      @sources  = build_steps(config, 'source',           Sources::Base::REGISTRY)
      @filters  = build_steps(config, 'filter',           Filters::Base::REGISTRY)
      @removals = build_steps(config, 'removal_strategy', RemovalStrategies::Base::REGISTRY)

      overflow_step  = config.steps_for('overflow_strategy').first
      overflow_klass = overflow_step ? OverflowStrategies::Base::REGISTRY[overflow_step.step_type] : nil
      @overflow = (overflow_klass || OverflowStrategies::OldestFirst).new
    end

    # Returns true if the status should be inserted via the push path.
    # Only evaluates push sources (pull sources are skipped here).
    def include?(status, account)
      push_sources = @sources.reject { |_, klass, _| klass.pull_source? }
      return false if push_sources.empty?

      push_sources.any? { |instance, _, options| instance.includes?(status, account, options) } &&
        @filters.none? { |instance, _, options| instance.exclude?(status, account, options) }
    end

    # Called by PullSourceIngestWorker for candidates already fetched by a pull source.
    # Skips the source check — the pull source itself is the gate.
    def passes_filters?(status, account)
      @filters.none? { |instance, _, options| instance.exclude?(status, account, options) }
    end

    def remove_on?(interaction_type)
      @removals.any? { |instance, _, options| instance.remove_on?(interaction_type, options) }
    end

    # Returns true if this pipeline has any pull source steps.
    def has_pull_sources?
      @sources.any? { |_, klass, _| klass.pull_source? }
    end

    # Returns the pull source steps as [{instance:, klass:, options:, step:}] for the ingest worker.
    attr_reader :pull_source_steps

    attr_reader :overflow

    private

    def build_steps(config, phase, registry)
      steps = config.steps_for(phase).filter_map do |step|
        klass = registry[step.step_type]
        next unless klass
        [klass.new, klass, step.options.with_indifferent_access, step]
      end
      # Store pull source steps separately for ingest worker access
      if phase == 'source'
        @pull_source_steps = steps.select { |_, klass, _| klass.pull_source? }
                                  .map { |instance, klass, options, step| { instance: instance, klass: klass, options: options, step: step } }
      end
      steps
    end
  end
end
```

**Also fix `Filters::Base`** to match the signature: `def exclude?(status, account, options = {})`. Check existing `InteractedPosts` and add the `options` parameter if missing.

---

## Phase 4 — New Pull Source Implementations

### `remote_tag_timeline`

```ruby
# app/lib/custom_feeds/sources/remote_tag_timeline.rb
module CustomFeeds
  module Sources
    class RemoteTagTimeline < Base
      def self.key; 'remote_tag_timeline'; end
      def self.pull_source?; true; end

      # options keys:
      #   sources (array, required) — [{domain:, tag:}, ...]
      #   limit_per_run (int, default 40, max 80)
      #
      # bucket format: "#{domain}:#{tag}"
      # fetch_candidates is called once per sources entry (per bucket).

      def fetch_candidates(account, options = {}, since_id: nil, bucket: '')
        sources = Array(options['sources'])
        entry = sources.find { |s| "#{s['domain']}:#{s['tag']}" == bucket } || sources.first
        return [] unless entry

        domain = entry['domain'].to_s.strip
        tag    = entry['tag'].to_s.delete_prefix('#').strip
        limit  = [[options.fetch('limit_per_run', 40).to_i, 80].min, 1].max

        url = "https://#{domain}/api/v1/timelines/tag/#{CGI.escape(tag)}"
        params = { limit: limit }
        params[:since_id] = since_id if since_id.present?

        response = HTTP.timeout(10).get(url, params: params)
        return [] unless response.status.success?

        uris = JSON.parse(response.body).filter_map { |s| s['uri'] }
        resolve_uris(uris)
      rescue => e
        Rails.logger.warn("CustomFeeds::Sources::RemoteTagTimeline fetch failed (#{bucket}): #{e.message}")
        []
      end

      # Returns all bucket strings for this step's options.
      # Used by PullSourceIngestWorker to enumerate cursors.
      def self.buckets_for(options)
        Array(options['sources']).map { |s| "#{s['domain']}:#{s['tag'].to_s.delete_prefix('#')}" }
      end

      private

      def resolve_uris(uris)
        uris.filter_map { |uri| ResolveStatusService.new.call(uri) rescue nil }
      end
    end
  end
end
```

### `remote_public_timeline`

```ruby
# app/lib/custom_feeds/sources/remote_public_timeline.rb
module CustomFeeds
  module Sources
    class RemotePublicTimeline < Base
      def self.key; 'remote_public_timeline'; end
      def self.pull_source?; true; end

      # options keys:
      #   sources (array, required) — [{domain:, local_only:}]
      #   limit_per_run (int, default 40)
      #
      # bucket = domain

      def fetch_candidates(account, options = {}, since_id: nil, bucket: '')
        sources = Array(options['sources'])
        entry = sources.find { |s| s['domain'] == bucket } || sources.first
        return [] unless entry

        domain    = entry['domain'].to_s.strip
        local     = entry.fetch('local_only', true)
        limit     = [[options.fetch('limit_per_run', 40).to_i, 80].min, 1].max

        url = "https://#{domain}/api/v1/timelines/public"
        params = { limit: limit, local: local }
        params[:since_id] = since_id if since_id.present?

        response = HTTP.timeout(10).get(url, params: params)
        return [] unless response.status.success?

        uris = JSON.parse(response.body).filter_map { |s| s['uri'] }
        uris.filter_map { |uri| ResolveStatusService.new.call(uri) rescue nil }
      rescue => e
        Rails.logger.warn("CustomFeeds::Sources::RemotePublicTimeline fetch failed (#{bucket}): #{e.message}")
        []
      end

      def self.buckets_for(options)
        Array(options['sources']).map { |s| s['domain'].to_s }
      end
    end
  end
end
```

**Key design:** Both sources use a `sources: [{...}]` array in options, and expose `self.buckets_for(options)` so the ingest worker can enumerate cursors. Single-server configs still use this array with one entry — no special-casing needed.

---

## Phase 5 — New Filter Implementations

### `friends_liked`

```ruby
# app/lib/custom_feeds/filters/friends_liked.rb
module CustomFeeds
  module Filters
    class FriendsLiked < Base
      def self.key; 'friends_liked'; end

      # options keys:
      #   min_interactions (int, default 1)

      def exclude?(status, account, options = {})
        min  = (options['min_interactions'] || 1).to_i
        orig = status.reblog? ? status.reblog : status
        following_ids = account.following.pluck(:id)

        fav_count    = Favourite.where(account_id: following_ids, status_id: orig.id).count
        reblog_count = Status.where(account_id: following_ids, reblog_of_id: orig.id).count
        (fav_count + reblog_count) < min
      end
    end
  end
end
```

### `recommendation_score`

Deferred to a later iteration — requires the `Recommendations::Algorithms::` infrastructure. Stub with `def exclude?(...) = false` if needed for registration.

---

## Phase 6 — Workers

### `SchedulePullSourcesWorker`

Runs every 5 minutes. Uses `pull_cadence_minutes` and `last_pulled_at` on each config to decide whether to enqueue a run — no static list of pull source keys needed.

```ruby
# app/workers/custom_feeds/schedule_pull_sources_worker.rb
module CustomFeeds
  class SchedulePullSourcesWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'scheduler', retry: 0

    def perform
      configs = CustomFeedConfig
        .enabled
        .where(
          "last_pulled_at IS NULL OR " \
          "last_pulled_at + (pull_cadence_minutes * interval '1 minute') <= NOW()"
        )
        .distinct

      configs.each_with_index do |config, i|
        PullSourceIngestWorker.perform_in(i * 2.seconds, config.id)
      end
    end
  end
end
```

`PullSourceIngestWorker` returns early if the config has no pull source steps (via `pipeline.has_pull_sources?`), so configs that only use push sources are harmlessly no-ops — no need to pre-filter by step_type in the scheduler.

### `PullSourceIngestWorker`

```ruby
# app/workers/custom_feeds/pull_source_ingest_worker.rb
module CustomFeeds
  class PullSourceIngestWorker
    include Sidekiq::Worker
    sidekiq_options queue: 'default', retry: 3

    def perform(config_id)
      config = CustomFeedConfig.find_by(id: config_id)
      return unless config&.enabled?

      account = config.account
      return unless account.user&.recently_active?

      pipeline = Pipeline.new(config)
      return unless pipeline.has_pull_sources?

      all_candidates = []

      pipeline.pull_source_steps.each do |ps|
        source  = ps[:instance]
        klass   = ps[:klass]
        options = ps[:options]
        step    = ps[:step]

        buckets = klass.buckets_for(options)
        buckets = [''] if buckets.empty?  # fallback for simple single-source

        buckets.each do |bucket|
          cursor = CustomFeedPullCursor.for_step_bucket(step, bucket)

          candidates = source.fetch_candidates(account, options, since_id: cursor.last_fetched_id, bucket: bucket)
          next if candidates.empty?

          max_id = candidates.map(&:id).max.to_s
          cursor.update!(last_fetched_id: max_id, last_fetched_at: Time.current)

          all_candidates.concat(candidates)
        end
      end

      seen = Set.new
      deduped = all_candidates.select { |s| seen.add?(s.id) }

      deduped.each do |status|
        next if ::FeedManager.instance.filter?(:home, status, account)
        next unless pipeline.passes_filters?(status, account)

        CustomFeeds::FeedManager.instance.push_and_stream(config, status)
      end

      config.update_column(:last_pulled_at, Time.current)
    end
  end
end
```

`last_pulled_at` is updated only after all steps complete. If the worker fails and retries, it will re-fetch (cursors are updated per step, so no duplicates — statuses already in the feed are ignored by `push_and_stream`).

---

## Phase 7 — Initializer & Cron

### `config/initializers/custom_feeds.rb` (additions)

```ruby
# New pull sources
CustomFeeds::Sources::RemotePublicTimeline.register!
CustomFeeds::Sources::RemoteTagTimeline.register!

# New filters
CustomFeeds::Filters::FriendsLiked.register!
```

### Sidekiq cron entry

Add to `config/initializers/sidekiq.rb` or `config/schedule.yml`:

```yaml
custom_feeds_pull_sources:
  cron: '*/5 * * * *'
  class: 'CustomFeeds::SchedulePullSourcesWorker'
  queue: scheduler
```

The cron runs every 5 minutes; the per-config cadence is controlled by `pull_cadence_minutes` (default 15). A config with `pull_cadence_minutes: 5` gets a run on every tick; one with `pull_cadence_minutes: 60` gets one roughly every hour. The minimum effective cadence is 5 minutes (one cron tick).

---

## Phase 8 — Rake Seed Task

```ruby
# lib/tasks/custom_feeds_seed.rake
namespace :custom_feeds do
  desc 'Seed NSFW custom feed for the admin account'
  task seed_nsfw: :environment do
    admin = Account.find_by(username: 'admin') || Account.first
    abort 'No account found' unless admin

    list = admin.owned_lists.find_or_create_by!(title: 'NSFW')

    config = CustomFeedConfig.find_or_create_by!(account: admin, list: list) do |c|
      c.enabled = true
      c.pull_cadence_minutes = 30
    end

    # remote_tag_timeline singleton covering mastodon.social and mastodon.art
    CustomFeedStep.find_or_create_by!(
      custom_feed_config: config,
      phase: 'source',
      step_type: 'remote_tag_timeline'
    ) do |s|
      s.position = 0
      s.options = {
        sources: [
          { domain: 'mastodon.social', tag: 'nsfw' },
          { domain: 'mastodon.art',    tag: 'nsfw' },
        ],
        limit_per_run: 40,
      }
    end

    # Remove posts once you interact with them
    CustomFeedStep.find_or_create_by!(
      custom_feed_config: config,
      phase: 'removal_strategy',
      step_type: 'on_interaction'
    ) do |s|
      s.position = 0
      s.options = {}
    end

    # Overflow: oldest first
    CustomFeedStep.find_or_create_by!(
      custom_feed_config: config,
      phase: 'overflow_strategy',
      step_type: 'oldest_first'
    ) do |s|
      s.position = 0
      s.options = {}
    end

    puts "NSFW feed seeded: list ##{list.id} '#{list.title}', config ##{config.id}"
  end
end
```

Run with: `bin/rails custom_feeds:seed_nsfw`

---

## Phase 9 — Frontend: Multi-Provider UI

### Data model change

The form state moves from one `string` per phase to one `array of step objects` per phase:

```ts
interface StepDraft {
  step_type: string;
  options: Record<string, unknown>;
}

// Per-phase state
const [sourceDrafts, setSourceDrafts] = useState<StepDraft[]>(() =>
  stepsFor(config, 'source'),
);
const [filterDrafts, setFilterDrafts] = useState<StepDraft[]>(() =>
  stepsFor(config, 'filter'),
);
const [removalDrafts, setRemovalDrafts] = useState<StepDraft[]>(() =>
  stepsFor(config, 'removal_strategy'),
);
const [overflowDrafts, setOverflowDrafts] = useState<StepDraft[]>(() =>
  stepsFor(config, 'overflow_strategy'),
);
```

`buildSteps()` maps each phase's drafts to `ApiCustomFeedStepInputJSON[]` with ascending `position`.

### Phase section component

Each phase renders a `<PhaseSection>` that:

1. Lists active steps as removable cards (step_type label + options summary + remove button)
2. Shows an "Add [Phase]" dropdown — a `SelectField` or `<select>` — populated with **only step_types not yet in the draft list** for that phase
3. When a step_type is selected from "Add", appends a new draft with default options and opens an inline options form
4. The "Add" control is hidden when all available types for the phase are already added

```tsx
interface PhaseSectionProps {
  phase: CustomFeedPhase;
  label: string;
  drafts: StepDraft[];
  availableOptions: { value: string; label: MessageDescriptor }[];
  onAdd: (stepType: string) => void;
  onRemove: (stepType: string) => void;
  onOptionsChange: (stepType: string, options: Record<string, unknown>) => void;
}
```

### Pull cadence field

The config-level form gains a `pull_cadence_minutes` `SelectField` (only shown when the config has at least one pull source step). Suggested options: 5, 15, 30, 60, 120, 360 minutes. Stored on `ApiCustomFeedConfigInputJSON.pull_cadence_minutes`.

```ts
const [pullCadenceMinutes, setPullCadenceMinutes] = useState(
  config?.pull_cadence_minutes ?? 15,
);
```

Sent as part of the update payload whenever the form is saved. The API serializer already returns `pull_cadence_minutes` from the config record.

### Options sub-forms

Each options-bearing step_type gets a sub-form component rendered beneath the step card in edit state.

**`RemoteTagTimelineOptions`**

- Sources list: repeating rows of `[domain input] [tag input] [remove row button]`
- "Add server" button appends a blank row
- `limit_per_run` number input (default 40)
- Serialised into `{ sources: [{domain, tag}, ...], limit_per_run }`

**`RemotePublicTimelineOptions`**

- Sources list: repeating rows of `[domain input] [local_only toggle] [remove row button]`
- "Add server" button
- `limit_per_run` number input
- Serialised into `{ sources: [{domain, local_only}, ...], limit_per_run }`

**`FriendsLikedOptions`**

- `min_interactions` number input (default 1)

### i18n additions (`app/javascript/mastodon/locales/en.json`)

```json
"custom_feeds.sources.remote_public_timeline": "Remote server — public timeline",
"custom_feeds.sources.remote_tag_timeline": "Remote server — tag timeline",
"custom_feeds.filters.friends_liked": "Only posts liked by people you follow",
"custom_feeds.phase.source.add": "Add source",
"custom_feeds.phase.filter.add": "Add filter",
"custom_feeds.phase.removal_strategy.add": "Add removal rule",
"custom_feeds.phase.overflow_strategy.add": "Set overflow rule",
"custom_feeds.step_options.domain": "Server domain",
"custom_feeds.step_options.tag": "Hashtag (without #)",
"custom_feeds.step_options.local_only": "Local posts only",
"custom_feeds.step_options.limit_per_run": "Posts fetched per run",
"custom_feeds.step_options.min_interactions": "Minimum interactions from follows",
"custom_feeds.step_options.add_server": "Add server",
"custom_feeds.form.pull_cadence": "Refresh interval",
"custom_feeds.form.pull_cadence_hint": "How often to fetch new posts from remote sources.",
"custom_feeds.cadence.5": "Every 5 minutes",
"custom_feeds.cadence.15": "Every 15 minutes",
"custom_feeds.cadence.30": "Every 30 minutes",
"custom_feeds.cadence.60": "Every hour",
"custom_feeds.cadence.120": "Every 2 hours",
"custom_feeds.cadence.360": "Every 6 hours"
```

---

## Phase 10 — API: multi-step update and cadence

The existing `PUT /api/v1/custom_feeds/:id` already accepts a `steps` array and replaces all steps atomically. The only change needed is to permit and persist `pull_cadence_minutes` from the request body.

`ApiCustomFeedConfigInputJSON` gains `pull_cadence_minutes?: number`. The controller permits it and the serializer returns it. `buildSteps()` is unchanged; the cadence is sent as a top-level field alongside `steps`.

The server-side replace-all behaviour means multi-step configs are sent and stored correctly without any special merge logic.

---

## Execution Order

| Step | What                                                                             | Dependencies |
| ---- | -------------------------------------------------------------------------------- | ------------ |
| 1    | Run unique index migration                                                       | —            |
| 2    | Run pull scheduling columns migration (`pull_cadence_minutes`, `last_pulled_at`) | —            |
| 3    | Run pull cursors migration                                                       | —            |
| 4    | Update `Sources::Base` + `Pipeline`                                              | —            |
| 5    | Implement `RemoteTagTimeline` + `RemotePublicTimeline`                           | Step 4       |
| 6    | Implement `FriendsLiked` filter                                                  | —            |
| 7    | Register new types in initializer                                                | Steps 5–6    |
| 8    | Implement `SchedulePullSourcesWorker` + `PullSourceIngestWorker`                 | Steps 4–5, 7 |
| 9    | Add cron entry (\*/5)                                                            | Step 8       |
| 10   | Write and verify rake seed task                                                  | Steps 5, 7   |
| 11   | Frontend: multi-provider phase sections + cadence selector                       | —            |
| 12   | Frontend: options sub-forms per step type                                        | Step 11      |
| 13   | API: permit `pull_cadence_minutes` in controller + serializer                    | —            |
| 14   | Run seed task on dev; verify two cursors created for NSFW config                 | Steps 8, 10  |

---

## Files to Create / Modify

### New

| File                                                                                                                | Purpose                                           |
| ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------- |
| `db/migrate/TIMESTAMP_add_unique_step_type_per_phase.rb`                                                            | Singleton uniqueness index                        |
| `db/migrate/TIMESTAMP_add_pull_scheduling_to_custom_feed_configs.rb`                                                | `pull_cadence_minutes` + `last_pulled_at` columns |
| `db/migrate/TIMESTAMP_create_custom_feed_pull_cursors.rb`                                                           | Cursor table                                      |
| `app/models/custom_feed_pull_cursor.rb`                                                                             | Cursor model                                      |
| `app/lib/custom_feeds/sources/remote_tag_timeline.rb`                                                               | Pull source                                       |
| `app/lib/custom_feeds/sources/remote_public_timeline.rb`                                                            | Pull source                                       |
| `app/lib/custom_feeds/filters/friends_liked.rb`                                                                     | Filter                                            |
| `app/workers/custom_feeds/schedule_pull_sources_worker.rb`                                                          | Scheduler                                         |
| `app/workers/custom_feeds/pull_source_ingest_worker.rb`                                                             | Ingest worker                                     |
| `lib/tasks/custom_feeds_seed.rake`                                                                                  | NSFW seed                                         |
| `app/javascript/mastodon/features/custom_feeds_settings/components/phase_section.tsx`                               | Per-phase UI section                              |
| `app/javascript/mastodon/features/custom_feeds_settings/components/step_options/remote_tag_timeline_options.tsx`    | Options form                                      |
| `app/javascript/mastodon/features/custom_feeds_settings/components/step_options/remote_public_timeline_options.tsx` | Options form                                      |
| `app/javascript/mastodon/features/custom_feeds_settings/components/step_options/friends_liked_options.tsx`          | Options form                                      |

### Modified

| File                                                                                     | Change                                                                                   |
| ---------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------- |
| `app/lib/custom_feeds/sources/base.rb`                                                   | Add `pull_source?`, `fetch_candidates` interface                                         |
| `app/lib/custom_feeds/pipeline.rb`                                                       | Pass options to plugins; add `passes_filters?`, `has_pull_sources?`, `pull_source_steps` |
| `app/lib/custom_feeds/filters/base.rb`                                                   | Add `options` param to `exclude?` signature                                              |
| `app/lib/custom_feeds/filters/interacted_posts.rb`                                       | Add `options = {}` param to `exclude?`                                                   |
| `app/models/custom_feed_config.rb`                                                       | Add `pull_cadence_minutes` / `last_pulled_at` to schema comment                          |
| `config/initializers/custom_feeds.rb`                                                    | Register new sources and filter (no pull-source key enumeration needed)                  |
| `config/initializers/sidekiq.rb` (or `schedule.yml`)                                     | Add `*/5` cron for `SchedulePullSourcesWorker`                                           |
| `app/controllers/api/v1/custom_feeds_controller.rb`                                      | Permit `pull_cadence_minutes` in strong params                                           |
| `app/serializers/rest/custom_feed_config_serializer.rb`                                  | Include `pull_cadence_minutes` in serialized attributes                                  |
| `app/javascript/mastodon/api_types/custom_feeds.ts`                                      | Add `pull_cadence_minutes` to config types                                               |
| `app/javascript/mastodon/features/custom_feeds_settings/components/custom_feed_form.tsx` | Per-phase draft arrays; `PhaseSection`; cadence selector                                 |
| `app/javascript/mastodon/locales/en.json`                                                | Add new i18n keys                                                                        |
