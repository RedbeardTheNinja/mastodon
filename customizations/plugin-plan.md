# Plan: Extract Custom Feeds as a Mastodon Plugin Gem

Goal: package the Custom Feeds system as a Rails Engine gem (`mastodon-custom-feeds`) that any Mastodon instance can install with minimal changes to the Mastodon source tree.

---

## What "minimal changes" means

There is no dynamic plugin API in stock Mastodon. The absolute minimum we can require of the host application is:

| File                                                           | Change                                                      |
| -------------------------------------------------------------- | ----------------------------------------------------------- |
| `Gemfile`                                                      | `gem 'mastodon-custom-feeds'`                               |
| `config/routes/api.rb`                                         | 1 line: `resources :custom_feeds` inside the `v1` namespace |
| `app/javascript/mastodon/features/navigation_panel/index.tsx`  | 1 nav entry                                                 |
| `app/javascript/mastodon/features/ui/index.jsx`                | 1 route                                                     |
| `app/javascript/mastodon/features/ui/util/async-components.js` | 1 async-component export                                    |
| `app/javascript/mastodon/reducers/index.ts`                    | 1 reducer registration                                      |

Everything else — all Ruby, all migrations, all workers, all controllers, the settings page components, Redux actions, API types — lives inside the gem.

The frontend changes are unavoidable because Mastodon compiles a single Vite bundle; there is no runtime plugin loader. They are small, surgical, and could be delivered as a versioned patch file alongside the gem.

---

## Gem structure

```
mastodon-custom-feeds/
├── mastodon-custom-feeds.gemspec
├── lib/
│   ├── mastodon_custom_feeds.rb          ← require entry point; loads engine
│   └── mastodon_custom_feeds/
│       └── engine.rb                     ← Rails::Engine; runs to_prepare hooks
├── app/
│   ├── lib/
│   │   └── custom_feeds/                 ← move from app/lib/custom_feeds/ verbatim
│   │       ├── feed_manager.rb
│   │       ├── pipeline.rb
│   │       ├── feed_insert_concern.rb
│   │       ├── list_controller_concern.rb
│   │       ├── favourite_concern.rb
│   │       ├── status_concern.rb
│   │       ├── sources/
│   │       ├── filters/
│   │       ├── removal_strategies/
│   │       └── overflow_strategies/
│   ├── models/
│   │   ├── custom_feed_config.rb
│   │   ├── custom_feed_step.rb
│   │   └── custom_feeds_feed.rb
│   ├── workers/
│   │   └── custom_feeds/
│   │       ├── feed_insert_worker.rb
│   │       └── feed_remove_worker.rb
│   ├── controllers/
│   │   └── api/
│   │       └── v1/
│   │           └── custom_feeds_controller.rb
│   ├── policies/
│   │   └── custom_feed_config_policy.rb
│   ├── serializers/
│   │   └── rest/
│   │       └── custom_feed_config_serializer.rb
│   └── javascript/                       ← frontend source shipped inside the gem
│       └── mastodon/
│           ├── features/
│           │   └── custom_feeds_settings/
│           │       ├── index.tsx
│           │       └── components/
│           │           ├── custom_feed_card.tsx
│           │           └── custom_feed_form.tsx
│           ├── actions/
│           │   └── custom_feeds.ts
│           ├── reducers/
│           │   └── custom_feeds.ts
│           ├── api/
│           │   └── custom_feeds.ts
│           └── api_types/
│               └── custom_feeds.ts
├── db/
│   └── migrate/
│       ├── 20260404000001_create_custom_feed_configs.rb
│       ├── 20260404000002_create_custom_feed_steps.rb
│       └── 20260404000003_migrate_new_to_me_to_custom_feeds.rb
└── spec/                                 ← RSpec tests; run from the gem
    └── ...
```

### Why no `isolate_namespace`

The gem must load `CustomFeeds::*` into the shared namespace, not `MastodonCustomFeeds::CustomFeeds::*`, because Mastodon's own classes (`FeedInsertWorker`, `Favourite`, `Status`) and the existing `CustomFeedsFeed` model are referenced across the codebase without a gem prefix. Do not call `isolate_namespace`.

---

## The Engine

`lib/mastodon_custom_feeds/engine.rb`:

```ruby
module MastodonCustomFeeds
  class Engine < ::Rails::Engine
    # Do not isolate — we add to Mastodon's shared namespace
    # Tell Rails where our migrations live
    initializer 'mastodon_custom_feeds.migrations' do |app|
      unless app.root.to_s == root.to_s
        config.paths['db/migrate'].expanded.each do |path|
          app.config.paths['db/migrate'] << path
        end
      end
    end

    # Wire concerns after all app code is loaded (supports code reloading in dev)
    config.to_prepare do
      CustomFeeds::Sources::FollowedPosts.register!
      CustomFeeds::Filters::InteractedPosts.register!
      CustomFeeds::RemovalStrategies::OnInteraction.register!
      CustomFeeds::OverflowStrategies::OldestFirst.register!

      Api::V1::Timelines::ListController.prepend(CustomFeeds::ListControllerConcern)
      FeedInsertWorker.prepend(CustomFeeds::FeedInsertConcern)
      Favourite.include(CustomFeeds::FavouriteConcern)
      Status.include(CustomFeeds::StatusConcern)
    end
  end
end
```

This replaces `config/initializers/custom_feeds.rb` entirely. Once the gem is in the `Gemfile`, the Engine auto-loads; no separate initializer is needed in the host app.

---

## Migrations

Rails automatically picks up Engine migrations when `app.config.paths['db/migrate']` is extended (done above in the `migrations` initializer). The host app runs:

```bash
bin/rails db:migrate
```

No `bin/rails railties:install:migrations` is required with this approach; migrations run directly from the gem path, which is fine for a private/internal gem. If the gem is published to RubyGems and instances need to copy migrations (for version pinning), add a `rake task` to copy them — but defer this until the gem is actually published.

---

## Routes

The one required Mastodon source change for routes. In `config/routes/api.rb`, inside the `namespace :v1` block, add:

```ruby
resources :custom_feeds, only: [:index, :create, :show, :update, :destroy]
```

Alternatively, the Engine can append routes itself via a `config.after_initialize` block that calls `Rails.application.routes.draw` — but this is fragile across Mastodon upgrades and harder to reason about. A single-line explicit addition to `config/routes/api.rb` is cleaner and easier to review in a PR.

---

## Frontend

The four Mastodon source files that need modification:

### 1. `app/javascript/mastodon/features/navigation_panel/index.tsx`

Add a nav entry pointing to `/custom_feeds`. The gem ships a patch or documents the exact diff.

### 2. `app/javascript/mastodon/features/ui/index.jsx`

Add a route entry for the settings page. One import + one `<Route>` element.

### 3. `app/javascript/mastodon/features/ui/util/async-components.js`

Export `CustomFeedsSettings` as a lazy component. One function export.

### 4. `app/javascript/mastodon/reducers/index.ts`

Register the `customFeeds` reducer. One import + one key in `combineReducers`.

### Frontend source shipping strategy

The React/TypeScript source lives inside the gem at `app/javascript/mastodon/`. During installation, a rake task (or documented manual step) copies the frontend files into the host app's `app/javascript/mastodon/`:

```bash
bin/rails mastodon_custom_feeds:install:javascript
```

This task copies everything under `gem_root/app/javascript/mastodon/` into `app/javascript/mastodon/`. The copied files are committed to the host app. On gem upgrades, re-run the task and commit the diff.

This is the same pattern used by popular Rails gems that ship frontend assets (e.g., Active Admin, Devise views). It avoids Vite/webpack symlink complexity while keeping the source in the gem as the canonical location.

The four Mastodon-core JS file modifications are still required (they cannot be automated without patching Mastodon itself), but they are documented as a one-time setup patch and will not change unless Mastodon restructures its navigation or reducer system.

---

## gemspec

```ruby
Gem::Specification.new do |spec|
  spec.name    = 'mastodon-custom-feeds'
  spec.version = '0.1.0'
  spec.summary = 'Pluggable algorithmic feed system for Mastodon'
  spec.files   = Dir[
    'lib/**/*',
    'app/**/*',
    'db/**/*',
    'config/**/*',
  ]
  spec.require_paths = ['lib']

  spec.add_dependency 'rails', '>= 7.2'
  spec.add_dependency 'sidekiq', '>= 7'
end
```

Mastodon itself is not listed as a dependency (it's not on RubyGems). The gem relies on Mastodon's classes being present at runtime; this is acceptable for a Mastodon-specific plugin.

---

## Installation story (from a host app's perspective)

```ruby
# Gemfile
gem 'mastodon-custom-feeds', path: '../mastodon-custom-feeds'  # local dev
# or: gem 'mastodon-custom-feeds', github: 'yourname/mastodon-custom-feeds', tag: 'v0.1.0'
```

```bash
bundle install
bin/rails db:migrate
bin/rails mastodon_custom_feeds:install:javascript
```

Then apply the four JS patches (nav entry, route, async-component, reducer). Rebuild the frontend:

```bash
yarn build:production
```

---

## What to delete from the Mastodon fork

After the gem is created and the Mastodon fork depends on it, remove from the fork:

| Path                                                    | Why                               |
| ------------------------------------------------------- | --------------------------------- |
| `app/lib/custom_feeds/`                                 | Moved into gem                    |
| `app/models/custom_feed_config.rb`                      | Moved into gem                    |
| `app/models/custom_feed_step.rb`                        | Moved into gem                    |
| `app/models/custom_feeds_feed.rb`                       | Moved into gem                    |
| `app/workers/custom_feeds/`                             | Moved into gem                    |
| `app/controllers/api/v1/custom_feeds_controller.rb`     | Moved into gem                    |
| `app/policies/custom_feed_config_policy.rb`             | Moved into gem                    |
| `app/serializers/rest/custom_feed_config_serializer.rb` | Moved into gem                    |
| `config/initializers/custom_feeds.rb`                   | Replaced by Engine's `to_prepare` |
| `db/migrate/*_create_custom_feed_configs.rb`            | Moved into gem                    |
| `db/migrate/*_create_custom_feed_steps.rb`              | Moved into gem                    |
| `db/migrate/*_migrate_new_to_me_to_custom_feeds.rb`     | Moved into gem                    |
| `spec/lib/custom_feeds/`                                | Moved into gem                    |
| `spec/workers/custom_feeds/`                            | Moved into gem                    |
| `spec/models/custom_feed*_spec.rb`                      | Moved into gem                    |
| `spec/requests/api/v1/custom_feeds_spec.rb`             | Moved into gem                    |

Keep in the fork (copied from gem on install, committed):

- `app/javascript/mastodon/features/custom_feeds_settings/`
- `app/javascript/mastodon/actions/custom_feeds.ts`
- `app/javascript/mastodon/reducers/custom_feeds.ts`
- `app/javascript/mastodon/api/custom_feeds.ts`
- `app/javascript/mastodon/api_types/custom_feeds.ts`

Keep with small modifications (the four core Mastodon JS files plus the API route line).

---

## Implementation steps

1. **Create the gem repo** — `mastodon-custom-feeds/` alongside the Mastodon fork (or as a subdirectory of a monorepo).

2. **Scaffold the Engine** — `lib/mastodon_custom_feeds.rb` + `lib/mastodon_custom_feeds/engine.rb` with the migration path extension and `to_prepare` block.

3. **Move Ruby files** — copy `app/lib/custom_feeds/`, models, workers, controller, policy, serializer into the gem's `app/` tree. Verify `require` paths are correct (Rails Engine autoloads `app/` subdirectories automatically, including `app/lib/`).

4. **Move migrations** — copy the three migration files into `db/migrate/`. Confirm the `migrations` initializer in the Engine registers them.

5. **Move RSpec files** — copy into gem's `spec/`. Add a minimal `spec/spec_helper.rb` that loads the Engine + a stub Mastodon environment (or use `combustion` / `appraisals` for isolated Engine testing).

6. **Write the JS install task** — `lib/tasks/mastodon_custom_feeds/install.rake`:

   ```ruby
   namespace :mastodon_custom_feeds do
     namespace :install do
       desc 'Copy frontend source files into the host app'
       task :javascript do
         gem_js = MastodonCustomFeeds::Engine.root.join('app/javascript/mastodon')
         host_js = Rails.root.join('app/javascript/mastodon')
         FileUtils.cp_r(gem_js.to_s + '/.', host_js.to_s)
         puts "Copied frontend files from mastodon-custom-feeds into app/javascript/mastodon/"
       end
     end
   end
   ```

7. **Point the fork at the gem** — add `gem 'mastodon-custom-feeds', path: '../mastodon-custom-feeds'` to the fork's `Gemfile`. Run `bundle install`. Delete the source files now in the gem. Verify `bin/rails db:migrate`, boot, and test.

8. **Document the four JS patches** — write a `INSTALL.md` in the gem describing the four one-time edits to Mastodon source, with exact before/after diffs pinned to a Mastodon version range.

9. **Tag v0.1.0** once the fork depends on it cleanly and tests pass.

---

## Open questions / deferred decisions

- **Gem hosting**: private GitHub repo + `github:` Gemfile source is simplest for now. RubyGems publication deferred until the API is stable.
- **Versioning against Mastodon**: the gem should declare the minimum Mastodon version it targets (e.g., `>= 4.4`) in its README. No automated enforcement mechanism exists, but the `to_prepare` hooks will raise `NameError` at boot if the expected Mastodon classes are missing.
- **Frontend as a compiled asset**: a future alternative is to pre-compile the frontend into a single JS file that a Mastodon instance loads as a separate `<script>` tag, removing all four JS patches. This is significantly more work (no shared React instance, no Redux store access) and is out of scope for v0.1.
- **NTM data migration in the gem**: the third migration (`migrate_new_to_me_to_custom_feeds`) references the `"New To Me"` list title. It's harmless to run on instances without NTM lists (it's a no-op). Keep it in the gem but document that it only affects forks that previously ran the NTM implementation.
