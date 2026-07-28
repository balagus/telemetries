#!/usr/bin/env bash
# Canonical settings for the Docker-free install.
#
# Sourced by install.sh and stack.sh. Every value uses ${VAR:=default}, so
# anything already exported in your shell — or set in bare-metal/env.sh —
# wins. To change something, prefer editing env.sh (see env.example.sh)
# rather than this file, so upgrades stay conflict-free.
#
# The variables exported here are the same ones docker-compose.yml sets for
# the containerised stack; config/ is shared between the two.

# --- Layout -----------------------------------------------------------------
_bm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Your overrides, if any. Sourced before the defaults below so they win.
# shellcheck source=/dev/null
[ -f "${_bm_dir}/env.sh" ] && . "${_bm_dir}/env.sh"

: "${TELEMETRY_HOME:="$(cd "${_bm_dir}/.." && pwd)"}"
: "${BM_HOME:="${_bm_dir}"}"
: "${BIN_DIR:="${BM_HOME}/bin"}"
: "${DATA_ROOT:="${BM_HOME}/data"}"
: "${LOG_DIR:="${BM_HOME}/logs"}"
: "${RUN_DIR:="${BM_HOME}/run"}"
: "${CONFIG_DIR:="${TELEMETRY_HOME}/config"}"
# Seconds to wait for a component to shut down cleanly before SIGKILL.
# Matches TimeoutStopSec in the systemd units.
: "${STOP_TIMEOUT:=120}"

# --- Component versions (match docker-compose.yml image tags) ---------------
: "${LOKI_VERSION:=3.3.2}"
: "${TEMPO_VERSION:=2.7.0}"
: "${MIMIR_VERSION:=2.14.2}"
: "${ALLOY_VERSION:=1.6.1}"
: "${GRAFANA_VERSION:=11.4.0}"

# Where install.sh fetches release archives from. Point these at an internal
# mirror (Artifactory, Nexus, a plain web server) when the machine cannot
# reach the public internet — see README.md, "Air-gapped installs".
: "${GITHUB_BASE_URL:=https://github.com}"
: "${GRAFANA_BASE_URL:=https://dl.grafana.com}"
# Optional directory of pre-downloaded archives; install.sh uses a file from
# here instead of downloading when the name matches.
: "${OFFLINE_DIR:=}"

# --- Ports ------------------------------------------------------------------
# Interface the backends bind to. They are internal services: keep them on
# loopback unless something off-box genuinely needs to reach them. Defined
# first because several settings below derive from it.
: "${BIND_ADDR:=127.0.0.1}"

# Compose gives every backend its own network namespace, so several of them
# can share a port number. On one host they cannot, so Tempo's OTLP receivers
# and Mimir's gRPC port are moved off their upstream defaults below.
#
# Applications still talk to Alloy on the standard 4317/4318 — nothing about
# the app-facing contract changes.
: "${ALLOY_HTTP_PORT:=12345}"      # Alloy UI
: "${ALLOY_OTLP_GRPC_PORT:=4317}"  # apps -> Alloy
: "${ALLOY_OTLP_HTTP_PORT:=4318}"  # apps -> Alloy
: "${ALLOY_FARO_PORT:=12347}"      # browsers -> Alloy

: "${LOKI_HTTP_PORT:=3100}"
: "${LOKI_GRPC_PORT:=9096}"
# Pin the address each backend publishes in its own rings. Auto-detection
# picks the default route's interface, which on a multi-NIC host is often
# not an address the process can reach itself on.
: "${LOKI_INSTANCE_ADDR:=${BIND_ADDR}}"

: "${TEMPO_HTTP_PORT:=3200}"
: "${TEMPO_GRPC_PORT:=9095}"
: "${TEMPO_OTLP_GRPC_PORT:=4319}"  # moved: 4317 belongs to Alloy here
: "${TEMPO_OTLP_HTTP_PORT:=4320}"  # moved: 4318 belongs to Alloy here

: "${MIMIR_HTTP_PORT:=9009}"
: "${MIMIR_GRPC_PORT:=9195}"       # moved: 9095 belongs to Tempo here
: "${MIMIR_MEMBERLIST_PORT:=7946}"
# Single process, so the rings live in memory. memberlist would additionally
# need a private IP to advertise, which a bare host does not always have.
: "${MIMIR_RING_STORE:=inmemory}"
: "${MIMIR_ADVERTISE_ADDR:=${BIND_ADDR}}"
: "${MIMIR_INSTANCE_ADDR:=${BIND_ADDR}}"

: "${GRAFANA_PORT:=3000}"
: "${GRAFANA_ADMIN_USER:=admin}"
: "${GRAFANA_ADMIN_PASSWORD:=admin}"

# --- Storage ----------------------------------------------------------------
# filesystem : each backend writes to local disk under DATA_ROOT. No object
#              store needed — the simplest way to run without Docker.
# s3         : point the backends at an existing S3-compatible endpoint (your
#              company's object storage, or a MinIO you already run). This is
#              what makes cheap long-term retention work; prefer it for
#              anything beyond a workstation.
: "${STORAGE_BACKEND:=filesystem}"

: "${S3_ENDPOINT:=localhost:9000}"          # host:port, no scheme
: "${S3_URL:=http://${S3_ENDPOINT}}"        # same endpoint, with scheme
: "${S3_ACCESS_KEY:=telemetry}"
: "${S3_SECRET_KEY:=telemetry-secret}"
: "${S3_INSECURE:=true}"                    # false when the endpoint is HTTPS

: "${LOKI_S3_BUCKET:=loki-data}"
: "${TEMPO_S3_BUCKET:=tempo-data}"
: "${MIMIR_BLOCKS_BUCKET:=mimir-blocks}"
: "${MIMIR_RULER_BUCKET:=mimir-ruler}"
: "${MIMIR_ALERTMANAGER_BUCKET:=mimir-alertmanager}"

# Translate STORAGE_BACKEND into the per-backend spelling each config expects.
case "${STORAGE_BACKEND}" in
  filesystem)
    : "${LOKI_OBJECT_STORE:=filesystem}"
    : "${TEMPO_BACKEND:=local}"
    : "${MIMIR_BACKEND:=filesystem}"
    ;;
  s3)
    : "${LOKI_OBJECT_STORE:=s3}"
    : "${TEMPO_BACKEND:=s3}"
    : "${MIMIR_BACKEND:=s3}"
    ;;
  *)
    echo "defaults.sh: STORAGE_BACKEND must be 'filesystem' or 's3', got '${STORAGE_BACKEND}'" >&2
    return 1 2>/dev/null || exit 1
    ;;
esac

# --- Data directories -------------------------------------------------------
: "${LOKI_DATA:=${DATA_ROOT}/loki}"
: "${TEMPO_DATA:=${DATA_ROOT}/tempo}"
: "${MIMIR_DATA:=${DATA_ROOT}/mimir}"
: "${ALLOY_DATA:=${DATA_ROOT}/alloy}"
: "${GRAFANA_DATA:=${DATA_ROOT}/grafana}"

# --- Service addresses (how the components find each other) -----------------
: "${LOKI_URL:=http://${BIND_ADDR}:${LOKI_HTTP_PORT}}"
: "${TEMPO_URL:=http://${BIND_ADDR}:${TEMPO_HTTP_PORT}}"
: "${MIMIR_URL:=http://${BIND_ADDR}:${MIMIR_HTTP_PORT}}"
: "${TEMPO_OTLP_ENDPOINT:=${BIND_ADDR}:${TEMPO_OTLP_GRPC_PORT}}"

# --- Grafana paths ----------------------------------------------------------
: "${GF_DASHBOARDS_PATH:=${CONFIG_DIR}/grafana/dashboards}"

export TELEMETRY_HOME BM_HOME BIN_DIR DATA_ROOT LOG_DIR RUN_DIR CONFIG_DIR
export STOP_TIMEOUT
export LOKI_VERSION TEMPO_VERSION MIMIR_VERSION ALLOY_VERSION GRAFANA_VERSION
export GITHUB_BASE_URL GRAFANA_BASE_URL OFFLINE_DIR
export ALLOY_HTTP_PORT ALLOY_OTLP_GRPC_PORT ALLOY_OTLP_HTTP_PORT ALLOY_FARO_PORT
export LOKI_HTTP_PORT LOKI_GRPC_PORT LOKI_INSTANCE_ADDR
export TEMPO_HTTP_PORT TEMPO_GRPC_PORT TEMPO_OTLP_GRPC_PORT TEMPO_OTLP_HTTP_PORT
export MIMIR_HTTP_PORT MIMIR_GRPC_PORT MIMIR_MEMBERLIST_PORT
export MIMIR_RING_STORE MIMIR_ADVERTISE_ADDR MIMIR_INSTANCE_ADDR
export GRAFANA_PORT GRAFANA_ADMIN_USER GRAFANA_ADMIN_PASSWORD BIND_ADDR
export STORAGE_BACKEND S3_ENDPOINT S3_URL S3_ACCESS_KEY S3_SECRET_KEY S3_INSECURE
export LOKI_S3_BUCKET TEMPO_S3_BUCKET
export MIMIR_BLOCKS_BUCKET MIMIR_RULER_BUCKET MIMIR_ALERTMANAGER_BUCKET
export LOKI_OBJECT_STORE TEMPO_BACKEND MIMIR_BACKEND
export LOKI_DATA TEMPO_DATA MIMIR_DATA ALLOY_DATA GRAFANA_DATA
export LOKI_URL TEMPO_URL MIMIR_URL TEMPO_OTLP_ENDPOINT
export GF_DASHBOARDS_PATH
