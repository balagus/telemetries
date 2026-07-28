# Running the stack without Docker

Every component of this stack ships as a **self-contained static binary**.
Nothing here needs Docker, a container runtime, or a container registry —
which makes this the path to take when your organisation only permits
images from an internal registry that lags upstream.

```bash
cd bare-metal
./install.sh          # fetch the binaries into bare-metal/bin/
./stack.sh up         # start everything
./stack.sh verify     # prove telemetry flows end to end
```

Then open Grafana at <http://127.0.0.1:3000> (admin/admin).

Applications point at the collector exactly as they do under Compose — the
app-facing contract is unchanged:

```bash
export OTEL_SERVICE_NAME=my-service
export OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317
```

## What you get

| Command | Does |
|---|---|
| `./install.sh [component...]` | Download pinned binaries into `bin/` |
| `./install.sh --list` | Show versions and download URLs, fetch nothing |
| `./stack.sh up [component...]` | Start, waiting for each to report ready |
| `./stack.sh down` | Stop, in reverse dependency order |
| `./stack.sh status` | Per-component state, PID and health |
| `./stack.sh logs <c> [-f]` | Tail one component's log |
| `./stack.sh verify` | Push OTLP through Alloy, read it back from all three backends |
| `./stack.sh check-config` | Confirm every config variable is supplied by both launchers |
| `./stack.sh wipe` | Stop and delete all stored telemetry (keeps binaries) |
| `./stack.sh systemd-env` | Print an `EnvironmentFile` for the systemd units |

Binaries land in `bin/`, data in `data/`, logs in `logs/`, PIDs in `run/` —
all gitignored, all removable.

## Requirements

- Linux or macOS, x86-64 or arm64. On Windows use WSL2.
- `bash`, `curl` (or `wget`), `tar`, `unzip`.
- `python3` for `./stack.sh verify` and `check-config` only — standard
  library, nothing to pip install.
- ~1.5 GB of disk for the binaries. Grafana is most of that; the four Go
  binaries are ~250 MB together.

No root, no daemon, no system packages.

## Configuration

Settings live in [`defaults.sh`](defaults.sh) — one annotated list of every
port, path and storage option. To change something, copy the template and
override only what you need:

```bash
cp env.example.sh env.sh
$EDITOR env.sh
```

`env.sh` is gitignored and is read before the defaults, so your settings win
and you never conflict with an upstream change to `defaults.sh`.

The same variables drive `docker-compose.yml`, so **`config/` is shared
between both ways of running the stack** — there is no second copy of the
Loki, Tempo, Mimir, Alloy or Grafana configuration to keep in sync.

The config files use plain `${VAR}` with no defaults, because Mimir's
expansion does not support `${VAR:-default}` — it produces an empty string
instead. An unset variable therefore fails quietly, usually as a backend that
starts fine and then refuses writes. After adding a setting to any config
file, run:

```bash
./stack.sh check-config
```

It collects every `${VAR}` and `sys.env("VAR")` reference under `config/` and
verifies both `defaults.sh` and `docker-compose.yml` supply it. Docker is
optional — the Compose half is skipped with a note if the CLI is absent.

### Storage: filesystem or S3

`STORAGE_BACKEND` picks where Loki, Tempo and Mimir persist data.

**`filesystem`** (the default) writes everything under `data/`. There is no
object store to run, which is what makes the Docker-free path simple. Good
for a workstation or a single-box deployment.

**`s3`** points the backends at S3-compatible object storage you already
have. Cheap long-term retention is the whole reason the upstream design uses
object storage, so prefer this for anything longer-lived than a laptop:

```bash
# env.sh
export STORAGE_BACKEND=s3
export S3_ENDPOINT=objectstore.internal.example.com:9000   # host:port
export S3_URL=https://objectstore.internal.example.com:9000
export S3_INSECURE=false
export S3_ACCESS_KEY=...
export S3_SECRET_KEY="$(cat /etc/telemetry/s3-secret)"
```

The five buckets (`loki-data`, `tempo-data`, `mimir-blocks`, `mimir-ruler`,
`mimir-alertmanager`) must already exist — nothing here creates them. Under
Compose the `minio-init` job does that; without Docker it is on you.

Switching backends does not migrate existing data. Historical telemetry
stays where it was written.

### Ports

Compose gives each backend its own network namespace, so several of them can
happily share a port number. On a single host they cannot, so three ports
move off their upstream defaults:

| | Compose | Bare metal | Why |
|---|---|---|---|
| Tempo OTLP gRPC | 4317 | **4319** | 4317 is Alloy's, where apps connect |
| Tempo OTLP HTTP | 4318 | **4320** | 4318 is Alloy's |
| Mimir gRPC | 9095 | **9195** | 9095 is Tempo's |

Everything an application touches — 4317, 4318, 12347 — is unchanged.
Nothing connects to Tempo's OTLP ports directly; only Alloy does, and it is
told where to find them.

Backends bind to `127.0.0.1` by default. Set `BIND_ADDR=0.0.0.0` only if
apps on other hosts need to reach the collector, and read
[`../docs/best-practices.md`](../docs/best-practices.md) on authentication
first — none of these components require a credential by default.

### Rings

Loki, Tempo and Mimir are distributed systems running here as one process
each, so the bare-metal install pins their rings to loopback
(`LOKI_INSTANCE_ADDR`, `MIMIR_INSTANCE_ADDR`) and keeps them in memory
(`MIMIR_RING_STORE=inmemory`).

Left to auto-detect, each process picks an address from the default route's
interface, which on a multi-homed host is often not an address it can reach
*itself* on — the symptom is a healthy-looking process logging
`error reading server preface: http2: frame too large` and refusing writes.
Compose keeps auto-detection, because a container's IP is unambiguous.

## Installing behind a corporate network

`install.sh` fetches from `github.com` and `dl.grafana.com`. If neither is
reachable, either mirror them or stage the files yourself.

**Internal mirror** (Artifactory, Nexus, or any web server that preserves
the upstream paths):

```bash
export GITHUB_BASE_URL=https://artifacts.example.com/github-remote
export GRAFANA_BASE_URL=https://artifacts.example.com/grafana-remote
./install.sh
```

**Air-gapped.** Run `./install.sh --list` on a machine with access to see
the exact URLs and filenames, download them, copy them across, then:

```bash
export OFFLINE_DIR=/mnt/share/telemetry-binaries
./install.sh
```

Filenames must match what `--list` prints. Nothing is downloaded when a
matching file is found.

### Verifying downloads

[`checksums.txt`](checksums.txt) holds SHA-256 sums for the release archives.
When an entry matches the file being installed the check is enforced and a
mismatch aborts the install; when your platform is not listed you get a
warning and the install continues. Add your own entry once you have checked
a download against the upstream release page:

```bash
sha256sum <archive> >> checksums.txt
```

Only sums that have actually been verified are committed, so the file is not
a complete matrix.

## Running under systemd

`stack.sh` is deliberately minimal — background processes and PID files,
fine for a workstation. For a server, use the units in
[`systemd/`](systemd/), which add restart-on-failure, ordering, and
filesystem confinement.

The layout the units expect:

| Path | Contents |
|---|---|
| `/opt/telemetry/bin` | the binaries from `install.sh` |
| `/opt/telemetry/config` | this repository's `config/` directory |
| `/var/lib/telemetry` | data (matches `ReadWritePaths` in the units) |
| `/etc/telemetry/telemetry.env` | generated settings |

```bash
sudo useradd --system --no-create-home --shell /usr/sbin/nologin telemetry
sudo mkdir -p /opt/telemetry /var/lib/telemetry /var/log/telemetry /etc/telemetry

sudo cp -r bin /opt/telemetry/
sudo cp -r ../config /opt/telemetry/
./stack.sh systemd-env | sudo tee /etc/telemetry/telemetry.env >/dev/null

sudo chown -R telemetry:telemetry /var/lib/telemetry /var/log/telemetry
sudo chmod 640 /etc/telemetry/telemetry.env
sudo chown root:telemetry /etc/telemetry/telemetry.env   # it holds S3 credentials

sudo cp systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now loki mimir tempo alloy grafana
```

Regenerate `telemetry.env` and `systemctl restart` after changing `env.sh`.
`ReadWritePaths` in the units is a literal path — systemd does not expand
variables there — so if you move `DATA_ROOT`, edit the units to match.

## Upgrading

Version numbers live in `defaults.sh` and match the image tags in
`docker-compose.yml`. To move to a new release, change the version, refresh
the checksums, and reinstall:

```bash
$EDITOR defaults.sh          # bump LOKI_VERSION, TEMPO_VERSION, ...
./stack.sh down
./install.sh
./stack.sh up && ./stack.sh verify
```

Read the upstream release notes first — Loki and Mimir occasionally require a
schema or config migration, and this is the same upgrade you would be doing
with containers.

## Troubleshooting

**A component will not start.** `./stack.sh up` prints the tail of the log
of whatever failed. For more, `./stack.sh logs <component>`.

**`address already in use`.** Something else holds one of the ports. Find it
with `ss -ltnp | grep <port>` and override the port in `env.sh`.

**`http2: frame too large` in the logs.** A ring is advertising an address
the process cannot reach itself on. See [Rings](#rings) — normally this means
`LOKI_INSTANCE_ADDR` / `MIMIR_INSTANCE_ADDR` are not set.

**Grafana shows no data.** Confirm the pipeline first with
`./stack.sh verify`. If that passes, the ingest path is fine and the problem
is in the dashboard or the datasource, not the stack.

**Everything is running but queries are empty.** Loki and Mimir only flush to
storage periodically; freshly written data is served from memory. Give it a
minute, and check the time range in Grafana.

**Start over.** `./stack.sh wipe` stops everything and deletes `data/`,
keeping the binaries.
