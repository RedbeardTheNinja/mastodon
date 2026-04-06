# Grafana Log Search Setup (Loki + Promtail)

Loki and Promtail have been added to the monitoring docker-compose. This document covers what needs to be done **on the server** to enable log search in Grafana.

Logs are retained for **7 days**.

---

## 1. Find where Mastodon writes logs

Mastodon can log to files or to the systemd journal depending on how it is configured. Run both checks:

```bash
# Check for log files
ls -lh /home/mastodon/live/log/

# Check if logs go to journald
journalctl -u mastodon-web --no-pager -n 5
```

**If logs go to journald** (lines appear in the `journalctl` output), the promtail `journal` scrape will pick them up automatically — skip to step 2.

**If logs go to files** (e.g. `/home/mastodon/live/log/production.log`), update `monitoring/promtail/promtail.yml` with the correct paths before deploying:

```yaml
- job_name: mastodon_rails
  static_configs:
    - targets:
        - localhost
      labels:
        job: mastodon
        service: rails
        __path__: /home/mastodon/live/log/production.log # ← update this

- job_name: mastodon_sidekiq
  static_configs:
    - targets:
        - localhost
      labels:
        job: mastodon
        service: sidekiq
        __path__: /home/mastodon/live/log/sidekiq.log # ← update this
```

Also update the `volumes` mount in `docker-compose.yml` to point at the correct directory:

```yaml
promtail:
  volumes:
    - /home/mastodon/live/log:/var/log/mastodon:ro # ← adjust source path
```

---

## 2. Check systemd unit names

The promtail config filters the journal for units matching `mastodon-*.service`. Verify yours match:

```bash
systemctl list-units 'mastodon*' --no-pager
```

Common names are `mastodon-web.service`, `mastodon-sidekiq.service`, `mastodon-streaming.service`. If yours differ, update the `regex` in `promtail/promtail.yml`:

```yaml
- source_labels: [__journal__systemd_unit]
  regex: mastodon-.+\.service # ← adjust if your unit names differ
  action: keep
```

---

## 3. Give the promtail container access to the journal

The promtail container needs read access to the systemd journal socket. The docker-compose already mounts:

```yaml
- /run/log/journal:/run/log/journal:ro
- /etc/machine-id:/etc/machine-id:ro
```

Verify the journal directory exists on your server:

```bash
ls /run/log/journal/
```

If it is empty or missing, your system may use `/var/log/journal/` (persistent journal). Add that mount instead:

```yaml
- /var/log/journal:/var/log/journal:ro
```

---

## 4. Pull the latest code and restart the stack

```bash
cd /path/to/monitoring   # wherever docker-compose.yml lives
git pull
docker compose up -d
```

Check that Loki and Promtail started cleanly:

```bash
docker compose logs loki --tail=20
docker compose logs promtail --tail=20
```

Promtail should log lines like:

```
level=info msg="Tailing new file" path=/var/log/mastodon/production.log
```

or for journald:

```
level=info msg="Journal successfully opened"
```

---

## 5. Verify in Grafana

1. Open Grafana → **Explore**
2. Switch the datasource to **Loki**
3. Run a test query:

```logql
{job="mastodon"} | line_format "{{.message}}"
```

To search for specific errors:

```logql
{job="mastodon"} |= "ERROR"
{job="mastodon", service="sidekiq"} |= "SignalWorker"
{job="mastodon"} |= "CustomFeeds" |= "failed"
```

To filter to a time range, use the Grafana time picker in the top right.

---

## Useful LogQL patterns

| What you want       | Query                                                              |
| ------------------- | ------------------------------------------------------------------ |
| All errors          | `{job="mastodon"} \|= "ERROR"`                                     |
| Rails only          | `{job="mastodon", service="rails"} \|= "ERROR"`                    |
| Sidekiq only        | `{job="mastodon", service="sidekiq"}`                              |
| Specific worker     | `{job="mastodon"} \|= "SignalWorker"`                              |
| Custom feed errors  | `{job="mastodon"} \|= "CustomFeeds" \|= "failed"`                  |
| HTTP 5xx errors     | `{job="mastodon", service="rails"} \|= "HTTP/1" \|~ " 5[0-9]{2} "` |
| Last hour of errors | `{job="mastodon"} \|= "ERROR"` (set time picker to Last 1h)        |
