#!/usr/bin/env bash
# Start, stop and inspect the stack without Docker.
#
#   ./stack.sh up [component...]     start (all components by default)
#   ./stack.sh down [component...]   stop
#   ./stack.sh restart [component...]
#   ./stack.sh status                what is running, and whether it is ready
#   ./stack.sh logs <component> [-f] tail a component's log
#   ./stack.sh verify                push test telemetry and read it back
#   ./stack.sh systemd-env           print an EnvironmentFile for the systemd units
#   ./stack.sh wipe                  stop everything and delete all stored data
#
# Processes are started in the background with their PIDs in run/ and their
# output in logs/. This is deliberately minimal: for a real server, use the
# systemd units in systemd/ instead (see README.md).
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=defaults.sh
. ./defaults.sh

# Start order matters: the storage backends must be accepting writes before
# Alloy starts forwarding to them, and Tempo remote-writes into Mimir.
COMPONENTS=(loki mimir tempo alloy grafana)

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

pid_file() { echo "${RUN_DIR}/$1.pid"; }
log_file() { echo "${LOG_DIR}/$1.log"; }

is_running() {
  local pf; pf="$(pid_file "$1")"
  [ -f "${pf}" ] || return 1
  kill -0 "$(cat "${pf}")" 2>/dev/null
}

# Health endpoint for each component, used by `status` and by `up` to wait
# until a backend is actually serving before starting the next one.
health_url() {
  case "$1" in
    loki)    echo "${LOKI_URL}/ready" ;;
    mimir)   echo "${MIMIR_URL}/ready" ;;
    tempo)   echo "${TEMPO_URL}/ready" ;;
    alloy)   echo "http://${BIND_ADDR}:${ALLOY_HTTP_PORT}/-/ready" ;;
    grafana) echo "http://${BIND_ADDR}:${GRAFANA_PORT}/api/health" ;;
  esac
}

command_for() {
  case "$1" in
    loki)
      echo "${BIN_DIR}/loki -config.file=${CONFIG_DIR}/loki/loki.yaml -config.expand-env=true" ;;
    tempo)
      echo "${BIN_DIR}/tempo -config.file=${CONFIG_DIR}/tempo/tempo.yaml -config.expand-env=true" ;;
    mimir)
      echo "${BIN_DIR}/mimir -config.file=${CONFIG_DIR}/mimir/mimir.yaml -config.expand-env=true" ;;
    alloy)
      echo "${BIN_DIR}/alloy run ${CONFIG_DIR}/alloy/config.alloy --server.http.listen-addr=${BIND_ADDR}:${ALLOY_HTTP_PORT} --storage.path=${ALLOY_DATA}" ;;
    grafana)
      echo "${BIN_DIR}/grafana server --homepath=${BIN_DIR}/grafana-home" ;;
  esac
}

prepare_dirs() {
  mkdir -p "${LOG_DIR}" "${RUN_DIR}" \
           "${LOKI_DATA}" "${TEMPO_DATA}" "${MIMIR_DATA}" \
           "${ALLOY_DATA}" "${GRAFANA_DATA}"
  # Loki's filesystem object store and Mimir's per-purpose dirs are not
  # created on demand by the binaries.
  mkdir -p "${LOKI_DATA}/chunks" "${LOKI_DATA}/index" "${LOKI_DATA}/index_cache" \
           "${LOKI_DATA}/compactor" \
           "${MIMIR_DATA}/blocks" "${MIMIR_DATA}/ruler" "${MIMIR_DATA}/alertmanager" \
           "${MIMIR_DATA}/tsdb" "${MIMIR_DATA}/tsdb-sync" "${MIMIR_DATA}/compactor"
}

# Grafana reads its settings from the environment rather than a generated
# grafana.ini, so nothing about the install has to be templated.
grafana_env() {
  export GF_PATHS_DATA="${GRAFANA_DATA}"
  export GF_PATHS_LOGS="${LOG_DIR}/grafana"
  export GF_PATHS_PLUGINS="${GRAFANA_DATA}/plugins"
  export GF_PATHS_PROVISIONING="${CONFIG_DIR}/grafana/provisioning"
  export GF_SERVER_HTTP_ADDR="${BIND_ADDR}"
  export GF_SERVER_HTTP_PORT="${GRAFANA_PORT}"
  export GF_SECURITY_ADMIN_USER="${GRAFANA_ADMIN_USER}"
  export GF_SECURITY_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD}"
  export GF_FEATURE_TOGGLES_ENABLE="traceqlEditor,exemplars"
  export GF_ANALYTICS_REPORTING_ENABLED=false
  mkdir -p "${GF_PATHS_LOGS}" "${GF_PATHS_PLUGINS}"
}

wait_ready() {
  local component="$1" url deadline
  url="$(health_url "${component}")"
  [ -n "${url}" ] || return 0
  deadline=$(( $(date +%s) + 90 ))
  while [ "$(date +%s)" -lt "${deadline}" ]; do
    if ! is_running "${component}"; then
      warn "${component} exited during startup — last lines of $(log_file "${component}"):"
      tail -20 "$(log_file "${component}")" >&2 || true
      return 1
    fi
    if curl -fsS -o /dev/null "${url}" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  warn "${component} did not become ready within 90s (still starting? see $(log_file "${component}"))"
  return 1
}

start_one() {
  local component="$1" cmd pf lf
  if is_running "${component}"; then
    info "${component} already running (pid $(cat "$(pid_file "${component}")"))"
    return 0
  fi
  # Return rather than die, so cmd_up still reports on whatever did start.
  if [ ! -x "${BIN_DIR}/${component}" ]; then
    warn "${component} is not installed — run ./install.sh ${component}"
    return 1
  fi

  cmd="$(command_for "${component}")"
  pf="$(pid_file "${component}")"; lf="$(log_file "${component}")"

  info "starting ${component}"
  if [ "${component}" = grafana ]; then
    ( grafana_env; exec ${cmd} ) >>"${lf}" 2>&1 &
  else
    ${cmd} >>"${lf}" 2>&1 &
  fi
  echo $! >"${pf}"

  wait_ready "${component}" || return 1
}

stop_one() {
  local component="$1" pf pid
  pf="$(pid_file "${component}")"
  if ! is_running "${component}"; then
    rm -f "${pf}"
    return 0
  fi
  pid="$(cat "${pf}")"
  info "stopping ${component} (pid ${pid})"
  kill "${pid}" 2>/dev/null || true
  # The storage backends flush open blocks and close their WAL on SIGTERM.
  # Cutting that short means replaying the WAL on the next start, so allow
  # the same grace period the systemd units use.
  for _ in $(seq 1 "${STOP_TIMEOUT}"); do
    kill -0 "${pid}" 2>/dev/null || break
    sleep 1
  done
  if kill -0 "${pid}" 2>/dev/null; then
    warn "${component} did not exit gracefully; sending SIGKILL"
    kill -9 "${pid}" 2>/dev/null || true
  fi
  rm -f "${pf}"
}

# --- Subcommands ------------------------------------------------------------
cmd_up() {
  local targets=("$@")
  [ ${#targets[@]} -gt 0 ] || targets=("${COMPONENTS[@]}")
  prepare_dirs

  info "storage backend: ${STORAGE_BACKEND}$([ "${STORAGE_BACKEND}" = s3 ] && echo " (${S3_URL})" || echo " (${DATA_ROOT})")"
  local failed=0
  for c in "${targets[@]}"; do
    start_one "${c}" || { failed=1; break; }
  done
  echo
  cmd_status
  if [ "${failed}" -ne 0 ]; then
    echo
    die "startup aborted — see the logs above"
  fi
  cat <<EOF

  Grafana        http://${BIND_ADDR}:${GRAFANA_PORT}  (${GRAFANA_ADMIN_USER}/${GRAFANA_ADMIN_PASSWORD})
  OTLP ingest    ${BIND_ADDR}:${ALLOY_OTLP_GRPC_PORT} (gRPC) / ${BIND_ADDR}:${ALLOY_OTLP_HTTP_PORT} (HTTP)
  Faro ingest    http://${BIND_ADDR}:${ALLOY_FARO_PORT}/collect
  Alloy UI       http://${BIND_ADDR}:${ALLOY_HTTP_PORT}

  Point an app at the stack with:
    export OTEL_SERVICE_NAME=my-service
    export OTEL_EXPORTER_OTLP_ENDPOINT=http://${BIND_ADDR}:${ALLOY_OTLP_GRPC_PORT}
EOF
}

cmd_down() {
  local targets=("$@")
  if [ ${#targets[@]} -eq 0 ]; then
    # Reverse of the start order.
    for (( i=${#COMPONENTS[@]}-1; i>=0; i-- )); do targets+=("${COMPONENTS[i]}"); done
  fi
  for c in "${targets[@]}"; do stop_one "${c}"; done
}

cmd_status() {
  printf '%-9s %-9s %-8s %s\n' COMPONENT STATE PID HEALTH
  for c in "${COMPONENTS[@]}"; do
    local state pid health url
    if is_running "${c}"; then
      state=running; pid="$(cat "$(pid_file "${c}")")"
      url="$(health_url "${c}")"
      if curl -fsS -o /dev/null "${url}" 2>/dev/null; then health=ready; else health='not ready'; fi
    else
      state=stopped; pid='-'; health='-'
    fi
    printf '%-9s %-9s %-8s %s\n' "${c}" "${state}" "${pid}" "${health}"
  done
}

cmd_logs() {
  local component="${1:-}"
  [ -n "${component}" ] || die "usage: ./stack.sh logs <component> [-f]"
  shift
  local lf; lf="$(log_file "${component}")"
  [ -f "${lf}" ] || die "no log for '${component}' at ${lf}"
  tail "$@" "${lf}"
}

# Emits every setting as KEY=value for use as a systemd EnvironmentFile, so
# the units and these scripts stay driven by the same defaults.sh.
cmd_systemd_env() {
  cat <<EOF
# Generated by stack.sh systemd-env on $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Install to /etc/telemetry/telemetry.env. Regenerate after changing env.sh.
#
# Paths assume the layout described in bare-metal/README.md:
#   binaries -> /opt/telemetry/bin      config -> /opt/telemetry/config
#   data     -> /var/lib/telemetry
EOF
  local v
  for v in BIND_ADDR \
           ALLOY_HTTP_PORT ALLOY_OTLP_GRPC_PORT ALLOY_OTLP_HTTP_PORT ALLOY_FARO_PORT \
           LOKI_HTTP_PORT LOKI_GRPC_PORT LOKI_INSTANCE_ADDR LOKI_OBJECT_STORE LOKI_S3_BUCKET \
           TEMPO_HTTP_PORT TEMPO_GRPC_PORT TEMPO_OTLP_GRPC_PORT TEMPO_OTLP_HTTP_PORT \
           TEMPO_BACKEND TEMPO_S3_BUCKET TEMPO_OTLP_ENDPOINT \
           MIMIR_HTTP_PORT MIMIR_GRPC_PORT MIMIR_MEMBERLIST_PORT MIMIR_RING_STORE \
           MIMIR_ADVERTISE_ADDR MIMIR_INSTANCE_ADDR MIMIR_BACKEND \
           MIMIR_BLOCKS_BUCKET MIMIR_RULER_BUCKET MIMIR_ALERTMANAGER_BUCKET \
           S3_URL S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY S3_INSECURE \
           LOKI_URL TEMPO_URL MIMIR_URL; do
    printf '%s=%s\n' "${v}" "${!v}"
  done

  # Under systemd the deployed layout is fixed, so these are emitted as the
  # installed paths rather than the in-repo ones.
  cat <<'EOF'
DATA_ROOT=/var/lib/telemetry
LOKI_DATA=/var/lib/telemetry/loki
TEMPO_DATA=/var/lib/telemetry/tempo
MIMIR_DATA=/var/lib/telemetry/mimir
ALLOY_DATA=/var/lib/telemetry/alloy
GF_DASHBOARDS_PATH=/opt/telemetry/config/grafana/dashboards
GF_PATHS_DATA=/var/lib/telemetry/grafana
GF_PATHS_LOGS=/var/log/telemetry/grafana
GF_PATHS_PLUGINS=/var/lib/telemetry/grafana/plugins
GF_PATHS_PROVISIONING=/opt/telemetry/config/grafana/provisioning
GF_FEATURE_TOGGLES_ENABLE=traceqlEditor,exemplars
GF_ANALYTICS_REPORTING_ENABLED=false
EOF
  printf 'GF_SERVER_HTTP_ADDR=%s\nGF_SERVER_HTTP_PORT=%s\n' "${BIND_ADDR}" "${GRAFANA_PORT}"
  echo "# Set GF_SECURITY_ADMIN_PASSWORD here, or leave Grafana's own default."
}

cmd_verify() {
  command -v python3 >/dev/null 2>&1 || die "verify needs python3 (standard library only)"
  exec python3 "${BM_HOME}/verify.py"
}

cmd_wipe() {
  cmd_down
  info "deleting ${DATA_ROOT}"
  rm -rf "${DATA_ROOT}"
  info "data deleted. Binaries in ${BIN_DIR} were left alone."
}

case "${1:-}" in
  up)      shift; cmd_up "$@" ;;
  down)    shift; cmd_down "$@" ;;
  restart) shift; cmd_down "$@"; cmd_up "$@" ;;
  status)  cmd_status ;;
  logs)    shift; cmd_logs "$@" ;;
  verify)  cmd_verify ;;
  systemd-env) cmd_systemd_env ;;
  wipe)    cmd_wipe ;;
  *)       sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
