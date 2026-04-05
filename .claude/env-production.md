# Production Server Environment

Runs in production mode (`RAILS_ENV=production`, database `mastodon_production`, domain `redbeardthe.ninja`). Ruby via rbenv at `/home/mastodon/.rbenv`. App runs as the `mastodon` user. Services managed by systemd.

**Default behavior: run all commands as the `mastodon` user via `sudo -u mastodon ...` unless the user explicitly asks otherwise.**

## Running Commands

```bash
# Rails command
sudo -u mastodon bash -c 'export PATH="/home/mastodon/.rbenv/shims:/home/mastodon/.rbenv/bin:$PATH" && eval "$(rbenv init -)" && RAILS_ENV=production bin/rails ...'

# Query the database directly (faster for diagnostics)
sudo -u mastodon psql -d mastodon_production -c "SELECT ..."

# Query Redis directly
sudo -u mastodon redis-cli ZCARD feed:home:{account_id}

# Git operations
sudo -u mastodon git ...
```

## Restarting Services

```bash
sudo systemctl restart mastodon-web      # Puma (picks up code/config changes)
sudo systemctl restart mastodon-sidekiq  # Sidekiq (picks up new workers/schedules)
# streaming rarely needs restart unless streaming server code changed
```

Note: `bin/rails runner` in development mode fails at boot (LetterOpenerWeb CSP issue). Always use `RAILS_ENV=production` or query the database/Redis directly.
