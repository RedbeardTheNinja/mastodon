# New To Me Feed

A server-side algorithmic feed that surfaces posts from followed accounts the user has not yet interacted with. It is exposed as a standard Mastodon List timeline so no frontend changes are required.

## How It Works

When a post from a followed account arrives in the user's home feed, it is also evaluated for the New To Me feed. A post is added if the user has not yet favourited it, reblogged it, or replied to it. When the user performs any of those interactions the post is immediately removed from the feed. Reblogs are tracked by their reblog ID so the "boosted by" attribution is visible; the interacted check resolves a reblog to its original before querying, so interacting with an original removes all reblogs of it as well.

The feed is stored as a Redis sorted set (`feed:new_to_me:{account_id}`) with the status ID used as both score and member, mirroring the pattern used by home and list feeds. It is read through the standard `Feed` class hierarchy and surfaced via the existing List timeline API endpoint by intercepting the `list_feed` method when the list title matches "New To Me".

### Feed Lifecycle

1. A `FeedInsertWorker` job runs for every home-feed delivery.
2. The `NewToMe::FeedInsertConcern` (prepended into `FeedInsertWorker`) fires a `NewToMe::FeedInsertWorker` job whenever the home-feed delivery succeeds (type `:home`).
3. `NewToMe::FeedInsertWorker` re-runs the home feed filter and the `interacted?` check, then calls `NewToMe::FeedManager#push` to add the status.
4. When the user favourites, reblogs, or replies, `NewToMe::FeedRemoveWorker` removes the status (and any reblogs of it) from the Redis set and publishes a streaming `delete` event on the list channel so the client UI updates in real time.

### Setup

Create a Mastodon List named exactly **"New To Me"** on the account. The List timeline for that list will then serve the algorithmic feed instead of the normal list content.

---

## Files

### New Files

#### `app/lib/new_to_me.rb`
Defines the `NewToMe` module and the `LIST_TITLE = 'New To Me'` constant used across all components to identify the special list.

#### `app/lib/new_to_me/feed_manager.rb`
Singleton that owns all Redis operations for the NTM feed.

- `key(account_id)` — returns `feed:new_to_me:{account_id}`
- `push(account, status)` — adds a status to the feed; skips inactive users and already-interacted posts; trims to `FeedManager::MAX_ITEMS`
- `remove(account, status_id)` — removes a status ID from the feed
- `interacted?(account, status)` — resolves reblogs to their original, then checks for existing favourites, reblogs, and replies by the account

#### `app/lib/new_to_me/feed_insert_concern.rb`
Prepended into the stock `FeedInsertWorker`. Overrides `perform_push` to call `super` (normal home-feed insert) and then enqueue `NewToMe::FeedInsertWorker` whenever `@type == :home`.

#### `app/lib/new_to_me/list_controller_concern.rb`
Prepended into `Api::V1::Timelines::ListController`. Overrides `list_feed` to return a `NewToMeFeed` instance when the list title is "New To Me", otherwise delegates to `super`.

#### `app/lib/new_to_me/favourite_concern.rb`
Included into the `Favourite` model. Adds an `after_create_commit` callback that enqueues `NewToMe::FeedRemoveWorker` with the favourite's `status_id` and `account_id`. Because `Favourite` normalises its `status_id` to the original (never a reblog ID), the remove worker always receives the original status ID.

#### `app/lib/new_to_me/status_concern.rb`
Included into the `Status` model. Adds an `after_create_commit` callback that enqueues `NewToMe::FeedRemoveWorker` when the new status is a local reblog (passes `reblog_of_id`) or a local reply (passes `in_reply_to_id`). Only fires for local accounts.

#### `app/models/new_to_me_feed.rb`
`NewToMeFeed < Feed`. Initialises with `:new_to_me` type and delegates `key` to `NewToMe::FeedManager#key` so the standard `Feed#get` Redis read path works unchanged.

#### `app/workers/new_to_me/feed_insert_worker.rb`
Sidekiq worker (queue `push`, 3 retries). Loads the status and account on the primary DB, then on the read replica:
- Returns early if the account is not recently active.
- Returns early if `::FeedManager.instance.filter(:home, ...)` would filter the post (uses `::` to resolve the top-level constant, not `NewToMe::FeedManager`).
- Calls `NewToMe::FeedManager.instance.push`.

#### `app/workers/new_to_me/feed_remove_worker.rb`
Sidekiq worker (queue `default`, 3 retries). Given a `status_id` (always the original) and `account_id`:
- Collects the original ID plus the IDs of all reblogs of it (`Status.where(reblog_of_id: status_id)`).
- Removes all of those IDs from the NTM Redis set.
- Looks up the "New To Me" list and publishes a streaming `delete` event for each removed ID on `timeline:list:{list_id}`, so the client removes the post from the UI without a page refresh.

#### `config/initializers/new_to_me.rb`
Wires the concerns into existing classes at boot via `Rails.application.config.to_prepare`:
- `Api::V1::Timelines::ListController.prepend(NewToMe::ListControllerConcern)`
- `FeedInsertWorker.prepend(NewToMe::FeedInsertConcern)`
- `Favourite.include(NewToMe::FavouriteConcern)`
- `Status.include(NewToMe::StatusConcern)`

### Test Files

All specs live under `spec/` and mirror the source tree:

| Spec file | What it covers |
|---|---|
| `spec/lib/new_to_me/feed_manager_spec.rb` | `push`, `remove`, `interacted?`, trimming |
| `spec/lib/new_to_me/feed_insert_concern_spec.rb` | NTM worker enqueue on home-feed push |
| `spec/lib/new_to_me/list_controller_concern_spec.rb` | NTM list returns `NewToMeFeed`; normal lists unchanged |
| `spec/lib/new_to_me/favourite_concern_spec.rb` | Remove worker enqueued on favourite |
| `spec/lib/new_to_me/status_concern_spec.rb` | Remove worker enqueued on reblog/reply; skipped for remote accounts |
| `spec/models/new_to_me_feed_spec.rb` | Redis key, pagination via `Feed#get` |
| `spec/workers/new_to_me/feed_insert_worker_spec.rb` | Filter logic, interacted? guard, successful push |
| `spec/workers/new_to_me/feed_remove_worker_spec.rb` | Removes original + reblogs, streaming delete events |
| `spec/requests/api/v1/timelines/new_to_me_spec.rb` | Full API request spec for the list timeline endpoint |

---

## Key Design Decisions

**No database migrations.** The feed lives entirely in Redis, consistent with how home and list feeds work in Mastodon.

**No frontend changes.** By intercepting the existing List timeline API, any Mastodon-compatible client that can display a list timeline automatically supports the NTM feed.

**Reblog handling.** The NTM feed stores the reblog's own status ID (not the original), so the "boosted by X" attribution is preserved in the client. `interacted?` resolves reblogs to their original before checking, and `FeedRemoveWorker` removes both the original and every reblog of it to handle the case where a favourite arrives with the original ID (due to `Favourite` normalisation).

**Constant resolution.** Inside `module NewToMe`, a bare `FeedManager` would resolve to `NewToMe::FeedManager`. All references to the stock Mastodon feed manager use `::FeedManager` to avoid this.

**Streaming deletes.** `FeedRemoveWorker` publishes `event: :delete` on the list's streaming channel so interactions remove posts from the UI immediately without requiring a page refresh or polling.
