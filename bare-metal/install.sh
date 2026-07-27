#!/usr/bin/env bash
# Download the stack's binaries into bare-metal/bin/.
#
# Every component ships as a self-contained static binary, so "installing"
# means fetching an archive and unpacking one file. Nothing is written outside
# this repository and no root privileges are needed.
#
#   ./install.sh                 # all components
#   ./install.sh loki tempo      # just these
#   ./install.sh --list          # show what would be fetched, and from where
#
# Air-gapped / no public internet: set OFFLINE_DIR to a directory holding the
# release archives, or point GITHUB_BASE_URL / GRAFANA_BASE_URL at an internal
# mirror. See README.md.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=defaults.sh
. ./defaults.sh

ALL_COMPONENTS=(loki tempo mimir alloy grafana)
CHECKSUM_FILE="${BM_HOME}/checksums.txt"

# --- Platform detection -----------------------------------------------------
detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"
  case "${os}" in
    linux|darwin) ;;
    *) die "unsupported OS '${os}'. These components publish linux and darwin builds; on Windows use WSL2." ;;
  esac
  case "${arch}" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported architecture '${arch}'" ;;
  esac
  OS="${os}"; ARCH="${arch}"
}

die()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }
info() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }

# --- Release URLs -----------------------------------------------------------
# Prints "<url> <archive-filename>" for a component.
release_url() {
  case "$1" in
    loki)
      echo "${GITHUB_BASE_URL}/grafana/loki/releases/download/v${LOKI_VERSION}/loki-${OS}-${ARCH}.zip loki-${OS}-${ARCH}.zip" ;;
    alloy)
      echo "${GITHUB_BASE_URL}/grafana/alloy/releases/download/v${ALLOY_VERSION}/alloy-${OS}-${ARCH}.zip alloy-${OS}-${ARCH}.zip" ;;
    tempo)
      echo "${GITHUB_BASE_URL}/grafana/tempo/releases/download/v${TEMPO_VERSION}/tempo_${TEMPO_VERSION}_${OS}_${ARCH}.tar.gz tempo_${TEMPO_VERSION}_${OS}_${ARCH}.tar.gz" ;;
    mimir)
      echo "${GITHUB_BASE_URL}/grafana/mimir/releases/download/mimir-${MIMIR_VERSION}/mimir-${OS}-${ARCH} mimir-${OS}-${ARCH}" ;;
    grafana)
      echo "${GRAFANA_BASE_URL}/oss/release/grafana-${GRAFANA_VERSION}.${OS}-${ARCH}.tar.gz grafana-${GRAFANA_VERSION}.${OS}-${ARCH}.tar.gz" ;;
    *) die "unknown component '$1'" ;;
  esac
}

# --- Fetch + verify ---------------------------------------------------------
fetch() {
  local url="$1" dest="$2" name
  name="$(basename "${dest}")"

  if [ -n "${OFFLINE_DIR}" ] && [ -f "${OFFLINE_DIR}/${name}" ]; then
    info "using pre-staged ${name} from ${OFFLINE_DIR}"
    cp "${OFFLINE_DIR}/${name}" "${dest}"
  else
    info "downloading ${name}"
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL --retry 3 --retry-delay 2 -o "${dest}" "${url}"
    elif command -v wget >/dev/null 2>&1; then
      wget -q -t 3 -O "${dest}" "${url}"
    else
      die "need curl or wget to download; or set OFFLINE_DIR to a directory containing ${name}"
    fi
  fi
  verify_checksum "${dest}" "${name}"
}

# Checks the archive against checksums.txt when an entry exists. Entries are
# only recorded for builds that have actually been verified, so a missing one
# is a warning rather than a failure.
verify_checksum() {
  local file="$1" name="$2" expected actual
  [ -f "${CHECKSUM_FILE}" ] || return 0
  expected="$(awk -v n="${name}" '$2 == n {print $1}' "${CHECKSUM_FILE}" | head -1)"
  if [ -z "${expected}" ]; then
    warn "no recorded checksum for ${name}; skipping verification"
    return 0
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    actual="$(sha256sum "${file}" | awk '{print $1}')"
  elif command -v shasum >/dev/null 2>&1; then
    actual="$(shasum -a 256 "${file}" | awk '{print $1}')"
  else
    warn "no sha256sum/shasum available; skipping verification of ${name}"
    return 0
  fi
  [ "${expected}" = "${actual}" ] || die "checksum mismatch for ${name}: expected ${expected}, got ${actual}"
  info "checksum ok: ${name}"
}

# --- Per-component install --------------------------------------------------
install_component() {
  local component="$1" url name archive tmp
  read -r url name <<<"$(release_url "${component}")"
  tmp="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '${tmp}'" RETURN

  archive="${tmp}/${name}"
  fetch "${url}" "${archive}"

  case "${component}" in
    loki|alloy)
      # Zip containing a single binary named <component>-<os>-<arch>.
      unzip -oq "${archive}" -d "${tmp}"
      mv "${tmp}/${component}-${OS}-${ARCH}" "${BIN_DIR}/${component}"
      ;;
    tempo)
      # Tarball with the binary at the root.
      tar -xzf "${archive}" -C "${tmp}" tempo
      mv "${tmp}/tempo" "${BIN_DIR}/tempo"
      ;;
    mimir)
      # Published as a bare binary.
      mv "${archive}" "${BIN_DIR}/mimir"
      ;;
    grafana)
      # Grafana is not a single binary: it needs its bundled web assets and
      # default configuration, so the whole tree is kept under bin/grafana-home
      # and stack.sh points --homepath at it.
      tar -xzf "${archive}" -C "${tmp}"
      local extracted
      extracted="$(find "${tmp}" -maxdepth 1 -type d -name 'grafana*' | head -1)"
      [ -n "${extracted}" ] || die "could not find the extracted Grafana directory in ${name}"
      rm -rf "${BIN_DIR}/grafana-home"
      mv "${extracted}" "${BIN_DIR}/grafana-home"
      ln -sf grafana-home/bin/grafana "${BIN_DIR}/grafana"
      ;;
  esac
  chmod +x "${BIN_DIR}/${component}" 2>/dev/null || true
}

version_of() {
  case "$1" in
    loki) echo "${LOKI_VERSION}" ;; tempo) echo "${TEMPO_VERSION}" ;;
    mimir) echo "${MIMIR_VERSION}" ;; alloy) echo "${ALLOY_VERSION}" ;;
    grafana) echo "${GRAFANA_VERSION}" ;;
  esac
}

main() {
  detect_platform

  local components=()
  for arg in "$@"; do
    case "${arg}" in
      --list)
        detect_platform
        printf 'platform: %s/%s\n\n' "${OS}" "${ARCH}"
        for c in "${ALL_COMPONENTS[@]}"; do
          printf '%-8s %-8s %s\n' "${c}" "$(version_of "${c}")" "$(release_url "${c}" | cut -d' ' -f1)"
        done
        exit 0 ;;
      -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
      -*) die "unknown flag '${arg}'" ;;
      *) components+=("${arg}") ;;
    esac
  done
  [ ${#components[@]} -gt 0 ] || components=("${ALL_COMPONENTS[@]}")

  command -v unzip >/dev/null 2>&1 || die "unzip is required (Loki and Alloy ship as .zip)"
  mkdir -p "${BIN_DIR}"

  info "installing for ${OS}/${ARCH} into ${BIN_DIR}"
  for c in "${components[@]}"; do
    install_component "${c}"
  done

  echo
  info "installed:"
  for c in "${components[@]}"; do
    printf '  %-8s %s\n' "${c}" "$("${BIN_DIR}/${c}" --version 2>&1 | head -1)"
  done
  echo
  info "next: ./stack.sh up"
}

main "$@"
