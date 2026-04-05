# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Mastodon is an ActivityPub-based federated social network server. The stack is:

- **Backend**: Ruby on Rails (REST API, web pages, background jobs)
- **Frontend**: React + Redux + TypeScript, bundled with Vite
- **Streaming**: Separate Node.js server for WebSocket real-time updates
- **Database**: PostgreSQL + Redis (caching, queues, pub/sub)

## Development Setup

```bash
bin/setup          # Install dependencies and prepare database
bin/dev            # Start all services (Rails, Sidekiq, streaming, Vite)
```

`bin/dev` runs 4 processes via `Procfile.dev`:

- **web** (port 3000): Rails/Puma
- **sidekiq**: Background jobs
- **stream** (port 4000): Node.js streaming server
- **vite**: Frontend dev server with HMR

Default dev credentials: `admin@localhost` / `mastodonadmin`

## Commands

### Ruby/Rails

```bash
bin/rubocop                         # Lint Ruby
bin/brakeman                        # Security analysis
bin/rails db:migrate                # Run pending migrations
bin/rails dev:populate_sample_data  # Create sample content

# Tests
bin/flatware rspec                  # Run all Ruby tests (parallel)
bin/rspec spec/models/account_spec.rb  # Run a single spec file
bin/rspec spec/models/              # Run a directory of specs
```

### JavaScript/Frontend

```bash
yarn lint                # ESLint + Stylelint
yarn lint:js             # ESLint only
yarn fix                 # Auto-fix lint issues
yarn typecheck           # TypeScript type checking
yarn i18n:extract        # Extract i18n strings to en.json

# Tests
yarn test:js             # Run Vitest unit tests
yarn test:storybook      # Run Storybook component tests
yarn test                # lint + typecheck + test:js

# Build
yarn build:production    # Production build
```

## Architecture

### Backend

- `app/controllers/api/v1/` — REST API endpoints (Mastodon API spec)
- `app/models/` — ActiveRecord models (Account, Status, Follow, etc.)
- `app/serializers/` — ActiveModelSerializers JSON serializers for API responses
- `app/services/` — Business logic (e.g., `PostStatusService`, `FetchRemoteAccountService`)
- `app/workers/` — Sidekiq background jobs
- `app/policies/` — Pundit authorization policies
- `lib/` — Custom libraries, including ActivityPub handling (`lib/mastodon/`)

### Frontend

- `app/javascript/mastodon/` — Main React application
  - `components/` — Shared UI components
  - `features/` — Page-level feature modules (compose, timelines, profiles, etc.)
  - `reducers/` — Redux reducers
  - `actions/` — Redux actions and async thunks
  - `api/` — API client utilities
- `app/javascript/entrypoints/` — Vite entry points
- `app/javascript/styles/` — SCSS stylesheets

### ActivityPub / Federation

Federation logic lives in `app/lib/activitypub/` and `lib/`. Incoming activities are processed by workers. The `app/workers/activitypub/` directory contains processors for different activity types.

### Feed Architecture

Feeds are Redis sorted sets (score = status ID, member = status ID). `Feed` base class in `app/models/feed.rb` reads from Redis; subclasses override `key`. `FeedManager` (`app/lib/feed_manager.rb`) handles push/remove/filter for home and list feeds and sends streaming updates via `redis.publish("timeline:...")`.

Redis key patterns:

- Home: `feed:home:{account_id}`
- List: `feed:list:{list_id}`
- New To Me: `feed:new_to_me:{account_id}`

Useful debugging commands:

```bash
redis-cli ZCARD feed:home:{account_id}        # feed size
redis-cli ZRANGE feed:home:{account_id} -5 -1 # 5 most recent IDs
redis-cli ZRANGE dead 0 -1                    # failed Sidekiq jobs
```

**Reblog normalization:** The `Favourite` model normalizes to the original via `before_validation { self.status = status.reblog if status.reblog? }`. This means `favourite.status_id` is always the original status ID, never a reblog ID. Feed workers that store or remove statuses must account for this — store original IDs, not reblog IDs.

### Testing

- **Ruby**: RSpec + Fabrication (factory gem). Tests use a real PostgreSQL database — do not mock the database.
- **JavaScript**: Vitest + MSW (Mock Service Worker) for API mocking. Browser tests use Playwright.
- System tests in `spec/system/` use Capybara + Playwright.

## Key Conventions

- Ruby version: 3.4.x (see `.ruby-version`)
- Node version: 24.x (see `.nvmrc`)
- Package manager: Yarn v4 (workspaces: root + `streaming/`)
- API follows the Mastodon REST API spec; breaking changes require API versioning
- i18n strings are in `config/locales/` (Ruby) and `app/javascript/mastodon/locales/` (JS)
- **Ruby constant resolution in namespaced code:** Inside a module like `module NewToMe`, a bare `FeedManager` resolves to `NewToMe::FeedManager`, not the top-level class. Use `::FeedManager` to reference top-level constants from within sub-modules.

## Environments

This repo is used in two environments. Determine which one you are in, then read the appropriate file for environment-specific commands.

**How to detect:**

- **Dev container** (Windows/Docker): working directory is `/workspaces/mastodon`, or `test -d /workspaces` is true
- **Production server** (Linux): working directory is `/home/mastodon/live`

**Environment guides** (read the relevant one):

- Dev container: [`.claude/env-dev-container.md`](.claude/env-dev-container.md)
- Production server: [`.claude/env-production.md`](.claude/env-production.md)
