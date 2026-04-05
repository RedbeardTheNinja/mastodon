# Custom Feeds System

An extensible system that lets users configure any of their Mastodon Lists as a **custom feed** with a pluggable pipeline of four lifecycle phases:

1. **Sources** — where posts originate (initially: `followed_posts`, taps the home-feed delivery path)
2. **Filters** — which posts to exclude before insertion (initially: `interacted_posts`)
3. **Removal Strategies** — when to remove posts already in the feed (initially: `on_interaction`)
4. **Overflow Strategies** — what to do when the feed exceeds its capacity (default: `oldest_first`, mirrors current Mastodon behavior)

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
                 └─ FeedManager#push_and_stream(config, status)

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

### Migration 1: `custom_feed_configs`

One record per custom feed. The unique index on `list_id` enforces one custom feed per list.

```ruby
create_table :custom_feed_configs do |t|
  t.references :account, null: false, foreign_key: true
  t.references :list,    null: false, foreign_key: true, index: { unique: true }
  t.boolean    :enabled, null: false, default: true
  t.timestamps
end
```

### Migration 2: `custom_feed_steps`

Each step in the pipeline. A single table covers all four phases; `phase` disambiguates them. `options` holds step-specific config without requiring additional migrations.

```ruby
create_table :custom_feed_steps do |t|
  t.references :custom_feed_config, null: false, foreign_key: true
  t.string  :phase,     null: false   # 'source' | 'filter' | 'removal_strategy' | 'overflow_strategy'
  t.string  :step_type, null: false   # 'followed_posts' | 'interacted_posts' | 'on_interaction' | 'oldest_first'
  t.jsonb   :options,   null: false, default: {}
  t.integer :position,  null: false, default: 0
  t.timestamps
  t.index [:custom_feed_config_id, :phase, :position]
end
```

### Migration 3: NTM data migration

For every `List` with title `"New To Me"`, create a `CustomFeedConfig` with the four NTM steps (including `oldest_first` overflow strategy). This is a reversible data migration — no schema changes.

---

## Plugin Architecture

All step types live under `app/lib/custom_feeds/`.

### Source Interface

```ruby
# app/lib/custom_feeds/sources/base.rb
module CustomFeeds
  module Sources
    class Base
      REGISTRY = {}
      def self.key; raise NotImplementedError; end
      def self.register!; REGISTRY[key] = self; end

      # Return true if this source provides the given status for the account.
      def includes?(status, account, options = {}); raise NotImplementedError; end
    end
  end
end
```

`CustomFeeds::Sources::FollowedPosts#includes?` returns `!::FeedManager.instance.filter(:home, status, account)` — i.e., it includes any post that would have passed the home feed filter.

### Filter Interface

```ruby
# app/lib/custom_feeds/filters/base.rb
module CustomFeeds
  module Filters
    class Base
      REGISTRY = {}
      def self.key; raise NotImplementedError; end
      def self.register!; REGISTRY[key] = self; end

      # Return true to EXCLUDE this status from the feed.
      def exclude?(status, account, options = {}); raise NotImplementedError; end
    end
  end
end
```

`CustomFeeds::Filters::InteractedPosts#exclude?` — port of `NewToMe::FeedManager#interacted?`. Resolves reblogs to original, then checks for existing favourites, reblogs, and replies.

### Removal Strategy Interface

```ruby
# app/lib/custom_feeds/removal_strategies/base.rb
module CustomFeeds
  module RemovalStrategies
    class Base
      REGISTRY = {}
      def self.key; raise NotImplementedError; end
      def self.register!; REGISTRY[key] = self; end

      # Return true to remove the status after this interaction type.
      # interaction_type: 'favourite' | 'reblog' | 'reply'
      def remove_on?(interaction_type, options = {}); raise NotImplementedError; end
    end
  end
end
```

`CustomFeeds::RemovalStrategies::OnInteraction#remove_on?` returns `true` for all three interaction types.

### Overflow Strategy Interface

```ruby
# app/lib/custom_feeds/overflow_strategies/base.rb
module CustomFeeds
  module OverflowStrategies
    class Base
      REGISTRY = {}
      def self.key; raise NotImplementedError; end
      def self.register!; REGISTRY[key] = self; end

      # Return true to block insertion when the feed is already at capacity.
      # Called BEFORE zadd; if true, the status is not added.
      def at_capacity?(current_count, max_items, options = {})
        false
      end

      # Called AFTER zadd to trim the feed if needed.
      def trim(redis, key, max_items, options = {})
        # no-op by default
      end
    end
  end
end
```

Two-method interface (`at_capacity?` then `trim`) lets strategies either block insertion up-front or evict after insertion without needing to know which element was just added.

#### `CustomFeeds::OverflowStrategies::OldestFirst` (default)

`at_capacity?` always returns `false` (always allow insertion). `trim` calls:

```ruby
redis.zremrangebyrank(key, 0, -(max_items + 1))
```

This removes the lowest-score entries (oldest status IDs), matching current Mastodon home/list feed behavior.

#### `CustomFeeds::OverflowStrategies::NoOverflow`

`at_capacity?` returns `current_count >= max_items`, blocking new insertions once the feed is full. Useful for a stable "snapshot" feed that only changes via explicit removal strategies. `trim` is a no-op.

`FeedManager#push` uses a fallback to `OldestFirst` when no overflow strategy step is configured on a feed, so existing feeds without an explicit step behave correctly.

---

## Core Components

### `app/lib/custom_feeds/feed_manager.rb`

Singleton owning all Redis operations.

- `key(list_id)` → `"feed:custom:#{list_id}"`
- `push(config, status)` — overflow-aware insert:
  1. Resolve overflow strategy from config (falls back to `OldestFirst` if no step configured).
  2. Check `overflow.at_capacity?(redis.zcard(key), MAX_ITEMS)` — return `false` immediately if at capacity.
  3. `zadd` with `status.id` as score and member.
  4. Call `overflow.trim(redis, key, MAX_ITEMS)` to evict if needed.
- `remove(config, status_id)` — `zrem`
- `push_and_stream(config, status)` — push + `redis.publish("timeline:list:#{config.list_id}", Oj.dump(event: :update, ...))`
- `remove_and_stream(config, ids)` — remove each + `redis.publish(..., Oj.dump(event: :delete, ...))`

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

Wraps a `CustomFeedConfig` and evaluates sources/filters/removal strategies for a given status.

```ruby
module CustomFeeds
  class Pipeline
    def initialize(config)
      @sources   = config.steps_for('source').map             { |s| Sources::Base::REGISTRY[s.step_type]&.new }
      @filters   = config.steps_for('filter').map             { |s| Filters::Base::REGISTRY[s.step_type]&.new }
      @removals  = config.steps_for('removal_strategy').map   { |s| RemovalStrategies::Base::REGISTRY[s.step_type]&.new }
      overflow_step = config.steps_for('overflow_strategy').first
      @overflow  = (OverflowStrategies::Base::REGISTRY[overflow_step&.step_type] || OverflowStrategies::OldestFirst).new
    end

    # Returns true if the status should be inserted.
    def include?(status, account)
      @sources.any?  { |s| s&.includes?(status, account) } &&
        @filters.none? { |f| f&.exclude?(status, account) }
    end

    # Returns true if the status should be removed after the given interaction.
    def remove_on?(interaction_type)
      @removals.any? { |r| r&.remove_on?(interaction_type) }
    end

    # The resolved overflow strategy (always non-nil; defaults to OldestFirst).
    attr_reader :overflow
  end
end
```

`CustomFeedConfig#steps_for(phase)` returns steps ordered by position. `FeedManager#push` reads `pipeline.overflow` to call `at_capacity?` and `trim`.

---

## Workers

### `app/workers/custom_feeds/feed_insert_worker.rb`

Queue: `push`, retry: 3. Called once per home-feed delivery and handles **all** custom feeds for the account — no N+1 worker spawning.

```
perform(status_id, account_id)
  with_primary: load status, account
  with_read_replica:
    return unless account.user&.signed_in_recently?
    return if ::FeedManager.instance.filter(:home, status, account)
    for each enabled config with 'followed_posts' source:
      pipeline = Pipeline.new(config)
      next unless pipeline.include?(status, account)
      FeedManager.instance.push_and_stream(config, status)
rescue ActiveRecord::RecordNotFound → true
```

### `app/workers/custom_feeds/feed_remove_worker.rb`

Queue: `default`, retry: 3. Handles **all** custom feeds for the account.

```
perform(status_id, account_id, interaction_type)
  account = Account.find(account_id)
  ids_to_remove = [status_id] + Status.where(reblog_of_id: status_id).pluck(:id)
  for each enabled config:
    pipeline = Pipeline.new(config)
    next unless pipeline.remove_on?(interaction_type)
    FeedManager.instance.remove_and_stream(config, ids_to_remove)
rescue ActiveRecord::RecordNotFound → true
```

---

## Concerns

### `app/lib/custom_feeds/feed_insert_concern.rb`

Prepended into `FeedInsertWorker`. Replaces `NewToMe::FeedInsertConcern`.

```ruby
module CustomFeeds
  module FeedInsertConcern
    def perform_push
      super
      return unless @type == :home
      CustomFeeds::FeedInsertWorker.perform_async(@status.id, @follower.id)
    end
  end
end
```

### `app/lib/custom_feeds/favourite_concern.rb`

Included into `Favourite`. Replaces `NewToMe::FavouriteConcern`.

`after_create_commit` → `CustomFeeds::FeedRemoveWorker.perform_async(status_id, account_id, 'favourite')`

Uses normalised `status_id` (always original, never a reblog ID — the `Favourite` model enforces this).

### `app/lib/custom_feeds/status_concern.rb`

Included into `Status`. Replaces `NewToMe::StatusConcern`.

`after_create_commit`, local accounts only:

- reblog → `perform_async(reblog_of_id, account_id, 'reblog')`
- reply → `perform_async(in_reply_to_id, account_id, 'reply')`

### `app/lib/custom_feeds/list_controller_concern.rb`

Prepended into `Api::V1::Timelines::ListController`. Replaces `NewToMe::ListControllerConcern`.

Checks the database rather than matching on list title — any list with a `CustomFeedConfig` becomes a custom feed.

```ruby
def list_feed
  config = CustomFeedConfig.find_by(list: @list, enabled: true)
  return CustomFeedsFeed.new(@list) if config
  super
end
```

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

Request body for create/update uses `ApiCustomFeedConfigInputJSON` (steps have no server-assigned `id`):

```json
{
  "list_id": 123,
  "enabled": true,
  "steps": [
    { "phase": "source", "step_type": "followed_posts", "position": 0 },
    { "phase": "filter", "step_type": "interacted_posts", "position": 0 },
    {
      "phase": "removal_strategy",
      "step_type": "on_interaction",
      "position": 0
    },
    { "phase": "overflow_strategy", "step_type": "oldest_first", "position": 0 }
  ]
}
```

`filter` and `removal_strategy` steps are optional. Omitting them means no filter / no removal strategy is applied. Steps are replaced wholesale on update (no partial step patching).

Serializer: `app/serializers/rest/custom_feed_config_serializer.rb` — includes list ID + title, enabled flag, and steps array (each step includes its server-assigned `id`).

Authorization: Pundit policy `CustomFeedConfigPolicy` — owner-only access.

---

## Settings Page (Frontend)

React feature at `app/javascript/mastodon/features/custom_feeds_settings/`.

Route: `/custom_feeds` — registered in `config/routes/web_app.rb` (served by `home#index` like other SPA routes). Linked from the navigation panel (left sidebar) with a `TuneIcon`, below Followed Tags.

### Components

| Component                         | Purpose                                                                                                                                                            |
| --------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `index.tsx`                       | Page container: `Column` + `ColumnHeader` (with add button in `extraButton` slot) + `ScrollableList`. Fetches configs and lists on mount.                          |
| `components/custom_feed_card.tsx` | List row showing the list name and a "Disabled" badge if inactive. Edit/delete icon buttons. Edit state expands inline below the row with a full-width form panel. |
| `components/custom_feed_form.tsx` | Create/edit form using `simple_form app-form` CSS pattern with `SelectField` dropdowns for each phase.                                                             |

### Form Layout (`custom_feed_form.tsx`)

Uses `simple_form app-form` with `fields-group` wrappers — the same pattern as the list editor (`lists/new.tsx`).

Each phase is a `SelectField` dropdown:

| Field             | Phase               | Options                                               |
| ----------------- | ------------------- | ----------------------------------------------------- |
| List picker       | —                   | User's lists without an existing config (create only) |
| Post source       | `source`            | Followed accounts (home feed)                         |
| Filter            | `filter`            | None · Hide already-interacted posts                  |
| Removal strategy  | `removal_strategy`  | None · Remove on interaction                          |
| When feed is full | `overflow_strategy` | Remove oldest first · Stop adding when full           |
| Feed enabled      | —                   | `ToggleField` (edit only)                             |

All option labels are registered with `defineMessages` so the React Intl babel plugin can statically extract them for i18n. The options data structure (`PHASE_OPTIONS`) references these descriptors by property access — not by computed string IDs — which satisfies the static evaluation requirement.

`filter` and `removal_strategy` include a "None" option (empty value). Steps with an empty value are omitted from the payload sent to the API. Submit button shows `LoadingIndicator` while in-flight.

### Card List View vs Edit View

**List view** (`custom_feed_card.tsx` normal state):

- Uses `lists__item` CSS class for consistent row styling with the Lists page
- Shows: `TuneIcon` + list name + optional "Disabled" badge + edit icon button + delete icon button
- No step details shown

**Edit view** (inline panel, replaces the row):

- `custom-feed-card--editing` full-width panel with a header row (icon + list name)
- Full `CustomFeedForm` beneath the header with all four phase dropdowns

### Navigation

`app/javascript/mastodon/features/navigation_panel/index.tsx` — a `ColumnLink` to `/custom_feeds` with `TuneIcon` is added below the `FollowedTagsPanel`. i18n key: `navigation_bar.custom_feeds`.

### TypeScript Types

`app/javascript/mastodon/api_types/custom_feeds.ts` exposes two input types in addition to the response types:

- `ApiCustomFeedStepInputJSON` — `Omit<ApiCustomFeedStepJSON, 'id'>` (steps in create/update payloads have no server-assigned id yet)
- `ApiCustomFeedConfigInputJSON` — partial config shape for create/update request bodies

`app/javascript/mastodon/api/custom_feeds.ts` uses these input types for `apiCreateCustomFeed` and `apiUpdateCustomFeed`, eliminating the previous `Omit<..., 'id'>` inline casts.

`deleteCustomFeed` thunk uses the correct two-argument `onData` signature: `(_data, { discardLoadData }) => discardLoadData`.

### Dark Mode

`color-scheme: inherit` is set on `<select>` elements in both:

- `app/javascript/mastodon/components/form_fields/select.module.scss` (used by `SelectField`)
- `app/javascript/styles/mastodon/forms.scss` (`.simple_form select` rule)

This ensures the browser's native dropdown popup (the option list rendered by the OS) follows the `color-scheme: dark` set by `[data-color-scheme='dark']` on the Mastodon theme container, rather than defaulting to the OS light mode.

### Redux

- `app/javascript/mastodon/actions/custom_feeds.ts` — `fetchCustomFeeds`, `createCustomFeed`, `updateCustomFeed`, `deleteCustomFeed` thunks using the API
- `app/javascript/mastodon/reducers/custom_feeds.ts` — normalized store keyed by config ID

### i18n

All strings are in `app/javascript/mastodon/locales/en.json` under the `custom_feeds.*` namespace. Key groups:

- `custom_feeds.heading`, `custom_feeds.add_feed`, `custom_feeds.no_feeds_yet`, `custom_feeds.no_feeds_hint`
- `custom_feeds.form.*` — field labels, placeholders, save/cancel
- `custom_feeds.sources.*`, `custom_feeds.filters.*`, `custom_feeds.removal_strategies.*`, `custom_feeds.overflow.*` — phase option labels
- `custom_feeds.option.none` — shared "None" label for optional phases
- `custom_feeds.card.*` — card action labels and badges
- `navigation_bar.custom_feeds` — navigation link label

---

## Initializer

`config/initializers/custom_feeds.rb` — replaces `config/initializers/new_to_me.rb`.

```ruby
Rails.application.config.to_prepare do
  CustomFeeds::Sources::FollowedPosts.register!
  CustomFeeds::Filters::InteractedPosts.register!
  CustomFeeds::RemovalStrategies::OnInteraction.register!
  CustomFeeds::OverflowStrategies::OldestFirst.register!

  Api::V1::Timelines::ListController.prepend(CustomFeeds::ListControllerConcern)
  FeedInsertWorker.prepend(CustomFeeds::FeedInsertConcern)
  Favourite.include(CustomFeeds::FavouriteConcern)
  Status.include(CustomFeeds::StatusConcern)
end
```

---

## NTM Migration

1. Build the custom feeds system (all steps below).
2. Write data migration (`db/migrate/*_migrate_new_to_me_to_custom_feeds.rb`): for every `List` titled `"New To Me"`, create a `CustomFeedConfig` with the four NTM steps (`followed_posts` + `interacted_posts` + `on_interaction` + `oldest_first`).
3. Replace `config/initializers/new_to_me.rb` with `custom_feeds.rb`.
4. Delete all `NewToMe::*` source files.
5. Delete `NewToMeFeed` model.
6. Delete the `spec/lib/new_to_me/` and `spec/workers/new_to_me/` and `spec/models/new_to_me_feed_spec.rb` test files (replaced by custom feeds specs).

**Redis note**: Existing `feed:new_to_me:{account_id}` keys are not copied. The new `feed:custom:{list_id}` key starts empty and fills naturally as new posts arrive. For this small-scale instance, the brief empty-feed window is acceptable. If zero-downtime is needed, the data migration can pre-populate via `ZUNIONSTORE` — mark this as optional in the implementation.

---

## Rake Task: `dev:setup_new_to_me`

The existing `dev:setup_new_to_me` task in `lib/tasks/dev.rake` must be updated to create the list in the new custom feeds style rather than pushing directly to `NewToMe::FeedManager`.

### What changes

| Before                                                                                  | After                                                                                                                                  |
| --------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| References `NewToMe::LIST_TITLE`                                                        | References `'New To Me'` as a plain string (NTM constant deleted)                                                                      |
| Creates the list, adds `ListAccount`                                                    | Same                                                                                                                                   |
| Seeds posts                                                                             | Same (same post IDs, same content)                                                                                                     |
| Calls `NewToMe::FeedManager.instance.push(account, status)` for each post               | Creates a `CustomFeedConfig` for the list with the four NTM steps, then calls `CustomFeeds::FeedManager.instance.push(config, status)` |
| Reports `NewToMe::FeedManager.instance.key(admin_account.id)` for the Redis ZCARD check | Reports `CustomFeeds::FeedManager.instance.key(ntm_list.id)`                                                                           |

### Config creation snippet (in the updated task)

```ruby
# Create the CustomFeedConfig with the NTM preset if it doesn't already exist
ntm_config = CustomFeedConfig.find_or_create_by!(list: ntm_list, account: admin_account) do |c|
  c.enabled = true
end

# Ensure the four NTM steps exist (idempotent via find_or_create_by!)
[
  { phase: 'source',            step_type: 'followed_posts',   position: 0 },
  { phase: 'filter',            step_type: 'interacted_posts', position: 0 },
  { phase: 'removal_strategy',  step_type: 'on_interaction',   position: 0 },
  { phase: 'overflow_strategy', step_type: 'oldest_first',     position: 0 },
].each do |attrs|
  CustomFeedStep.find_or_create_by!(custom_feed_config: ntm_config, phase: attrs[:phase]) do |s|
    s.step_type = attrs[:step_type]
    s.position  = attrs[:position]
  end
end

# Seed the Redis feed using the new feed manager
cf_manager = CustomFeeds::FeedManager.instance
[plain_post, tagged_post, cw_post, poll_post, unlisted_post, media_post, reply_post].each do |status|
  cf_manager.push(ntm_config, status)
end

feed_size = RedisConnection.with { |r| r.zcard(cf_manager.key(ntm_list.id)) }
puts "New To Me list created: \"#{ntm_list.title}\" (id: #{ntm_list.id})"
puts "CustomFeedConfig id: #{ntm_config.id}"
puts "Seeded #{feed_size} posts into feed:custom:#{ntm_list.id} for @#{admin_account.username}"
puts "Visit: http://localhost:3000/lists/#{ntm_list.id}"
```

The task remains idempotent — `find_or_create_by!` on both the config and each step means re-running it is safe.

---

## File List

### New Backend Files

| File                                                        | Purpose                                         |
| ----------------------------------------------------------- | ----------------------------------------------- |
| `app/lib/custom_feeds.rb`                                   | Module namespace                                |
| `app/lib/custom_feeds/feed_manager.rb`                      | Redis operations (push, remove, stream events)  |
| `app/lib/custom_feeds/pipeline.rb`                          | Evaluates sources, filters, removal strategies  |
| `app/lib/custom_feeds/sources/base.rb`                      | Source interface + registry                     |
| `app/lib/custom_feeds/sources/followed_posts.rb`            | Home-feed delivery source                       |
| `app/lib/custom_feeds/filters/base.rb`                      | Filter interface + registry                     |
| `app/lib/custom_feeds/filters/interacted_posts.rb`          | Exclude if already interacted (ported from NTM) |
| `app/lib/custom_feeds/removal_strategies/base.rb`           | Removal strategy interface + registry           |
| `app/lib/custom_feeds/removal_strategies/on_interaction.rb` | Remove on any interaction                       |
| `app/lib/custom_feeds/overflow_strategies/base.rb`          | Overflow strategy interface + registry          |
| `app/lib/custom_feeds/overflow_strategies/oldest_first.rb`  | Evict oldest posts when over capacity (default) |
| `app/lib/custom_feeds/overflow_strategies/no_overflow.rb`   | Block insertion when at capacity                |
| `app/lib/custom_feeds/feed_insert_concern.rb`               | Prepended into FeedInsertWorker                 |
| `app/lib/custom_feeds/list_controller_concern.rb`           | Intercepts list timeline API endpoint           |
| `app/lib/custom_feeds/favourite_concern.rb`                 | Enqueues FeedRemoveWorker on favourite          |
| `app/lib/custom_feeds/status_concern.rb`                    | Enqueues FeedRemoveWorker on reblog/reply       |
| `app/models/custom_feeds_feed.rb`                           | Feed model; delegates key to FeedManager        |
| `app/models/custom_feed_config.rb`                          | Config ActiveRecord model                       |
| `app/models/custom_feed_step.rb`                            | Pipeline step ActiveRecord model                |
| `app/workers/custom_feeds/feed_insert_worker.rb`            | Insert worker; handles all configs per account  |
| `app/workers/custom_feeds/feed_remove_worker.rb`            | Remove worker; handles all configs per account  |
| `app/controllers/api/v1/custom_feeds_controller.rb`         | REST CRUD API                                   |
| `app/policies/custom_feed_config_policy.rb`                 | Pundit: owner-only access                       |
| `app/serializers/rest/custom_feed_config_serializer.rb`     | API serializer                                  |
| `config/initializers/custom_feeds.rb`                       | Registers step types + wires concerns           |
| `db/migrate/*_create_custom_feed_configs.rb`                | Schema migration                                |
| `db/migrate/*_create_custom_feed_steps.rb`                  | Schema migration                                |
| `db/migrate/*_migrate_new_to_me_to_custom_feeds.rb`         | Data migration                                  |

### Modified Backend Files

| File                       | Change                                                                                                     |
| -------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `config/routes/api.rb`     | `resources :custom_feeds` under `namespace :v1`                                                            |
| `config/routes/web_app.rb` | `/custom_feeds` SPA route (served by `home#index`)                                                         |
| `lib/tasks/dev.rake`       | Update `setup_new_to_me` task to create `CustomFeedConfig` + steps and seed via `CustomFeeds::FeedManager` |

### Deleted Backend Files

| File                                           | Replaced by                                       |
| ---------------------------------------------- | ------------------------------------------------- |
| `config/initializers/new_to_me.rb`             | `config/initializers/custom_feeds.rb`             |
| `app/lib/new_to_me.rb`                         | `app/lib/custom_feeds.rb`                         |
| `app/lib/new_to_me/feed_manager.rb`            | `app/lib/custom_feeds/feed_manager.rb`            |
| `app/lib/new_to_me/feed_insert_concern.rb`     | `app/lib/custom_feeds/feed_insert_concern.rb`     |
| `app/lib/new_to_me/list_controller_concern.rb` | `app/lib/custom_feeds/list_controller_concern.rb` |
| `app/lib/new_to_me/favourite_concern.rb`       | `app/lib/custom_feeds/favourite_concern.rb`       |
| `app/lib/new_to_me/status_concern.rb`          | `app/lib/custom_feeds/status_concern.rb`          |
| `app/models/new_to_me_feed.rb`                 | `app/models/custom_feeds_feed.rb`                 |
| `app/workers/new_to_me/feed_insert_worker.rb`  | `app/workers/custom_feeds/feed_insert_worker.rb`  |
| `app/workers/new_to_me/feed_remove_worker.rb`  | `app/workers/custom_feeds/feed_remove_worker.rb`  |

### New Frontend Files

| File                                                                                     | Purpose                                                                                       |
| ---------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `app/javascript/mastodon/features/custom_feeds_settings/index.tsx`                       | Settings page container                                                                       |
| `app/javascript/mastodon/features/custom_feeds_settings/components/custom_feed_card.tsx` | Feed list item (name + badges + edit/delete) and inline edit panel                            |
| `app/javascript/mastodon/features/custom_feeds_settings/components/custom_feed_form.tsx` | Create/edit form with `SelectField` dropdowns per phase                                       |
| `app/javascript/mastodon/actions/custom_feeds.ts`                                        | Redux thunks (`fetchCustomFeeds`, `createCustomFeed`, `updateCustomFeed`, `deleteCustomFeed`) |
| `app/javascript/mastodon/reducers/custom_feeds.ts`                                       | Redux reducer (normalized by config ID)                                                       |
| `app/javascript/mastodon/api/custom_feeds.ts`                                            | API client (uses `ApiCustomFeedConfigInputJSON` for request bodies)                           |
| `app/javascript/mastodon/api_types/custom_feeds.ts`                                      | TypeScript types including `ApiCustomFeedStepInputJSON` and `ApiCustomFeedConfigInputJSON`    |

### Modified Frontend Files

| File                                                                | Change                                                                                                                         |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| `app/javascript/mastodon/features/ui/index.jsx`                     | Register `CustomFeedsSettings` async component; add `WrappedRoute` for `/custom_feeds`                                         |
| `app/javascript/mastodon/features/ui/util/async-components.js`      | Add `CustomFeedsSettings` lazy import                                                                                          |
| `app/javascript/mastodon/reducers/index.ts`                         | Mount `customFeeds` reducer                                                                                                    |
| `app/javascript/mastodon/features/navigation_panel/index.tsx`       | Add `ColumnLink` to `/custom_feeds` with `TuneIcon`, below `FollowedTagsPanel`                                                 |
| `app/javascript/mastodon/locales/en.json`                           | Add all `custom_feeds.*` and `navigation_bar.custom_feeds` i18n strings                                                        |
| `app/javascript/mastodon/components/form_fields/select.module.scss` | Add `color-scheme: inherit` for dark mode native popup support                                                                 |
| `app/javascript/styles/mastodon/forms.scss`                         | Add `color-scheme: inherit` to `.simple_form select`                                                                           |
| `app/javascript/styles/mastodon/components.scss`                    | Add `.custom-feed-card--editing`, `.custom-feed-card__actions`, `.custom-feed-card__disabled-badge`, `.custom-feed-new` styles |

### Test Files

| File                                                              | Covers                                                                                         |
| ----------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `spec/lib/custom_feeds/feed_manager_spec.rb`                      | push (with overflow guards), remove, stream, key; oldest_first trim; no_overflow cap           |
| `spec/lib/custom_feeds/pipeline_spec.rb`                          | `include?`, `remove_on?`, and `overflow` accessor for all step combos; defaults to OldestFirst |
| `spec/lib/custom_feeds/sources/followed_posts_spec.rb`            | Home filter pass/fail → includes? true/false                                                   |
| `spec/lib/custom_feeds/filters/interacted_posts_spec.rb`          | exclude? for fav/reblog/reply; reblog-of-original resolution                                   |
| `spec/lib/custom_feeds/removal_strategies/on_interaction_spec.rb` | Returns true for all interaction types                                                         |
| `spec/lib/custom_feeds/overflow_strategies/oldest_first_spec.rb`  | trim removes oldest entries; at_capacity? always false                                         |
| `spec/lib/custom_feeds/feed_insert_concern_spec.rb`               | Dispatches to FeedInsertWorker only on :home type                                              |
| `spec/lib/custom_feeds/list_controller_concern_spec.rb`           | Returns CustomFeedsFeed for configured list; normal lists delegate to super                    |
| `spec/lib/custom_feeds/favourite_concern_spec.rb`                 | FeedRemoveWorker enqueued with 'favourite'                                                     |
| `spec/lib/custom_feeds/status_concern_spec.rb`                    | FeedRemoveWorker enqueued with 'reblog'/'reply'; skipped for remote accounts                   |
| `spec/models/custom_feeds_feed_spec.rb`                           | Redis key, pagination via Feed#get                                                             |
| `spec/models/custom_feed_config_spec.rb`                          | `steps_for`, enabled scope, list/account associations, uniqueness of list_id                   |
| `spec/models/custom_feed_step_spec.rb`                            | Validations (valid phase/step_type), position ordering                                         |
| `spec/workers/custom_feeds/feed_insert_worker_spec.rb`            | Multi-config dispatch, inactive user guard, home filter guard, successful push                 |
| `spec/workers/custom_feeds/feed_remove_worker_spec.rb`            | Removes original + reblogs from all matching configs, streaming deletes                        |
| `spec/requests/api/v1/custom_feeds_spec.rb`                       | CRUD API — auth, create, read, update, delete                                                  |
| `spec/requests/api/v1/timelines/custom_feed_spec.rb`              | Full list timeline spec: configured list returns custom feed data                              |

---

## Key Design Decisions

**Single `custom_feed_steps` table for all phases.** Fewer migrations when adding new step types. `phase` and `step_type` columns plus a `jsonb` options blob cover all future extensibility without schema changes.

**Redis keyed by `list_id`, not `account_id`.** `feed:custom:{list_id}` avoids collisions when an account has multiple custom feeds, and makes the key derivable from the list object alone.

**One `FeedInsertWorker` job per home-feed delivery handles all configs.** The current NTM spawns one worker per account per delivery. The new worker loads all enabled configs for the account in a single job, cutting Sidekiq queue volume proportionally as users add more custom feeds.

**`ListControllerConcern` queries the database, not the list title.** More robust than magic-title matching; works with any list name; the settings UI is the only configuration surface.

**Removal strategies are optional.** A feed with no removal strategy steps accumulates posts until Redis TTL or the MAX_ITEMS trim. This supports future "recommendation-style" feeds that don't remove on interaction.

**`FeedRemoveWorker` takes an `interaction_type` string.** Removal strategies can make fine-grained decisions (e.g., a future strategy that only removes on reblog, not on favourite).

**Overflow strategy defaults to `OldestFirst` without explicit config.** `Pipeline` always resolves a non-nil overflow strategy, falling back to `OldestFirst` when no `overflow_strategy` step is present. This preserves existing behavior for feeds created before the overflow strategy was added and avoids a mandatory migration to backfill the step on existing configs.

**`at_capacity?` is checked before `zadd`, not after.** This avoids needing to know which element was just inserted in order to roll it back. The slight race condition (two workers both pass the check, both insert, feed briefly exceeds MAX_ITEMS) is harmless — `trim` on the second insert corrects it, and for `NoOverflow` the extra post is silently kept rather than evicted.

**Phase dropdowns in the settings UI use static `defineMessages` for all option labels.** The React Intl babel plugin requires message IDs to be statically evaluable at build time. All phase option labels are defined in a single `optionMessages = defineMessages({...})` call; the `PHASE_OPTIONS` structure references them by property access. This satisfies static extraction while keeping the option list data-driven (adding a new step type only requires a new entry in `optionMessages` and `PHASE_OPTIONS`).

**Constant resolution.** Inside `module CustomFeeds`, bare `FeedManager` resolves to `CustomFeeds::FeedManager`. All references to the stock Mastodon feed manager use `::FeedManager`.

**Recommendations feed is out of scope.** The Recommendations plan (see `recommendations.md`) uses a periodic ingest model that does not map cleanly to the source/filter/removal pipeline. It will continue as a separate system. When the custom feeds system is stable, `RecommendedPosts` could be added as a source type.

---

## Implementation Order

1. Database migrations: `custom_feed_configs`, `custom_feed_steps`
2. ActiveRecord models: `CustomFeedConfig`, `CustomFeedStep` (with `steps_for` helper)
3. Plugin base classes: `Sources::Base`, `Filters::Base`, `RemovalStrategies::Base`, `OverflowStrategies::Base`
4. Initial implementations: `FollowedPosts`, `InteractedPosts`, `OnInteraction`, `OldestFirst`, `NoOverflow`
5. `CustomFeeds::FeedManager` + `CustomFeedsFeed` model
6. `CustomFeeds::Pipeline`
7. Workers: `FeedInsertWorker`, `FeedRemoveWorker`
8. Concerns: `FeedInsertConcern`, `ListControllerConcern`, `FavouriteConcern`, `StatusConcern`
9. Initializer `custom_feeds.rb` + routes (API + web SPA)
10. Data migration (NTM → custom feeds) + delete NTM files
11. Pundit policy + Settings API controller + serializer
12. Frontend: TypeScript types (`api_types/custom_feeds.ts`, `api/custom_feeds.ts`)
13. Frontend: Redux actions + reducer
14. Frontend: Settings page components (index, card, form)
15. Frontend: Navigation panel link + i18n strings
16. Frontend: Dark mode fix (`color-scheme: inherit`) + card/form CSS
17. Tests: RSpec (all spec files above)
18. Tests: Vitest for frontend components and Redux actions
19. Update `customizations/README.md`: replace the New To Me entry with Custom Feeds; update `customizations/new-to-me.md` with a deprecation notice pointing to `custom-feeds.md`
