# Dev Container Environment

Development runs in Docker via VS Code Dev Containers on Windows. The main app container is `devcontainer-app-1`.

## Running Commands

All Rails/Ruby commands run inside the container via `docker exec`:

```bash
# Rails / Ruby
docker exec devcontainer-app-1 bash -c "cd /workspaces/mastodon && bin/rails ..."
docker exec devcontainer-app-1 bash -c "cd /workspaces/mastodon && bin/rails runner 'puts Model.count'"
docker exec devcontainer-app-1 bash -c "cd /workspaces/mastodon && bin/rails db:migrate"
docker exec devcontainer-app-1 bash -c "cd /workspaces/mastodon && bin/rails custom_feeds:seed_nsfw"
docker exec devcontainer-app-1 bin/rubocop path/to/file.rb

# Sidekiq (restart after changing sidekiq.yml)
docker exec devcontainer-app-1 ps aux | grep sidekiq   # find PID
docker exec -d devcontainer-app-1 bash -c "cd /workspaces/mastodon && bundle exec sidekiq -C config/sidekiq.yml >> log/sidekiq.log 2>&1"

# Redis
docker exec devcontainer-redis-1 redis-cli ZCARD feed:home:{account_id}

# Postgres
docker exec devcontainer-db-1 psql -U mastodon -d mastodon_development -c "SELECT ..."
```

Other containers: `devcontainer-db-1` (Postgres), `devcontainer-redis-1` (Redis), `devcontainer-es-1` (Elasticsearch).

Note: `bin/rails runner` works in development mode inside the container. Do NOT use `RAILS_ENV=production` here.
