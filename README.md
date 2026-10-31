# bambu
Bambu Lab cloud tooling in Go: `bambu-ctl`, a CLI that also feeds a Waybar pill, and `bambu-exporter`, a Prometheus exporter that runs in Kubernetes. Both talk to Bambu's cloud MQTT broker with the account token, so the printer stays in normal Cloud mode. Split out of [waybar-modules](https://github.com/polarn/waybar-modules) in October 2026; see [AGENTS.md](AGENTS.md) for the conventions and the hard-won details.

`make` builds `bambu-ctl` into `build/`; `make install` copies it to `~/.local/bin`. `bambu-exporter` is built into `ghcr.io/polarn/bambu-exporter` by `.github/workflows/build.yml` on every push to `main` that touches it, or locally with `go build ./cmd/bambu-exporter`.

## bambu-ctl
A CLI for Bambu Lab's cloud that reports 3D-printer state (tested with a P2S). `bambu-ctl waybar` emits one JSON line for a Waybar custom module (run it with `"interval"`, not as a daemon) — progress + time left while printing, nozzle temperature otherwise, with the full report (temps, AMS humidity, loaded filament slots) in the tooltip.

The printer stays in normal Cloud mode — no LAN-only or Developer Mode needed. Status is read from Bambu's cloud MQTT broker with the account token, the same channel the Handy app uses. Talks MQTT 3.1.1 directly (no client library) since the exchange is a single subscribe + pushall.

Run `bambu-ctl login` once (email + password, or an emailed code / 2FA when Bambu asks); the token lands in `~/.config/bambu-cloud.json` and lasts about 3 months — the pill switches to a `reauth` class when a fresh `login` is needed. Accounts created with Google/Apple sign-in have no API password: either set one in the account settings, or run `bambu-ctl login --token` and paste the `token` cookie from a logged-in makerworld.com browser session. `bambu-ctl status` prints the same state human-readably (`--raw` for the full report JSON).

Control goes over the same channel: `bambu-ctl pause` / `resume` / `stop` (stop asks for confirmation, `--yes` skips), `bambu-ctl speed silent|standard|sport|ludicrous`, and `bambu-ctl light on|off` for the chamber light. Commands wait for the printer's acknowledgement on the report topic and report failures (e.g. `bambu-ctl resume` with nothing paused).

## bambu-exporter
A long-running companion to `bambu-ctl` that keeps one MQTT subscription open and serves what it hears, for Prometheus and for the pill.

It exists because the printer rate-limits `pushall` to roughly one a minute, so nothing can fetch per scrape — that limit is why the waybar module polls at 120 s. Holding the subscription open instead means the partial `push_status` messages the printer streams unprompted (measured: one every 1–2 s) become the data source, and any number of consumers can read as often as they like at no cost to the printer.

| Endpoint | Port | For |
|---|---|---|
| `/metrics` | `$BAMBU_METRICS_ADDR`, default `:9090` | Prometheus text, ~57 `bambulab_*` families (gauges plus two `_total` counters) |
| `/state` | `$BAMBU_HTTP_ADDR`, default `:8080` | the merged report as JSON, for `bambu-ctl waybar` |
| `/healthz` | `$BAMBU_HTTP_ADDR` | process liveness |

Two listeners so `/metrics` can stay cluster-internal while `/state` is reachable on the LAN. Config is environment-only (`BAMBU_SESSION_JSON` holds the contents of `~/.config/bambu-cloud.json`; it falls back to the file on disk for local runs), which suits a Kubernetes `envFrom: secretRef`.

Two behaviours worth knowing. A metric is only published when the printer actually reported the field, so a sensor this firmware doesn't have is absent rather than a confident zero. And `/healthz` deliberately ignores data freshness — a powered-off printer is not an unhealthy exporter, and tying them together would restart the pod every time the printer sleeps; use `bambulab_report_age_seconds` for that, which also catches a subscription that has gone deaf while the socket still looks open.

The cloud token lasts about three months and can only be renewed interactively, so `bambulab_cloud_auth_ok` drops to 0 when it is rejected and `bambulab_cloud_token_age_seconds` lets you warn ahead of time. (`bambulab_cloud_token_expiry_timestamp_seconds` is exported too, but only for JWT tokens — the emailed-code login flow mints opaque ones.)

### Filament

`bambulab_ams_tray_info` carries what is in each slot — material, product name, colour as `RRGGBBAA`, the Bambu filament code, and the spool's RFID uid. `bambulab_print_filament_info` is the one that says which of those is actually feeding the hotend, resolved from the AMS-global `tray_now`; the per-slot series cannot answer that on their own, which is what makes "which spool did that print use" answerable after the fact.

Grams remaining is deliberately not exported: it is `bambulab_ams_tray_weight_grams` times `bambulab_ams_tray_remaining_percent / 100`, and deriving one exported number from two others is PromQL's job.

Note the external spool is `print.vir_slot` on P2S-generation firmware. There is no `vt_tray` key at all — the field every guide names does not exist here.

### Counters

`bambulab_prints_total{result}` and `bambulab_filament_grams_total{type,name,color}` are the only things in the exporter that accumulate; everything else is rebuilt from the latest report on each scrape, which is what makes stale series disappear on their own. They live in the process and reset when it restarts, so **query them with `increase()`**, not by reading the raw total.

The grams come from the slicer's estimate in the cloud task history, which is the only place in the whole pipeline that has a filament weight — the MQTT report never gives one. A finished print therefore parks a pending credit and nudges the task poller, applying the weight once a task comes back whose title matches. Failed prints are counted but credited nothing (the estimate is for the whole plate), and a print drawing from more than one slot goes to `name="multi-material"` rather than being attributed to a spool it may not have used.

### Do not name a label `job`

kube-prometheus-stack's scrape attaches its own `job="bambu-exporter"`, so Prometheus renames any colliding label to `exported_job`. `bambulab_print_job_info` shipped with a `job` label and every dashboard asking for `{{job}}` rendered the scrape job instead of the print name, unnoticed for months. It is `title` now. The same applies to `instance`, `pod`, `namespace`, `container`, `endpoint` and `service`.
