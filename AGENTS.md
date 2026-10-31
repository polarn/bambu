# Agents Guide for bambu

## Project overview

Bambu Lab cloud tooling in Go, split out of `polarn/waybar-modules` in October 2026 with its history. Two programs of different shapes:

| Program | Shape | What it does |
|---|---|---|
| `cmd/bambu-ctl` | CLI, one-shot | `login`/`status`/`waybar`/`pause`/`resume`/`toggle`/`stop`/`speed`/`light`. The `waybar` subcommand prints a single pill line; waybar runs it with `"interval"`, not as a daemon. |
| `cmd/bambu-exporter` | Service | Holds one cloud MQTT subscription open; serves Prometheus metrics, a JSON state endpoint and a status page. Deployed to Kubernetes via the flux `bambu-exporter` app. |

Packages:

- `pkg/bambu/` - Bambu cloud client: HTTP login flow, session cache, hand-rolled minimal MQTT 3.1.1 (no client library), plus the persistent subscription and report accumulator the exporter needs
- `pkg/waybar/` - The `Waybar` struct with JSON output and `Print()`. A copy of the one in waybar-modules (30 lines); copying it beat a cross-module dependency on `@latest` that lags behind the proxy.

## Where it is wired up

- chezmoi (`~/.local/share/chezmoi`): `dot_config/waybar/modules/p2s.jsonc` runs `dot_local/bin/executable_waybar-p2s.sh`, which execs `bambu-ctl waybar`; `run_onchange_install-waybar-modules.sh` has the `go install github.com/polarn/bambu/cmd/bambu-ctl@latest` line; pill colours are in `dot_config/waybar/style.css` keyed `#custom-p2s.<class>`.
- `polarn/container-images/bambu-exporter/Dockerfile` builds the exporter from a pinned `SRC_REF` of this repo. Shipping a change means bumping that SHA and re-pinning the resulting digest in `polarn/flux` (`apps/microk8s/bambu-exporter`).

## Building

- `make build` compiles `bambu-ctl` to `./build/`; `make install` copies it to `~/.local/bin/`.
- `bambu-exporter` is deliberately not in `make build`: it is a server and belongs in the container image, not `~/.local/bin`. Build it locally with `go build ./cmd/bambu-exporter`.

## Conventions

- **No external dependencies beyond what's in `go.mod`**: `golang.org/x/term` for the password prompt and nothing else direct. This is a real constraint, not an aspiration — it is why the MQTT framing in `pkg/bambu` and the Prometheus exposition format in `cmd/bambu-exporter` are both hand-rolled rather than pulling in a client library. Both formats are small and stable; the libraries would each be larger than the code using them.
- Flags use the standard `flag` package. `bambu-ctl` dispatches on `os.Args[1]` with a `flag.NewFlagSet` per subcommand.
- The `waybar` subcommand must **always exit 0 and print exactly one JSON line**, even on failure — a bad exit or stray output blanks or breaks the pill. Errors go to stderr (waybar forwards them to the journal) and surface as a pill `class` instead.
- Long-lived credentials live under `~/.config/`, mode 0600, and are never committed.
- `cmd/bambu-exporter` splits files by concern (main / metrics / task / jobwatch, plus an embedded `index.html`) because it is several separable concerns; `bambu-ctl` is one file.
- A metric or a field is emitted only when the upstream actually reported it. Publishing a zero for an absent value is how `chamber_temper` silently graphed 0 °C for months.

## bambu-ctl details

### Why cloud, not local

Bambu's P2S-generation printers only serve local MQTT when LAN-only mode + Developer Mode are enabled (which kills the Handy app / MakerWorld cloud features). `bambu-ctl` therefore reads state from Bambu's cloud broker (`us.mqtt.bambulab.com:8883`) with the account's access token — the same channel Handy uses — so the printer stays in Cloud mode.

### Auth flow

`bambu-ctl login`: POST `/v1/user-service/user/login` on `api.bambulab.com` with OrcaSlicer-mimicking headers (Bambu's risk control rejects unknown clients). Response may demand an emailed code (`loginType: verifyCode` → `/user/sendemail/code`) or 2FA (`loginType: tfa` → `/user/tfa/login`, token in the `token` cookie). The JWT's `username` claim (`u_<uid>`) is the MQTT username; the token itself is the password. Session cached in `~/.config/bambu-cloud.json` (0600), expires ~3 months → the pill's `reauth` class.

Google/Apple SSO accounts have no API-usable password and the API login rejects them entirely; `login --token` covers those by pasting the `token` cookie from a browser session on makerworld.com / bambulab.com (it's the same cloud access token). Alternative: set a password on the account via Handy/web, then normal login works.

### Status fetch

Subscribe `device/<serial>/report`, publish `{"pushing":{"command":"pushall"}}` to `device/<serial>/request`, take the first report containing `mc_percent` (partial pushes lack it). The printer rate-limits pushall (~1/min) — the waybar module polls at 120 s for headroom. Report fields mix numbers and numeric strings across firmwares; `pkg/bambu.Num` tolerates both.

Chamber temperature moved between generations: P2S-gen firmware has no flat `print.chamber_temper` (X1-era) and reports it at `print.device.ctc.info.temp` instead. `Report.ChamberTemp()` prefers the ctc path, falls back to the flat field, and returns false when neither exists so the tooltip omits the line rather than showing a fake 0 °C — don't "simplify" either branch away. Sibling `device.*` temps pack `(target << 16) | current` (`device.bed.info.temp` 0x4b004b = 75/75), hence the low-16-bit mask; the chamber has no target today so it reads as a bare int.

### Pill states

`printing` (green, `% + min left`) / `paused` / `failed` / `idle` (nozzle °C) / `offline` (dim, printer off) / `setup`+`reauth` (mauve, login needed) / `error`. CSS classes live in the chezmoi waybar style.css.

### Control commands

`pause`/`resume`/`stop`/`speed`/`light` publish to `device/<serial>/request` (payloads per OpenBambuAPI mqtt.md: `print.command` = pause/resume/stop/print_speed with param "1"-"4"; `system.command` = ledctrl for chamber_light) and wait for the echoed `result` on the report topic — `SendCommand` in pkg/bambu matches on section+command, treats a non-"success" result as an error, and returns `ErrNoAck` on timeout (printer off). `stop` prompts for confirmation unless `--yes`. AMS drying has no documented MQTT command (start it from the touchscreen/Handy).

## bambu-exporter details

### One-shot fetch vs held-open subscription

`FetchReport` asks for a `pushall` per call, and the printer rate-limits those to ~1/min — that is the only reason the waybar module polls at 120 s. `Subscribe` (pkg/bambu/stream.go) holds one connection open instead and consumes the unsolicited `push_status` deltas, which arrive every 1–2 s. Anything that needs data more often than once a minute must go through `Subscribe`, not `FetchReport`.

Those deltas carry only changed fields, so `State` (pkg/bambu/state.go) merges each message over the accumulated object; keeping just the newest message would make most fields absent, which renders as zero. The merge runs on decoded JSON rather than `Report` values so unmodelled fields survive — the same blind spot that hid `chamber_temper` moving to `device.ctc`. Nested objects merge key-by-key; arrays replace wholesale, because the printer resends a whole list (the AMS trays) when any of it changes.

Connection details that are easy to get wrong: `dial` leaves a whole-connection deadline set for its short exchange, so a persistent session must clear it or the first keepalive write fails; CONNECT advertises a 30 s keepalive, so `Subscribe` sends PINGREQ every 20 s with a rolling read deadline (90 s of silence means the session went deaf while the socket still looks open); and the reconnect backoff resets only after a connection survives 5 minutes.

### Metrics

Prometheus text is hand-rolled in `cmd/bambu-exporter/metrics.go` — client_golang would pull protobuf and a half-dozen transitive modules into a repo whose `go.sum` is four lines. Validate changes with `podman run --rm -i --entrypoint promtool docker.io/prom/prometheus:latest check metrics < metrics.txt`; it catches reserved suffixes (`_total` is counters-only — hence `bambulab_print_layers`) and non-base units (hence nozzle diameter living on `bambulab_nozzle_info` as a label rather than being named in millimetres).

Naming follows `bambulab_*` with base-unit suffixes and a `printer_name` label, close to Grafana dashboard 25033 so it is a usable starting point — but not identical, see the layers note above. **A metric is emitted only when the printer reported the field**: absent must not become a confident zero. Keep the printer serial out of labels; it is credential-adjacent and would end up in dashboard screenshots.

**Never name a label `job`** — or `instance`, `pod`, `namespace`, `container`, `endpoint`, `service`. The kube-prometheus-stack scrape attaches its own, and Prometheus silently renames the colliding one to `exported_<name>`. `bambulab_print_job_info` shipped with a `job` label and the dashboard's `{{job}}` rendered "bambu-exporter" instead of the print name for months. It is `title` now.

Two other own-goals promtool will not always catch: two samples of one family with an *identical* label set is a scrape error, so anything derived from a repeated array (`hms`, `lights_report`) needs deduplicating; and a family whose samples carry different label *keys* is merely bad form, but an empty label value is indistinguishable from an absent label in Prometheus, so conditionally-present labels are best emitted as `""`.

`bambulab_prints_total` and `bambulab_filament_grams_total` are the only counters, and the only state the exporter holds — see `jobwatch.go`. They are in-process and unpersisted on purpose: a volume would cost the container its `readOnlyRootFilesystem`, and a counter reset is something Prometheus already models. Query them with `increase()`.

### Token expiry

Renewal is interactive, so an unattended deployment breaks about quarterly. `bambulab_cloud_auth_ok` goes to 0 when the cloud rejects the token and the process keeps serving rather than crash-looping (a crash loop would hide the reason, and retrying in-process cannot help — the token is baked into the environment until the pod restarts). `TokenExpiry()` reads the JWT `exp` claim, but **not every token is a JWT**: the emailed-code login flow mints opaque ones, and this printer's account has one, so `bambulab_cloud_token_age_seconds` is the portable early warning.
