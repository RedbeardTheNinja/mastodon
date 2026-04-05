# Custom Feeds Monitoring

Measures the performance impact of custom/algorithmic feeds vs. the home feed baseline.
Provides CPU, memory, and disk metrics to support extrapolation of per-user scaling cost.

## Architecture

```
antypdet-server (production)           antypdet-gaming (local Windows)
─────────────────────────────          ──────────────────────────────────────
  Rails / Puma                           docker-compose -f monitoring/docker-compose.yml
  Sidekiq                    scrape ──►  Prometheus  :9090
  prometheus_exporter :9394             Grafana     :3001  (login admin/admin)
  node_exporter       :9100             Pushgateway :9091  (optional, ad-hoc use)
  redis_exporter      :9121
  Mastodon streaming  :4000/metrics
```

Prometheus on `antypdet-gaming` scrapes three endpoints on `antypdet-server` every 15 s.
No metrics are pushed — Prometheus pulls. Hostname resolution depends on the two machines
being on the same network (LAN or Tailscale).

## Production server setup

All steps run on **antypdet-server** as the `mastodon` user (or with sudo where noted).

### 1. Install node_exporter

```bash
# Download (check https://github.com/prometheus/node_exporter/releases for latest)
VERSION=1.8.2
wget https://github.com/prometheus/node_exporter/releases/download/v${VERSION}/node_exporter-${VERSION}.linux-amd64.tar.gz
tar xf node_exporter-${VERSION}.linux-amd64.tar.gz
sudo mv node_exporter-${VERSION}.linux-amd64/node_exporter /usr/local/bin/

# Create systemd unit
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

### 3. Run the prometheus_exporter server (standalone mode)

Mastodon's Rails and Sidekiq processes push metrics to a single collector process.
This is preferable to LOCAL mode in production because only one port is needed.

```bash
# In /home/mastodon/live
bundle exec prometheus_exporter \
  --bind 0.0.0.0 \
  --port 9394 \
  --type-collector lib/mastodon/prometheus_exporter/custom_feeds_collector.rb \
  >> log/prometheus_exporter.log 2>&1 &
```

As a systemd unit (recommended):

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
# prometheus_exporter — points at the standalone collector above
MASTODON_PROMETHEUS_EXPORTER_ENABLED=true
# Do NOT set MASTODON_PROMETHEUS_EXPORTER_LOCAL=true in production
# (that starts an embedded server inside each process, conflicting on port)

# Optional: detailed per-action/controller HTTP metrics (some overhead)
# MASTODON_PROMETHEUS_EXPORTER_WEB_DETAILED_METRICS=true

# Optional: detailed per-job Sidekiq metrics
# MASTODON_PROMETHEUS_EXPORTER_SIDEKIQ_DETAILED_METRICS=true
```

Restart Puma and Sidekiq after changing `.env.production`:

```bash
sudo systemctl restart mastodon-web mastodon-sidekiq
```

Verify metrics are flowing:

```bash
# Custom feed metrics should appear (non-zero after some activity)
curl http://localhost:9394/metrics | grep custom_feed
```

### 5. Open firewall ports from antypdet-gaming

Prometheus on `antypdet-gaming` needs TCP access to:

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

If using Tailscale, no firewall changes needed — Tailscale handles routing.

---

## Local monitoring stack

On **antypdet-gaming** (Windows, in the repository directory):

```powershell
# Start the stack
docker compose -f monitoring/docker-compose.yml up -d

# Verify Prometheus can reach the server
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

Follow this procedure to isolate the marginal cost of custom feeds:

1. **Deploy** the monitoring stack and verify all targets are UP in Prometheus.
2. **Baseline (home feeds only)**: Disable all custom feed configs (`UPDATE custom_feed_configs SET enabled = false`), let the system run for ≥ 24 h. Record:
   - Average CPU % from panel "Server CPU usage %"
   - Average `sidekiq_job_duration_seconds` p95 for `FeedInsertWorker`
   - Redis memory used (total)
3. **Standard custom feeds**: Re-enable standard (non-algorithmic) configs. Run 24 h. Record delta.
4. **Algorithmic feeds**: Enable algorithmic configs. Run 24 h. Record delta.
5. **Extrapolation**: `marginal_cpu_per_feed = (delta_cpu_pct / num_active_custom_feeds)`.
   Scale: `projected_cpu_at_N_users = baseline_cpu + (marginal_cpu_per_feed × N × feeds_per_user)`.

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
