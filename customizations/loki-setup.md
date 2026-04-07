# Grafana Log Search Setup (Promtail on server → Loki local)

Grafana, Loki, Prometheus, and Pushgateway all run **locally** on your dev machine.
Promtail runs **on the server** and pushes logs to your local Loki over the network.

Logs are retained for **7 days**.

---

## Architecture

```
Server                        Local machine
──────────────────────        ──────────────────────
Mastodon (journald/files)
  └─ Promtail  ──────────────────────→  Loki :3100
                                         └─ Grafana :3001
```

---

## 1. Make local Loki reachable from the server

Loki listens on port **3100** on your local machine. The server needs to be able to reach it.

Find your local machine's IP that the server can route to:

```bash
# On your local machine
ipconfig   # look for your LAN or VPN IP
```

Ensure port 3100 is not blocked by your local firewall. On Windows Defender Firewall, add an inbound rule for TCP 3100 if needed.

Test reachability from the server:

```bash
curl http://<your-local-ip>:3100/ready
# Should return: ready
```

---

## 2. Find where Mastodon writes logs on the server

```bash
# Check for log files
ls -lh /home/mastodon/live/log/

# Check if logs go to journald
journalctl -u mastodon-web --no-pager -n 5
```

---

## 3. Install Promtail on the server

Download the same version used locally (3.1.0):

```bash
curl -Lo /tmp/promtail.zip \
  https://github.com/grafana/loki/releases/download/v3.1.0/promtail-linux-amd64.zip
cd /tmp && unzip promtail.zip
sudo mv promtail-linux-amd64 /usr/local/bin/promtail
sudo chmod +x /usr/local/bin/promtail
```

Or run it as a Docker container — see step 5 for the Docker variant.

---

## 4. Create the Promtail config on the server

Create `/etc/promtail/promtail.yml` — choose the block that matches how Mastodon logs on your server.

**If logs go to the systemd journal:**

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://<your-local-ip>:3100/loki/api/v1/push

scrape_configs:
  - job_name: mastodon_systemd
    journal:
      max_age: 168h
      labels:
        job: mastodon
        service: systemd
    relabel_configs:
      - source_labels: [__journal__systemd_unit]
        target_label: unit
      - source_labels: [__journal__systemd_unit]
        regex: mastodon-.+\.service
        action: keep
```

**If logs go to files** (e.g. `/home/mastodon/live/log/`):

```yaml
server:
  http_listen_port: 9080
  grpc_listen_port: 0

positions:
  filename: /tmp/positions.yaml

clients:
  - url: http://<your-local-ip>:3100/loki/api/v1/push

scrape_configs:
  - job_name: mastodon_rails
    static_configs:
      - targets:
          - localhost
        labels:
          job: mastodon
          service: rails
          __path__: /home/mastodon/live/log/production.log

  - job_name: mastodon_sidekiq
    static_configs:
      - targets:
          - localhost
        labels:
          job: mastodon
          service: sidekiq
          __path__: /home/mastodon/live/log/sidekiq.log
```

Replace `<your-local-ip>` with your actual IP from step 1.

---

## 5. Run Promtail

**As a systemd service (recommended):**

Create `/etc/systemd/system/promtail.service`:

```ini
[Unit]
Description=Promtail log shipper
After=network.target

[Service]
ExecStart=/usr/local/bin/promtail -config.file=/etc/promtail/promtail.yml
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now promtail
sudo systemctl status promtail
```

**As Docker (journal access requires host networking):**

```bash
docker run -d \
  --name promtail \
  --restart unless-stopped \
  --network host \
  -v /etc/promtail:/etc/promtail:ro \
  -v /var/log/journal:/var/log/journal:ro \
  -v /etc/machine-id:/etc/machine-id:ro \
  grafana/promtail:3.1.0 \
  -config.file=/etc/promtail/promtail.yml
```

Use `--network host` so it can reach your local machine via the LAN IP and read the journal socket.

---

## 6. Verify logs appear in Grafana

1. Open Grafana → **Explore** → switch datasource to **Loki**
2. Run:

```logql
{job="mastodon"}
```

You should see log lines within a few seconds of Promtail starting.

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
