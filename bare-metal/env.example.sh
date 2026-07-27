#!/usr/bin/env bash
# Copy to env.sh and edit. Anything set here overrides bare-metal/defaults.sh,
# which is where the full list of settings and their defaults lives:
#
#     cp env.example.sh env.sh
#
# env.sh is gitignored, so your local settings never end up in a commit.
# Only override what you actually need — everything omitted keeps its default.

# --- Storage ----------------------------------------------------------------
# 'filesystem' (default) keeps everything under bare-metal/data — no object
# store required, which is the quickest way to get running.
#
# Switch to 's3' to use real object storage. That is what makes long retention
# affordable, so prefer it for anything longer-lived than a workstation.
#
# export STORAGE_BACKEND=s3
# export S3_ENDPOINT=objectstore.internal.example.com:9000   # host:port
# export S3_URL=https://objectstore.internal.example.com:9000
# export S3_INSECURE=false                                   # false for HTTPS
# export S3_ACCESS_KEY=...
# export S3_SECRET_KEY=...
#
# The buckets below must already exist — nothing here creates them.
# export LOKI_S3_BUCKET=loki-data
# export TEMPO_S3_BUCKET=tempo-data
# export MIMIR_BLOCKS_BUCKET=mimir-blocks
# export MIMIR_RULER_BUCKET=mimir-ruler
# export MIMIR_ALERTMANAGER_BUCKET=mimir-alertmanager

# Keep credentials out of this file where you can — it is easy to paste into a
# ticket by accident. Reading them from the environment or a secret store at
# start-up is better:
# export S3_SECRET_KEY="$(cat /etc/telemetry/s3-secret)"

# --- Where data lives -------------------------------------------------------
# Defaults to bare-metal/data. Point it at a volume with room to grow when
# you are keeping 90 days of logs.
# export DATA_ROOT=/var/lib/telemetry

# --- Network ----------------------------------------------------------------
# Backends bind to loopback by default. Set this to 0.0.0.0 only if apps on
# other hosts need to reach the collector directly — and put authentication
# or a firewall in front of it if you do (see docs/best-practices.md).
# export BIND_ADDR=0.0.0.0

# Ports, if the defaults collide with something already on the host.
# export GRAFANA_PORT=3000
# export ALLOY_OTLP_GRPC_PORT=4317
# export ALLOY_OTLP_HTTP_PORT=4318

# --- Grafana ----------------------------------------------------------------
# Change these before exposing Grafana to anyone else.
# export GRAFANA_ADMIN_USER=admin
# export GRAFANA_ADMIN_PASSWORD=admin

# --- Installing behind a corporate network ----------------------------------
# Point install.sh at an internal mirror instead of the public internet.
# export GITHUB_BASE_URL=https://artifacts.example.com/github-remote
# export GRAFANA_BASE_URL=https://artifacts.example.com/grafana-remote
#
# Or drop the release archives somewhere on disk and install from there:
# export OFFLINE_DIR=/mnt/share/telemetry-binaries
