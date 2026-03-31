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