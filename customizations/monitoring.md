# Monitoring

Prometheus + Grafana stack measuring custom and algorithmic feed performance. Scrapes Rails, Sidekiq, Redis, and system metrics from the production server.

## Architecture

```
antypdet-server (production)           antypdet-gaming (local Windows)
─────────────────────────────          ──────────────────────────────────────
  Rails / Puma                           docker compose -f monitoring/docker-compose.yml up -d
  Sidekiq                    scrape ──►  Prometheus  :9090
  prometheus_exporter :9394             Grafana     :3001  (admin/admin)
  node_exporter       :9100             Pushgateway :9091  (available for ad-hoc use)
  redis_exporter      :9121
  Mastodon streaming  :4000/metrics
```

Prometheus on `antypdet-gaming` scrapes three endpoints on `antypdet-server` every 15 s via pull. Hostname resolution requires the two machines to be on the same network (LAN or Tailscale).

---

## Repo customizations that enable monitoring

These files exist in this fork specifically to support the monitoring stack. They have no upstream equivalent.

### `app/lib/custom_feeds/metrics.rb`

Thin wrapper around `PrometheusExporter::Client`. All emit methods guard with `enabled?` and a bare `rescue` so metrics never raise into the main execution path. Used by `FeedInsertWorker`, `PullSourceIngestWorker`, `AlgorithmicFeedWorker`, `SignalWorker`, and `StatsCollectorWorker`.

### `app/workers/custom_feeds/stats_collector_worker.rb`

Sidekiq scheduler worker (queue: `scheduler`, every 5 min). Uses `SCAN` to find all `feed:custom:*` and `feed:algo:*:pending` keys, samples per-key memory via `DEBUG OBJECT`, queries PostgreSQL `pg_relation_size` for custom feed tables, and emits gauges via `CustomFeeds::Metrics`. Uses HSCAN-based iteration to avoid loading entire key sets into memory.

### `lib/mastodon/prometheus_exporter/custom_feeds_collector.rb`

`PrometheusExporter::Server::TypeCollector` implementation. Registered with the standalone `prometheus_exporter` process via `--type-collector`. Receives JSON metric payloads from Rails and Sidekiq processes (via `PrometheusExporter::Client`) and exposes them at `:9394/metrics`.

### `lib/mastodon/prometheus_exporter/local_server.rb`

Extended to support `register_collector` for dev/local mode, where the collector runs inside the Rails process rather than a separate server. Allows `MASTODON_PROMETHEUS_EXPORTER_LOCAL=true` to work in development without starting a standalone `prometheus_exporter` process.

### `monitoring/` directory

Docker Compose stack (`monitoring/docker-compose.yml`) running Prometheus, Grafana, and Pushgateway locally on `antypdet-gaming`. Grafana dashboards are auto-provisioned from `monitoring/grafana/dashboards/`. Prometheus scrape config is at `monitoring/prometheus/prometheus.yml`. Data persists in named Docker volumes (`prometheus_data`, `grafana_data`).

### Sidekiq cron

`StatsCollectorWorker` and `Recommendations::ScheduleAlgorithmicFeedsWorker` are scheduled in `config/sidekiq.yml` (every 5 minutes). `CustomFeeds::SchedulePullSourcesWorker` runs on the same cadence.

---

## Production server setup

All steps run on **antypdet-server** as the `mastodon` user (or with `sudo` where noted).

### 1. Install node_exporter

```bash
VERSION=1.8.2
wget https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz
tar xf node_exporter-${VERSION}.linux-amd64.tar.gz
sudo mv node_exporter-${VERSION}.linux-amd64/node_exporter /usr/local/bin/

sudo tee /etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus node_exporter
After=network.target

[Service]
User=nobody
ExecStart=/usr/local/bin/node_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now node_exporter
# Verify: curl http://localhost:9100/metrics | head
```

### 2. Install redis_exporter

```bash
VERSION=1.62.0
wget https://github.com/oliver006/redis_exporter/releases/download/v${VERSION}/redis_exporter-v${VERSION}.linux-amd64.tar.gz
tar xf redis_exporter-v${VERSION}.linux-amd64.tar.gz
sudo mv redis_exporter /usr/local/bin/

sudo tee /etc/systemd/system/redis_exporter.service <<'EOF'
[Unit]
Description=Prometheus redis_exporter
After=network.target redis.service

[Service]
User=nobody
Environment=REDIS_ADDR=redis://localhost:6379
ExecStart=/usr/local/bin/redis_exporter
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now redis_exporter
# Verify: curl http://localhost:9121/metrics | head
```

> If Redis requires a password, add `Environment=REDIS_PASSWORD=yourpassword` to the unit file.

### 3. Run the prometheus_exporter server

Mastodon's Rails and Sidekiq processes push metrics to a single collector process. Standalone mode is required in production so only one port is exposed.

```bash
sudo tee /etc/systemd/system/mastodon-prometheus-exporter.service <<EOF
[Unit]
Description=Mastodon prometheus_exporter collector
After=network.target

[Service]
Type=simple
User=mastodon
WorkingDirectory=/home/mastodon/live
Environment=RAILS_ENV=production
ExecStart=/home/mastodon/.rbenv/shims/bundle exec prometheus_exporter \\
  --bind 0.0.0.0 --port 9394 \\
  --type-collector lib/mastodon/prometheus_exporter/custom_feeds_collector.rb
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now mastodon-prometheus-exporter
# Verify: curl http://localhost:9394/metrics | grep custom_feed
```

### 4. Enable prometheus_exporter in Rails and Sidekiq

Add to `/home/mastodon/live/.env.production`:

```env
MASTODON_PROMETHEUS_EXPORTER_ENABLED=true
# Do NOT set MASTODON_PROMETHEUS_EXPORTER_LOCAL=true in production
# (starts an embedded server inside each process, conflicting on port)

# Optional: detailed per-action/controller HTTP metrics (some overhead)
# MASTODON_PROMETHEUS_EXPORTER_WEB_DETAILED_METRICS=true

# Optional: detailed per-job Sidekiq metrics
# MASTODON_PROMETHEUS_EXPORTER_SIDEKIQ_DETAILED_METRICS=true
```

Restart Puma and Sidekiq after changing `.env.production`:

```bash
sudo systemctl restart mastodon-web mastodon-sidekiq
```

### 5. Open firewall ports from antypdet-gaming

| Port | Service                                       |
| ---- | --------------------------------------------- |
| 9394 | prometheus_exporter (Rails + Sidekiq metrics) |
| 9100 | node_exporter (system CPU/mem/disk)           |
| 9121 | redis_exporter (Redis metrics)                |
| 4000 | Mastodon streaming /metrics                   |

If using `ufw`:

```bash
sudo ufw allow from <antypdet-gaming-ip> to any port 9394,9100,9121
# Port 4000 may already be open for WebSocket clients
```

If using Tailscale, no firewall changes needed.

---

## Local monitoring stack

On **antypdet-gaming** (Windows, in the repository directory):

```powershell
docker compose -f monitoring/docker-compose.yml up -d

# Verify Prometheus can reach the server:
# Open http://localhost:9090/targets — all targets should show State=UP

# Grafana: http://localhost:3001  (admin / admin)
# Dashboard: "Custom Feeds — Performance Impact" is auto-provisioned
```

To stop:

```powershell
docker compose -f monitoring/docker-compose.yml down
```

Data persists in named volumes (`prometheus_data`, `grafana_data`).
To wipe and start fresh: add `--volumes` to the `down` command.

---

## Baseline measurement procedure

1. **Deploy** the stack; verify all targets are UP in Prometheus.
2. **Baseline (home feeds only)**: disable all custom feed configs (`UPDATE custom_feed_configs SET enabled = false`), run ≥ 24 h. Record average CPU %, `sidekiq_job_duration_seconds` p95 for `FeedInsertWorker`, and Redis memory used.
3. **Standard custom feeds**: re-enable standard (non-algorithmic) configs. Run 24 h. Record delta.
4. **Algorithmic feeds**: enable algorithmic configs. Run 24 h. Record delta.
5. **Extrapolation**: `marginal_cpu_per_feed = delta_cpu_pct / num_active_custom_feeds`. Scale: `projected_cpu = baseline_cpu + (marginal_cpu_per_feed × N × feeds_per_user)`.

The `dev:seed_custom_feeds` rake task can be used to create reproducible test loads in the dev container.

---

## Metric reference

| Metric                                | Type      | Labels                            | Source                                   |
| ------------------------------------- | --------- | --------------------------------- | ---------------------------------------- |
| `custom_feed_inserts_total`           | counter   | `feed_type`, `result`             | FeedInsertWorker, PullSourceIngestWorker |
| `custom_feed_algo_candidates_total`   | counter   | `result`                          | AlgorithmicFeedWorker                    |
| `recommendation_signal_records_total` | counter   | `signal_type`, `interaction_type` | SignalWorker                             |
| `custom_feed_redis_memory_bytes`      | gauge     | `feed_type`                       | StatsCollectorWorker (5 min)             |
| `custom_feed_redis_feed_count`        | gauge     | `feed_type`                       | StatsCollectorWorker (5 min)             |
| `custom_feed_pg_table_bytes`          | gauge     | `table_name`                      | StatsCollectorWorker (5 min)             |
| `sidekiq_job_duration_seconds`        | histogram | `job_class`                       | prometheus_exporter (built-in Sidekiq)   |
| `ruby_process_rss_bytes`              | gauge     | `type`                            | prometheus_exporter (built-in Process)   |
| `redis_memory_used_bytes`             | gauge     | —                                 | redis_exporter                           |
| `node_cpu_seconds_total`              | counter   | `mode`                            | node_exporter                            |
