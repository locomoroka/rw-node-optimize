#!/usr/bin/env bash
set -euo pipefail
umask 077
export LC_ALL=C

EXIT_OK=0
EXIT_RUNTIME=1
EXIT_USAGE=2

ASSUME_YES=0
DRY_RUN=0
DEBUG_MODE=0
SPEED_NORMALIZED=""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKDIR_BASE="${RW_BOOTSTRAP_WORKDIR:-/tmp/rw-oneliner}"
WORKDIR=""
RUN_ID=""
RUN_DIR=""
REPORT_EXIT=$EXIT_OK

RW_BOOTSTRAP_BASE_URL="${RW_BOOTSTRAP_BASE_URL:-https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main}"
RW_BOOTSTRAP_VERSION_EXPECTED="${RW_BOOTSTRAP_VERSION_EXPECTED:-}"
RW_BOOTSTRAP_APPLY_TARGET="${RW_BOOTSTRAP_APPLY_TARGET:-all}"
RW_BOOTSTRAP_SAMPLE_SECONDS="${RW_BOOTSTRAP_SAMPLE_SECONDS:-1}"

BEFORE_SNAPSHOT_STATUS="failed"
BEFORE_DIAG_STATUS="failed"
AFTER_DIAG_STATUS="failed"
AFTER_SNAPSHOT_STATUS="failed"
SNAPSHOT_RESULT_STATUS="failed"
APPLY_STATUS="failed"
APPLY_DETAIL="not started"
TX_ID=""

REQUIRED_FILES=(
  "VERSION"
  "manifest.sha256"
  "scripts/optimize-bootstrap.sh"
  "scripts/optimize.sh"
  "scripts/diag.sh"
  "scripts/snapshot.sh"
)

usage() {
  cat <<'EOF'
Usage:
  scripts/optimize-bootstrap.sh --help
  scripts/optimize-bootstrap.sh --yes [--speed <mbit>] [--debug]
  scripts/optimize-bootstrap.sh --dry-run [--speed <mbit>] [--debug]

Options:
  --yes             Non-interactive apply mode.
  --dry-run         Diagnostics/snapshots only; no mutating apply.
  --speed <value>   Per-user CAKE shaping speed (examples: 50, 50mbit, 500kbit, 1gbit).
  --debug           Print extended DEBUG diagnostics section after WHAT NEXT.
  --help, -h        Show this help.

Validation rules:
  - Exactly one mode is required: --yes OR --dry-run.
  - --yes and --dry-run together are invalid.
  - --speed requires a non-empty value and valid unit format.
  - --debug may be combined with --yes or --dry-run.

Environment overrides:
  RW_BOOTSTRAP_BASE_URL          Base URL/path for payload files (default: rw-node-optimize/main raw).
  RW_BOOTSTRAP_VERSION_EXPECTED  Optional pinned VERSION value to enforce.
  RW_BOOTSTRAP_WORKDIR           Optional local workdir (default: /tmp/rw-oneliner).
  RW_BOOTSTRAP_APPLY_TARGET      scripts/optimize.sh --apply target (default: all).
  RW_BOOTSTRAP_SAMPLE_SECONDS    Snapshot sampling window for bootstrap runs (default: 1).
  Payload layout                 VERSION, manifest.sha256, scripts/optimize-bootstrap.sh, scripts/optimize.sh, scripts/diag.sh, scripts/snapshot.sh.
EOF
}

log_info() {
  echo "[INFO] $1"
}

log_error() {
  echo "[FAIL] $1" >&2
}

die() {
  log_error "$1"
  exit "$EXIT_RUNTIME"
}

normalize_speed() {
  local raw="$1"
  local norm=""
  norm="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"

  if [[ "$norm" =~ ^[1-9][0-9]*$ ]]; then
    printf '%smbit' "$norm"
    return 0
  fi

  if [[ "$norm" =~ ^[1-9][0-9]*(kbit|mbit|gbit)$ ]]; then
    printf '%s' "$norm"
    return 0
  fi

  return 1
}

parse_args() {
  if [ "$#" -eq 0 ]; then
    log_error "Exactly one mode is required: --yes or --dry-run"
    usage >&2
    exit "$EXIT_USAGE"
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --help|-h)
        usage
        exit "$EXIT_OK"
        ;;
      --yes)
        if [ "$ASSUME_YES" -eq 1 ]; then
          log_error "Duplicate flag: --yes"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        ASSUME_YES=1
        ;;
      --dry-run)
        if [ "$DRY_RUN" -eq 1 ]; then
          log_error "Duplicate flag: --dry-run"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        DRY_RUN=1
        ;;
      --speed)
        if [ -n "$SPEED_NORMALIZED" ]; then
          log_error "Duplicate flag: --speed"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        if [ "$#" -lt 2 ]; then
          log_error "Missing required value for --speed"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        if ! SPEED_NORMALIZED="$(normalize_speed "$2")"; then
          log_error "Invalid --speed value: $2 (expected: <int>[kbit|mbit|gbit], e.g. 50 or 50mbit)"
          usage >&2
          exit "$EXIT_USAGE"
        fi
        shift
        ;;
      --debug)
        DEBUG_MODE=1
        ;;
      *)
        log_error "Unknown argument: $1"
        usage >&2
        exit "$EXIT_USAGE"
        ;;
    esac
    shift
  done
}

validate_mode_combination() {
  if [ "$ASSUME_YES" -eq 1 ] && [ "$DRY_RUN" -eq 1 ]; then
    log_error "Flags --yes and --dry-run are mutually exclusive"
    usage >&2
    exit "$EXIT_USAGE"
  fi

  if [ "$ASSUME_YES" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
    log_error "Exactly one mode is required: --yes or --dry-run"
    usage >&2
    exit "$EXIT_USAGE"
  fi
}

setup_workdir() {
  WORKDIR="${WORKDIR_BASE}"
  mkdir -p "$WORKDIR" || die "Failed to create workdir: ${WORKDIR}"
}

download_file() {
  local filename="$1"
  local url="${RW_BOOTSTRAP_BASE_URL}/${filename}"
  local out="${WORKDIR}/${filename}"
  local out_dir=""

  out_dir="$(dirname "$out")"
  mkdir -p "$out_dir" || die "Failed to create payload directory for ${filename}"

  if [ -f "$url" ]; then
    cp "$url" "$out" || die "Failed to copy ${filename} from ${url}"
    return 0
  fi

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$out" || die "Failed to download ${filename} from ${url}"
    return 0
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -qO "$out" "$url" || die "Failed to download ${filename} from ${url}"
    return 0
  fi

  die "Neither curl nor wget is available for downloading payload"
}

ensure_required_files_present() {
  local f=""
  for f in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "${WORKDIR}/${f}" ] || [ ! -s "${WORKDIR}/${f}" ]; then
      die "Required payload file missing or empty: ${f}"
    fi
  done
}

verify_version() {
  local actual=""
  actual="$(tr -d '\r' < "${WORKDIR}/VERSION" | awk 'NF{print; exit}')"

  if [ -z "$actual" ]; then
    die "VERSION file is empty"
  fi

  if [ -n "$RW_BOOTSTRAP_VERSION_EXPECTED" ] && [ "$actual" != "$RW_BOOTSTRAP_VERSION_EXPECTED" ]; then
    die "VERSION mismatch: expected ${RW_BOOTSTRAP_VERSION_EXPECTED}, got ${actual}"
  fi

  log_info "Payload VERSION: ${actual}"
}

verify_manifest() {
  local manifest="${WORKDIR}/manifest.sha256"

  if command -v sha256sum >/dev/null 2>&1; then
    (
      cd "$WORKDIR" || exit 1
      sha256sum -c "$manifest" --status
    ) || die "Checksum verification failed against manifest.sha256"
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    (
      cd "$WORKDIR" || exit 1
      shasum -a 256 -c "$manifest" --status
    ) || die "Checksum verification failed against manifest.sha256"
    return 0
  fi

  die "No SHA-256 verifier found (need sha256sum or shasum)"
}

fetch_and_verify_payload() {
  local f=""
  for f in "${REQUIRED_FILES[@]}"; do
    download_file "$f"
  done

  ensure_required_files_present
  verify_version
  verify_manifest
  chmod +x "${WORKDIR}/scripts/optimize-bootstrap.sh" "${WORKDIR}/scripts/optimize.sh" "${WORKDIR}/scripts/diag.sh" "${WORKDIR}/scripts/snapshot.sh"

  log_info "Payload integrity verification passed"
}

init_run_context() {
  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  RUN_DIR="${WORKDIR}/runs/${RUN_ID}"
  mkdir -p "$RUN_DIR" || die "Failed to create run context: ${RUN_DIR}"
}

mark_runtime_failure() {
  REPORT_EXIT=$EXIT_RUNTIME
}

run_capture() {
  local name="$1"
  shift
  local outfile="${RUN_DIR}/${name}.log"

  if "$@" >"$outfile" 2>&1; then
    return 0
  fi
  return 1
}

status_token() {
  case "$1" in
    changed|already-ok|skipped|failed) printf '%s' "$1" ;;
    *) die "Internal report status is not normalized: $1" ;;
  esac
}

summarize_log_tail() {
  local file="$1"
  if [ -f "$file" ]; then
    tail -n 8 "$file" | sed 's/^/    /'
  else
    echo "    log missing: $file"
  fi
}

extract_tx_id() {
  local file="$1"
  [ -f "$file" ] || return 0
  sed -n \
    -e 's/.*Transaction ID: \([A-Za-z0-9._-][A-Za-z0-9._-]*\).*/\1/p' \
    -e 's/.*\[tx:\([A-Za-z0-9._-][A-Za-z0-9._-]*\)\].*/\1/p' \
    "$file" | tail -n 1
}

run_before() {
  local label="one-liner ${RUN_ID} BEFORE"
  if RW_BA_STATE_DIR="${RUN_DIR}/snapshots" RW_BA_SAMPLE_SECONDS="$RW_BOOTSTRAP_SAMPLE_SECONDS" run_capture before-snapshot bash "${WORKDIR}/scripts/snapshot.sh" before "$label"; then
    BEFORE_SNAPSHOT_STATUS="ok"
  else
    BEFORE_SNAPSHOT_STATUS="failed"
    mark_runtime_failure
  fi

  if run_capture before-diag bash "${WORKDIR}/scripts/diag.sh"; then
    BEFORE_DIAG_STATUS="ok"
  else
    BEFORE_DIAG_STATUS="failed"
    mark_runtime_failure
  fi
}

run_apply() {
  local apply_log="${RUN_DIR}/apply.log"
  local -a apply_cmd=(bash "${WORKDIR}/scripts/optimize.sh" --apply "$RW_BOOTSTRAP_APPLY_TARGET")

  if [ -n "$SPEED_NORMALIZED" ]; then
    apply_cmd+=(--shaping "$SPEED_NORMALIZED")
  fi
  if [ "$DEBUG_MODE" -eq 1 ]; then
    apply_cmd+=(--debug)
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    APPLY_STATUS="skipped"
    APPLY_DETAIL="dry-run: mutating optimize.sh apply was not executed"
    {
      echo "dry-run: skipped command: ${apply_cmd[*]}"
      if [ -n "$SPEED_NORMALIZED" ]; then
        echo "speed: ${SPEED_NORMALIZED} would be passed as --shaping"
      fi
    } >"$apply_log"
    return 0
  fi

  if printf 'Yes\n' | "${apply_cmd[@]}" >"$apply_log" 2>&1; then
    TX_ID="$(extract_tx_id "$apply_log")"
    if grep -Eiq 'no-op apply|already match|already-ok' "$apply_log"; then
      APPLY_STATUS="already-ok"
      APPLY_DETAIL="target state already matched; no-op apply preserved"
    else
      APPLY_STATUS="changed"
      APPLY_DETAIL="optimize.sh --apply ${RW_BOOTSTRAP_APPLY_TARGET} completed"
    fi
  else
    TX_ID="$(extract_tx_id "$apply_log")"
    APPLY_STATUS="failed"
    APPLY_DETAIL="optimize.sh --apply ${RW_BOOTSTRAP_APPLY_TARGET} failed"
    mark_runtime_failure
  fi

  if [ -n "$SPEED_NORMALIZED" ]; then
    APPLY_DETAIL="${APPLY_DETAIL}; speed=${SPEED_NORMALIZED}"
  fi
}

run_after() {
  local label="one-liner ${RUN_ID} AFTER"
  if run_capture after-diag bash "${WORKDIR}/scripts/diag.sh"; then
    AFTER_DIAG_STATUS="ok"
  else
    AFTER_DIAG_STATUS="failed"
    mark_runtime_failure
  fi

  if RW_BA_STATE_DIR="${RUN_DIR}/snapshots" RW_BA_SAMPLE_SECONDS="$RW_BOOTSTRAP_SAMPLE_SECONDS" run_capture after-snapshot bash "${WORKDIR}/scripts/snapshot.sh" after "$label"; then
    AFTER_SNAPSHOT_STATUS="ok"
  else
    AFTER_SNAPSHOT_STATUS="failed"
    mark_runtime_failure
  fi

  if RW_BA_STATE_DIR="${RUN_DIR}/snapshots" RW_BA_SAMPLE_SECONDS="$RW_BOOTSTRAP_SAMPLE_SECONDS" run_capture snapshot-result bash "${WORKDIR}/scripts/snapshot.sh" result; then
    SNAPSHOT_RESULT_STATUS="ok"
  else
    SNAPSHOT_RESULT_STATUS="failed"
    mark_runtime_failure
  fi
}

print_debug_section() {
  local os_id="" os_ver="" kernel="" docker_ver="" docker_status=""

  os_id="$(. /etc/os-release 2>/dev/null && printf '%s' "${ID:-unknown}" || printf 'unknown')"
  os_ver="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_ID:-unknown}" || printf 'unknown')"
  kernel="$(uname -r 2>/dev/null || printf 'unavailable')"
  docker_ver="$(docker version --format '{{.Server.Version}}' 2>/dev/null || printf 'unavailable')"
  docker_status="$(systemctl is-active docker 2>/dev/null || printf 'unavailable')"

  echo
  echo "=== DEBUG ==="
  echo "DEBUG_OS=${os_id} ${os_ver}"
  echo "DEBUG_KERNEL=${kernel}"
  echo "DEBUG_DOCKER_VERSION=${docker_ver}"
  echo "DEBUG_DOCKER_STATUS=${docker_status}"
  echo "EVIDENCE_APPLY_SUMMARY=optimize=${APPLY_STATUS}"
}

print_report() {
  local normalized_apply_status=""
  normalized_apply_status="$(status_token "$APPLY_STATUS")"

  echo
  echo "BEFORE"
  echo "- snapshot: ${BEFORE_SNAPSHOT_STATUS}"
  echo "- diagnostics: ${BEFORE_DIAG_STATUS}"
  echo "- logs: ${RUN_DIR}/before-snapshot.log, ${RUN_DIR}/before-diag.log"

  echo
  echo "APPLIED"
  echo "- optimize: status=${normalized_apply_status}; target=${RW_BOOTSTRAP_APPLY_TARGET}; detail=${APPLY_DETAIL}"
  if [ -n "$SPEED_NORMALIZED" ]; then
    echo "- shaping: status=${normalized_apply_status}; speed=${SPEED_NORMALIZED}; pass-through=--shaping"
  fi
  if [ -n "$TX_ID" ]; then
    echo "- transaction: status=${normalized_apply_status}; tx-id=${TX_ID}"
  fi
  echo "- apply-log: ${RUN_DIR}/apply.log"

  echo
  echo "AFTER"
  echo "- diagnostics: ${AFTER_DIAG_STATUS}"
  echo "- snapshot: ${AFTER_SNAPSHOT_STATUS}"
  echo "- snapshot-result: ${SNAPSHOT_RESULT_STATUS}"
  echo "- logs: ${RUN_DIR}/after-diag.log, ${RUN_DIR}/after-snapshot.log, ${RUN_DIR}/snapshot-result.log"

  echo
  echo "WHAT NEXT"
  if [ "$normalized_apply_status" = "skipped" ]; then
    echo "- reboot/restart: not required by dry-run; no mutating apply was executed."
  elif [ "$normalized_apply_status" = "failed" ]; then
    echo "- reboot/restart: do not reboot for this run until failed steps are reviewed."
  else
    echo "- reboot/restart: reboot is recommended when kernel/sysctl or container runtime changes were applied; restart RemnaWave containers if service-level drift remains."
  fi

  echo "- verify: inspect ${RUN_DIR}/snapshot-result.log and rerun diagnostics with ./scripts/diag.sh after reboot/restart."
  if [ -n "$TX_ID" ]; then
    echo "- rollback: ./scripts/optimize.sh --rollback ${TX_ID}"
    echo "- verify-reboot: ./scripts/optimize.sh --verify-reboot ${TX_ID}"
  else
    echo "- rollback: no tx-id was created or detected for this run."
    echo "- verify-reboot: use ./scripts/optimize.sh --verify-reboot-last if a prior transaction exists."
  fi
  if [ "$REPORT_EXIT" -ne "$EXIT_OK" ]; then
    echo "- partial-fail: at least one orchestration step failed; review the logs below before applying further changes."
    summarize_log_tail "${RUN_DIR}/apply.log"
  fi

  if [ "$DEBUG_MODE" -eq 1 ]; then
    print_debug_section
  fi
}

main() {
  parse_args "$@"
  validate_mode_combination

  log_info "Parsed mode: $( [ "$ASSUME_YES" -eq 1 ] && echo apply || echo dry-run )"
  if [ -n "$SPEED_NORMALIZED" ]; then
    log_info "Parsed speed: ${SPEED_NORMALIZED}"
  else
    log_info "Parsed speed: <none>"
  fi

  setup_workdir
  fetch_and_verify_payload
  init_run_context

  run_before
  run_apply
  run_after
  print_report

  exit "$REPORT_EXIT"
}

main "$@"
