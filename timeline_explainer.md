# How Mastodon Receives and Stores Posts for Your Home Timeline

This document traces the full journey of a post from a remote account you follow — from the moment it arrives at the server to when you see it in your home timeline.

---

## Overview

The flow has two distinct phases:

1. **Ingestion** — A remote server sends the post to your Mastodon instance via ActivityPub
2. **Fan-out** — The post is distributed into the home timelines of every local follower

Timeline data is split across two stores: **PostgreSQL** holds the full post content, and **Redis** holds each user's ordered list of post IDs to display.

---

## Phase 1: Receiving the Post

### Step 1 — HTTP Inbox

`app/controllers/activitypub/inboxes_controller.rb`

When you follow a remote account, their server records your instance's inbox URL. Whenever they post, their server sends an HTTP `POST` to one of two inboxes:

- `/inbox` — the shared inbox (all activity for the instance)
- `/users/:username/inbox` — a user-specific inbox

The controller:
- Rejects payloads over 1MB
- Verifies the HTTP Signature on the request to authenticate the sending server
- Refreshes stale remote account metadata if needed
- Enqueues `ActivityPub::ProcessingWorker` with the raw JSON body and returns immediately

The inbox returns quickly and does all real work asynchronously to avoid blocking the remote server.

### Step 2 — Processing Worker

`app/workers/activitypub/processing_worker.rb`

A Sidekiq worker on the `ingress` queue picks up the job. It looks up the sender account and hands the raw JSON body to `ActivityPub::ProcessCollectionService`.

### Step 3 — Activity Routing

`app/services/activitypub/process_collection_service.rb`

This service parses the JSON-LD document, verifies the actor hasn't been suspended, and routes it to the correct activity handler based on the `type` field. A new post is a `Create` activity, so it instantiates `ActivityPub::Activity::Create`.

### Step 4 — Creating the Status

`app/lib/activitypub/activity/create.rb`

This is the core of ingestion. The `perform` method:

1. Checks whether the object is an acceptable type (Note, Question, etc.)
2. Verifies the URI host matches the actor's server (prevents impersonation)
3. Checks if the post already exists (deduplication via a Redis lock on the URI)
4. Validates the post is actually relevant to local users — it must be from someone followed locally, mention a local user, be a reply to a local post, or arrive via a relay

If all checks pass, it runs inside a database transaction:

```ruby
ApplicationRecord.transaction do
  @status = Status.create!(@params.merge(quote: @quote))
  attach_tags(@status)
  attach_mentions(@status)
  attach_counts(@status)
end
```

After saving, it queues workers to download media attachments, resolve parent posts if it's a reply, and crawl any linked URLs.

Finally, it calls `distribute`, which enqueues `DistributionWorker`.

---

## Phase 2: Fan-Out to Timelines

### Step 5 — Distribution Worker

`app/workers/distribution_worker.rb`

Picks up the status ID and calls `FanOutOnWriteService`. Uses a Redis lock to prevent duplicate distributions if the job is retried.

### Step 6 — Fan-Out on Write Service

`app/services/fan_out_on_write_service.rb`

This is the fan-out engine. For a public post it does three things:

1. **`deliver_to_all_followers!`** — Iterates over all local followers of the posting account in batches, bulk-enqueuing one `FeedInsertWorker` job per follower
2. **`fan_out_to_public_recipients!`** — Delivers to users who follow relevant hashtags
3. **`fan_out_to_public_streams!`** — Broadcasts to WebSocket connections for real-time updates

The home timeline fan-out scales with follower count. An account with 10,000 local followers creates 10,000 `FeedInsertWorker` jobs, which is why these are bulk-enqueued in batches.

### Step 7 — Feed Insert Worker

`app/workers/feed_insert_worker.rb`

Each job handles one follower. It:

1. Applies the follower's filter rules via `FeedManager#filter` — checking blocks, mutes, language filters, reply/reblog visibility preferences
2. If the post passes filters, calls `FeedManager#push_to_home`
3. If the post should trigger a notification (e.g. a mention), enqueues `NotifyService`

### Step 8 — Feed Manager (Redis Storage)

`app/lib/feed_manager.rb`

`push_to_home` does a quick check — if the user hasn't signed in recently, their feed isn't maintained in Redis (it gets rebuilt on next login). Otherwise it calls `add_to_feed`, which writes to a Redis Sorted Set:

```
Key:    feed:home:{account_id}
Score:  status ID (a Snowflake ID, numerically sortable by time)
Member: status ID
```

After inserting, it trims the feed to the most recent 800 items.

If the user has an active WebSocket connection, it also pushes a real-time update via `PushUpdateWorker`.

---

## Retrieval: Serving the Timeline

`app/controllers/api/v1/timelines/home_controller.rb`
`app/models/feed.rb`

When you open Mastodon, the client calls `GET /api/v1/timelines/home`. The controller:

1. Reads status IDs from Redis using `ZREVRANGEBYSCORE` (newest first, paginated by `max_id`/`since_id`)
2. Fetches the full status rows from PostgreSQL using those IDs
3. Serializes and returns them as JSON

Redis only stores IDs — PostgreSQL has the actual content. The Redis sorted set is purely a fast, ordered index of what belongs in your feed.

---

## Storage Summary

| What | Where | Structure |
|---|---|---|
| Post content (text, account, timestamps, etc.) | PostgreSQL `statuses` table | Rows |
| Your home timeline (ordered list of post IDs) | Redis | Sorted Set `feed:home:{id}` |
| Max items per feed | Redis | 800 entries |
| Ordering | Redis score | Snowflake ID (time-sortable integer) |

---

## Full Flow Diagram

```
Remote server POST /inbox
         |
         v
ActivityPub::InboxesController      # Verify signature, enqueue job
         |
         v
ActivityPub::ProcessingWorker       # Sidekiq, ingress queue
         |
         v
ActivityPub::ProcessCollectionService  # Parse JSON-LD, route by type
         |
         v
ActivityPub::Activity::Create       # Validate, deduplicate, save to PostgreSQL
         |
         v
DistributionWorker                  # Sidekiq
         |
         v
FanOutOnWriteService                # For each local follower...
         |
         v
FeedInsertWorker (×N followers)     # Sidekiq, bulk-enqueued
         |
         v
FeedManager#push_to_home            # Filter check, then write to Redis
         |
         v
Redis ZSET: feed:home:{account_id}  # Ordered list of status IDs


GET /api/v1/timelines/home
         |
         v
Feed#from_redis                     # ZREVRANGEBYSCORE → list of IDs
         |
         v
Status.where(id: [...])             # Hydrate from PostgreSQL
         |
         v
JSON response
```

---

## Key Files at a Glance

| File | Role |
|---|---|
| `app/controllers/activitypub/inboxes_controller.rb` | HTTP entry point for incoming activities |
| `app/workers/activitypub/processing_worker.rb` | Async worker parsing the activity |
| `app/services/activitypub/process_collection_service.rb` | Routes to the right activity handler |
| `app/lib/activitypub/activity/create.rb` | Creates the Status record |
| `app/workers/distribution_worker.rb` | Triggers the fan-out |
| `app/services/fan_out_on_write_service.rb` | Distributes to all follower feeds |
| `app/workers/feed_insert_worker.rb` | Inserts one status into one follower's feed |
| `app/lib/feed_manager.rb` | Manages Redis sorted sets for all feed types |
| `app/models/feed.rb` | Reads IDs from Redis |
| `app/controllers/api/v1/timelines/home_controller.rb` | Serves the home timeline API |