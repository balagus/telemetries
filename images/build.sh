#!/usr/bin/env bash
# Build container images for the stack from the binaries in bare-metal/bin,
# on top of a base image your organisation permits.
#
#   ./images/build.sh                    # build all components
#   ./images/build.sh loki tempo         # build just these
#   ./images/build.sh --push             # build all, then push
#   ./images/build.sh --list             # show what would be built
#
# Configure with environment variables (or images/env.sh):
#
#   BASE_IMAGE   base to build FROM. Must be glibc-based — Alloy is
#                dynamically linked and will not run on Alpine/musl.
#   REGISTRY     registry/namespace prefix for the resulting tags.
#   IMAGE_PREFIX name prefix within the registry (default "telemetry-").
#
#   BASE_IMAGE=registry.example.com/base/ubi9-minimal:9.5 \
#   REGISTRY=registry.example.com/observability \
#   ./images/build.sh --push
#
# Versions and component list come from bare-metal/defaults.sh, so the images
# are tagged with exactly the versions that were installed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_ROOT="$(pwd)"

# shellcheck source=../bare-metal/defaults.sh
. ./bare-metal/defaults.sh

# Your local settings, if any (gitignored).
# shellcheck source=/dev/null
[ -f images/env.sh ] && . images/env.sh

: "${BASE_IMAGE:=docker.io/library/debian:12-slim}"
: "${REGISTRY:=telemetry-stack}"
: "${IMAGE_PREFIX:=telemetry-}"
: "${RUN_UID:=10001}"
: "${RUN_GID:=10001}"
: "${DOCKER:=docker}"

ALL_COMPONENTS=(loki tempo mimir alloy grafana)

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

version_of() {
  case "$1" in
    loki) echo "${LOKI_VERSION}" ;; tempo) echo "${TEMPO_VERSION}" ;;
    mimir) echo "${MIMIR_VERSION}" ;; alloy) echo "${ALLOY_VERSION}" ;;
    grafana) echo "${GRAFANA_VERSION}" ;;
  esac
}

tag_of() { echo "${REGISTRY}/${IMAGE_PREFIX}$1:$(version_of "$1")"; }

# Alloy is dynamically linked; the other three are static. Catching a musl
# base here is far kinder than the "no such file or directory" the loader
# produces at container start.
warn_if_musl_base() {
  case "${BASE_IMAGE}" in
    *alpine*|*musl*)
      warn "BASE_IMAGE '${BASE_IMAGE}' looks musl-based."
      warn "Alloy is dynamically linked against glibc and will not start on it."
      warn "Use a Debian, Ubuntu or RHEL/UBI base instead."
      ;;
  esac
}

build_one() {
  local component="$1" tag dockerfile
  tag="$(tag_of "${component}")"

  if [ "${component}" = grafana ]; then
    dockerfile=images/Dockerfile.grafana
    [ -d bare-metal/bin/grafana-home ] \
      || die "bare-metal/bin/grafana-home is missing — run ./bare-metal/install.sh grafana"
  else
    dockerfile=images/Dockerfile
    [ -f "bare-metal/bin/${component}" ] \
      || die "bare-metal/bin/${component} is missing — run ./bare-metal/install.sh ${component}"
  fi

  info "building ${tag}"
  "${DOCKER}" build \
    -f "${dockerfile}" \
    --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
    --build-arg "COMPONENT=${component}" \
    --build-arg "COMPONENT_VERSION=$(version_of "${component}")" \
    --build-arg "RUN_UID=${RUN_UID}" \
    --build-arg "RUN_GID=${RUN_GID}" \
    -t "${tag}" \
    "${REPO_ROOT}"
}

push_one() {
  local tag; tag="$(tag_of "$1")"
  info "pushing ${tag}"
  "${DOCKER}" push "${tag}"
}

main() {
  local push=0 components=()
  for arg in "$@"; do
    case "${arg}" in
      --push) push=1 ;;
      --list)
        printf 'base image: %s\n\n' "${BASE_IMAGE}"
        for c in "${ALL_COMPONENTS[@]}"; do
          printf '%-8s %-8s %s\n' "${c}" "$(version_of "${c}")" "$(tag_of "${c}")"
        done
        exit 0 ;;
      -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*) die "unknown flag '${arg}'" ;;
      *) components+=("${arg}") ;;
    esac
  done
  [ ${#components[@]} -gt 0 ] || components=("${ALL_COMPONENTS[@]}")

  # Warn about the base before checking for a builder: a musl base is a
  # configuration mistake worth surfacing either way.
  warn_if_musl_base

  command -v "${DOCKER}" >/dev/null 2>&1 \
    || die "'${DOCKER}' not found. Set DOCKER=podman to build with Podman."

  info "base image: ${BASE_IMAGE}"

  for c in "${components[@]}"; do build_one "${c}"; done
  if [ "${push}" -eq 1 ]; then
    for c in "${components[@]}"; do push_one "${c}"; done
  fi

  echo
  info "built:"
  for c in "${components[@]}"; do printf '  %s\n' "$(tag_of "${c}")"; done
  cat <<EOF

Run the stack on these images instead of the upstream ones:

  REGISTRY=${REGISTRY} docker compose \\
    -f docker-compose.yml -f images/docker-compose.images.yml up -d
EOF
}

main "$@"
