#!/bin/bash
set -euo pipefail

#===============================================================================
# RemnaWave Adaptive Optimization Script v3.1
# Sysctl parameter fixes based on recomend.md audit and 2026-05-15 production incident:
#   - tcp_fin_timeout: 30→15 (orphan-storm prevention under reconcile load >17K established)
#   - nf_conntrack_tcp_timeout_established: 3600→1200 (conntrack table pressure)
#   - nf_conntrack_tcp_timeout_time_wait: 30→15 (orphan-storm symmetry)
#   - nf_conntrack_tcp_timeout_fin_wait: 30→15 (orphan-storm symmetry)
#   - tcp_notsent_lowat: added 131072 (VLESS/Vision multiplexing latency)
#   - tcp_max_orphans: adaptive clamp(MEM_TOTAL_MB*64, 65536, 1048576)
#   - tcp_orphan_retries: added 3 (faster orphan pool release)
# Compose environment patch (default profile, no RW_OPT_GC_PROFILE):
#   - default resolves to conservative: GOGC=100 + GODEBUG=madvdontneed=1
#   - GOMEMLIMIT = (CONTAINER_MEM_MB - 1500) / 100 * 100 MiB (if guard passes)
# RW_OPT_GC_PROFILE=conservative (and alias default):
#   - same as default conservative profile
# RW_OPT_GC_PROFILE=fallback:
#   - legacy mode: GOGC=150, GOMEMLIMIT removed
#   - guard: if CONTAINER_MEM_MB - 1500 < 1024 → skip GOMEMLIMIT (warn + degrade)
# Explicit contract:
#   - no implicit mutation
#   - must pass --apply <target>
#   - always show preview + require exact "Yes"
#   - supports validated zone subsets
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${CYAN}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }
log_error_stderr() { echo -e "${RED}[FAIL]${NC} $1" >&2; }

ZONE_ORDER=(sysctl limits docker-daemon compose net-iface)
ALLOWED_ZONES="${ZONE_ORDER[*]}"

CLI_MODE=""
APPLY_TARGET_RAW=""
# Set by normalize_selected_zones: 1 if --apply list explicitly names docker-daemon (not from bare "all").
DOCKER_DAEMON_EXPLICITLY_SELECTED=0
ROLLBACK_TX_ID=""
VERIFY_TX_ID=""
SELECTED_ZONES=()
SELECTED_ZONES_CSV=""
SHAPING_BANDWIDTH=""
DEBUG_MODE=0
VERIFY_ROLLBACK_ON_FAIL="0"

DEFAULT_STATE_ROOT="/var/lib/remnawave-optimizer"

# Calculated globals
CPU_CORES=""
CPU_MODEL=""
MEM_TOTAL_KB=""
MEM_TOTAL_MB=""
MEM_TOTAL_GB=""
VIRT_TYPE=""
NET_IFACE=""

SYS_RESERVE=""
AVAILABLE_MB=""
CONTAINER_MEM_MB=""
CONTAINER_MEM_RESERVE=""
CONTAINER_CPUS=""
TCP_RMEM_MAX=""
TCP_WMEM_MAX=""
TCP_BUFFER_DEFAULT=""
CONNTRACK_MAX=""
FD_SOFT=""
FD_HARD=""
SOMAXCONN=""
SYN_BACKLOG=""
NETDEV_BACKLOG=""
RING_SIZE=""
TCP_FIN_TIMEOUT=""
CONNTRACK_ESTABLISHED=""
TCP_NOTSENT_LOWAT=""
TCP_MAX_ORPHANS=""
TCP_ORPHAN_RETRIES=""
SWAPPINESS=""

SYSCTL_CONFIG="/etc/sysctl.d/99-remnawave-adaptive.conf"
LIMITS_CONFIG="/etc/security/limits.d/99-remnawave-adaptive.conf"
DOCKER_CONFIG="/etc/docker/daemon.json"
EXISTING_COMPOSE="/opt/remnawave/docker-compose.yml"
OOM_SCRIPT="/usr/local/bin/remnawave-oom-watch.sh"
OOM_SERVICE="/etc/systemd/system/remnawave-oom-watch.service"
MODULES_LOAD_BBR="/etc/modules-load.d/bbr.conf"
MODULES_LOAD_CONNTRACK="/etc/modules-load.d/nf_conntrack.conf"
STARTUP_BASELINE_REL_PATH="baseline/containers.tsv"
REBOOT_VERIFY_TIMEOUT_SEC="${RW_OPT_REBOOT_VERIFY_TIMEOUT:-180}"
REBOOT_VERIFY_INTERVAL_SEC="${RW_OPT_REBOOT_VERIFY_INTERVAL:-5}"

COMPOSE_CANDIDATE_PATHS=(
    "/opt/remnawave/docker-compose.yml"
    "/opt/remnanode/docker-compose.yml"
    "/vless/docker-compose.yml"
    "/vless/remnanode/docker-compose.yml"
)
# After successful --apply: `docker compose up -d` for each existing file. Disable with RW_OPT_COMPOSE_ENSURE_UP=0.
COMPOSE_ENSURE_STACK_PATHS=(
    "/opt/remnanode/docker-compose.yml"
    "/opt/remnanode/selfsteal/docker-compose.yml"
)
COMPOSE_SERVICE_NAME="remnanode"
COMPOSE_CONTAINER_NAME="remnanode"

CURRENT_TX_ID=""
CURRENT_TX_DIR=""
CURRENT_TX_OPS_DIR=""
ZONE_OUTCOME_STATUS="applied"
ZONE_OUTCOME_REASON="zone applied successfully"
ROLLBACK_ZONE_STATUS="rolled_back"
ROLLBACK_ZONE_REASON="rollback completed"
CURRENT_OP_PATH=""
STARTUP_BASELINE_ACTIVE="0"
STARTUP_BASELINE_FILE=""
STARTUP_BASELINE_SCOPE="${RW_OPT_BASELINE_SCOPE:-all}"
STARTUP_BASELINE_INCLUDE_REGEX="${RW_OPT_BASELINE_INCLUDE_REGEX:-}"
STARTUP_BASELINE_EXCLUDE_REGEX="${RW_OPT_BASELINE_EXCLUDE_REGEX:-}"

is_test_mode() {
    [ "${RW_OPT_TEST_MODE:-0}" = "1" ]
}

# List of parameter names managed by this script's sysctl zone.
# Used for conflict detection and idempotency checks.
get_managed_sysctl_params() {
    echo "net.core.default_qdisc"
    echo "net.ipv4.tcp_congestion_control"
    echo "net.ipv4.tcp_fin_timeout"
    echo "net.ipv4.tcp_keepalive_time"
    echo "net.ipv4.tcp_keepalive_intvl"
    echo "net.ipv4.tcp_keepalive_probes"
    echo "net.ipv4.tcp_notsent_lowat"
    echo "net.ipv4.tcp_max_orphans"
    echo "net.ipv4.tcp_orphan_retries"
    echo "net.netfilter.nf_conntrack_tcp_timeout_established"
    echo "net.netfilter.nf_conntrack_tcp_timeout_time_wait"
    echo "net.netfilter.nf_conntrack_tcp_timeout_fin_wait"
    echo "net.core.rmem_max"
    echo "net.core.wmem_max"
    echo "net.ipv4.tcp_rmem"
    echo "net.ipv4.tcp_wmem"
    echo "vm.swappiness"
}

print_debug_section() {
    local os_id="" os_ver="" kernel="" docker_ver="" docker_status=""
    local param key val summary_parts=()

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

    while IFS= read -r param; do
        val="$(sysctl -n "$param" 2>/dev/null || printf 'unavailable')"
        key="${param//./_}"
        echo "DEBUG_SYSCTL_${key}=${val}"
    done < <(get_managed_sysctl_params)

    local fd_soft fd_hard
    fd_soft="$(ulimit -Sn 2>/dev/null || printf 'unavailable')"
    fd_hard="$(ulimit -Hn 2>/dev/null || printf 'unavailable')"
    echo "DEBUG_LIMITS_nofile_soft=${fd_soft}"
    echo "DEBUG_LIMITS_nofile_hard=${fd_hard}"

    if [ -n "${_DEBUG_APPLY_SUMMARY:-}" ]; then
        echo "EVIDENCE_APPLY_SUMMARY=${_DEBUG_APPLY_SUMMARY}"
    fi
}

# Read current value of a sysctl parameter.
# Returns "__missing__" if the tunable does not exist in the kernel.
get_current_sysctl_value() {
    local param="$1"
    local val
    val="$(sysctl -n "$param" 2>/dev/null || true)"
    if [ -z "$val" ]; then
        echo "__missing__"
    else
        echo "$val"
    fi
}

normalize_sysctl_value() {
    local value="$1"
    echo "$value" | tr '\t' ' ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

journal_decode_value() {
    local raw="$1"

    if [[ "$raw" =~ ^\$\'.*\'$ ]]; then
        local inner="${raw:2:${#raw}-3}"
        printf '%b' "$inner"
        return 0
    fi

    printf '%s' "$raw"
}

capture_sysctl_runtime_snapshot() {
    local op_path="$1"
    local idx=0
    local param current

    while IFS= read -r param; do
        current="$(get_current_sysctl_value "$param")"
        idx=$((idx + 1))
        journal_append_field "$op_path" "sysctl_runtime_${idx}_param" "$param"
        journal_append_field "$op_path" "sysctl_runtime_${idx}_value" "$current"
    done < <(get_managed_sysctl_params)

    journal_append_field "$op_path" "sysctl_runtime_count" "$idx"
}

restore_sysctl_runtime_snapshot() {
    local op_path="$1"
    local count i param value restored=0 missing=0 failed=0

    count="$(journal_get_field_optional "$op_path" "sysctl_runtime_count")"
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -eq 0 ]; then
        echo "no runtime snapshot metadata"
        return 1
    fi

    for ((i=1; i<=count; i++)); do
        param="$(journal_decode_value "$(journal_get_field_optional "$op_path" "sysctl_runtime_${i}_param")")"
        value="$(journal_decode_value "$(journal_get_field_optional "$op_path" "sysctl_runtime_${i}_value")")"

        if [ -z "$param" ]; then
            failed=$((failed + 1))
            continue
        fi

        if [ "$value" = "__missing__" ] || [ -z "$value" ]; then
            missing=$((missing + 1))
            continue
        fi

        if sysctl -w "${param}=${value}" >/dev/null 2>&1; then
            restored=$((restored + 1))
        else
            failed=$((failed + 1))
        fi
    done

    echo "runtime restored=${restored} skipped_missing=${missing} failed=${failed}"
    [ "$failed" -eq 0 ]
}

# Scan /etc/sysctl.d/ and /etc/sysctl.conf for files that override managed params.
# Outputs one line per conflict: "filename\tparam=value\tparam=value..."
scan_conflicting_sysctl_configs() {
    local managed_params
    managed_params="$(get_managed_sysctl_params | sort -u)"
    if [ -z "$managed_params" ]; then
        return 0
    fi

    local scan_files=()
    if [ -f /etc/sysctl.conf ]; then
        scan_files+=(/etc/sysctl.conf)
    fi
    # shellcheck disable=SC2206
    scan_files+=(/etc/sysctl.d/*.conf)

    local f param param_escaped line match_params
    for f in "${scan_files[@]}"; do
        [ -f "$f" ] || continue
        # Skip our own config and already disabled files
        case "$f" in
            *"99-remnawave-adaptive.conf"|*".disabled") continue ;;
        esac

        match_params=""
        while IFS= read -r line || [ -n "$line" ]; do
            # Trim leading/trailing whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            # Skip comments and empty lines
            case "$line" in
                "#"*|""|";"*) continue ;;
            esac
            # Parameter name is everything before first = or space
            param="${line%%[[:space:]=]*}"
            # Remove any trailing spaces from param name
            param="${param% }"
            # Check if param is in managed list
            if echo "$managed_params" | grep -qxF "$param"; then
                if [ -z "$match_params" ]; then
                    match_params="${line}"
                else
                    match_params="${match_params}; ${line}"
                fi
            fi
        done < "$f"

        if [ -n "$match_params" ]; then
            printf '%s\t%s\n' "$f" "$match_params"
        fi
    done
}

# Check if the sysctl zone is already at target values (idempotent).
# Returns 0 (all match) or 1 (some differ).
# Parameters not available in kernel are treated as "not applied".
is_zone_idempotent() {
    local mismatches=0
    local param current target

    while IFS= read -r param; do
        current="$(get_current_sysctl_value "$param")"
        if [ "$current" = "__missing__" ]; then
            continue
        fi

        target=""
        case "$param" in
            net.core.default_qdisc)          target="${QDISC}" ;;
            net.ipv4.tcp_congestion_control) target="bbr" ;;
            net.ipv4.tcp_fin_timeout)        target="${TCP_FIN_TIMEOUT}" ;;
            net.ipv4.tcp_keepalive_time)     target="300" ;;
            net.ipv4.tcp_keepalive_intvl)    target="30" ;;
            net.ipv4.tcp_keepalive_probes)   target="3" ;;
            net.ipv4.tcp_notsent_lowat)      target="${TCP_NOTSENT_LOWAT}" ;;
            net.ipv4.tcp_max_orphans)        target="${TCP_MAX_ORPHANS}" ;;
            net.ipv4.tcp_orphan_retries)     target="${TCP_ORPHAN_RETRIES}" ;;
            net.netfilter.nf_conntrack_tcp_timeout_established) target="${CONNTRACK_ESTABLISHED}" ;;
            net.netfilter.nf_conntrack_tcp_timeout_time_wait) target="15" ;;
            net.netfilter.nf_conntrack_tcp_timeout_fin_wait)  target="15" ;;
            net.core.rmem_max)               target="${TCP_RMEM_MAX}" ;;
            net.core.wmem_max)               target="${TCP_WMEM_MAX}" ;;
            net.ipv4.tcp_rmem)               target="4096 ${TCP_BUFFER_DEFAULT} ${TCP_RMEM_MAX}" ;;
            net.ipv4.tcp_wmem)               target="4096 ${TCP_BUFFER_DEFAULT} ${TCP_WMEM_MAX}" ;;
            vm.swappiness)                   target="${SWAPPINESS}" ;;
        esac

        # Compare values (normalize whitespace for multi-value params)
        if [ "$(normalize_sysctl_value "$current")" != "$(normalize_sysctl_value "$target")" ]; then
            mismatches=$((mismatches + 1))
        fi
    done < <(get_managed_sysctl_params)

    if [ "$mismatches" -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

resolve_state_root() {
    local root="${RW_OPT_STATE_DIR:-$DEFAULT_STATE_ROOT}"
    if [ -z "$root" ]; then
        root="$DEFAULT_STATE_ROOT"
    fi
    echo "$root"
}

transactions_root() {
    echo "$(resolve_state_root)/transactions"
}

tx_id_is_valid() {
    local tx_id="$1"

    if [ -z "$tx_id" ]; then
        return 1
    fi

    if [[ "$tx_id" == *"/"* || "$tx_id" == *".."* ]]; then
        return 1
    fi

    if [[ ! "$tx_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
        return 1
    fi

    return 0
}

generate_tx_id() {
    if is_test_mode && [ -n "${RW_OPT_TEST_TX_ID:-}" ]; then
        if ! tx_id_is_valid "$RW_OPT_TEST_TX_ID"; then
            log_error "RW_OPT_TEST_TX_ID is invalid"
            exit 2
        fi
        echo "$RW_OPT_TEST_TX_ID"
        return 0
    fi

    local ts
    local suffix

    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    suffix="$(od -An -N4 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"

    if [ -z "$suffix" ]; then
        suffix="00000000"
    fi

    echo "${ts}-${suffix}"
}

tx_dir_for_id() {
    local tx_id="$1"
    echo "$(transactions_root)/${tx_id}"
}

list_all_tx_ids_chronological() {
    local root
    root="$(transactions_root)"

    if [ ! -d "$root" ]; then
        return 2
    fi

    local line
    local -a tx_ids=()
    while IFS= read -r line; do
        local candidate
        candidate="${line#* }"
        if tx_id_is_valid "$candidate"; then
            tx_ids+=("$candidate")
        fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' 2>/dev/null | sort -n)

    if [ "${#tx_ids[@]}" -eq 0 ]; then
        return 3
    fi

    printf '%s\n' "${tx_ids[@]}"
}

find_last_tx_id() {
    local tx_output=""
    if ! tx_output="$(list_all_tx_ids_chronological)"; then
        return $?
    fi

    local -a tx_ids=()
    local tx_id
    while IFS= read -r tx_id; do
        [ -n "$tx_id" ] && tx_ids+=("$tx_id")
    done <<< "$tx_output"

    if [ "${#tx_ids[@]}" -eq 0 ]; then
        return 3
    fi

    local last_index=$(( ${#tx_ids[@]} - 1 ))
    echo "${tx_ids[$last_index]}"
}

utc_now() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

reset_zone_outcome() {
    ZONE_OUTCOME_STATUS="applied"
    ZONE_OUTCOME_REASON="zone applied successfully"
}

mark_zone_skipped() {
    local reason="$1"
    ZONE_OUTCOME_STATUS="skipped"
    ZONE_OUTCOME_REASON="$reason"
}

journal_assert_status() {
    local status="$1"
    case "$status" in
        planned|applied|skipped|failed)
            return 0
            ;;
        *)
            log_error "Unexpected journal status: $status"
            return 1
            ;;
    esac
}

journal_op_path() {
    local seq="$1"
    local zone="$2"
    printf "%s/%04d-%s.env" "$CURRENT_TX_OPS_DIR" "$seq" "$zone"
}

journal_write_manifest() {
    local created_at="$1"
    local manifest_path="${CURRENT_TX_DIR}/manifest.env"
    local host
    host="$(hostname 2>/dev/null || echo unknown)"

    {
        echo "# RemnaWave transaction manifest"
        printf 'mode=%q\n' "apply"
        printf 'tx_id=%q\n' "$CURRENT_TX_ID"
        printf 'created_at=%q\n' "$created_at"
        printf 'apply_target_raw=%q\n' "$APPLY_TARGET_RAW"
        printf 'selected_zones_csv=%q\n' "$SELECTED_ZONES_CSV"
        printf 'script_version=%q\n' "3.1"
        printf 'hostname=%q\n' "$host"
    } > "$manifest_path"
}

journal_write_op() {
    local seq="$1"
    local zone="$2"
    local status="$3"
    local reason="$4"
    local planned_at="$5"
    local finished_at="$6"

    if ! journal_assert_status "$status"; then
        exit 1
    fi

    local op_path
    op_path="$(journal_op_path "$seq" "$zone")"

    local extra_lines=""
    if [ -f "$op_path" ]; then
        extra_lines="$(awk -F= '
            $1!="seq" && $1!="zone" && $1!="status" && $1!="reason" && $1!="planned_at" && $1!="finished_at" {
                print $0
            }
        ' "$op_path")"
    fi

    {
        printf 'seq=%q\n' "$seq"
        printf 'zone=%q\n' "$zone"
        printf 'status=%q\n' "$status"
        printf 'reason=%q\n' "$reason"
        printf 'planned_at=%q\n' "$planned_at"
        printf 'finished_at=%q\n' "$finished_at"
        if [ -n "$extra_lines" ]; then
            printf '%s\n' "$extra_lines"
        fi
    } > "$op_path"
}

journal_init_apply_tx() {
    CURRENT_TX_ID="$(generate_tx_id)"
    if ! tx_id_is_valid "$CURRENT_TX_ID"; then
        log_error "Generated tx-id is invalid: ${CURRENT_TX_ID}"
        exit 2
    fi

    CURRENT_TX_DIR="$(tx_dir_for_id "$CURRENT_TX_ID")"
    CURRENT_TX_OPS_DIR="${CURRENT_TX_DIR}/ops"

    if ! mkdir -p "$CURRENT_TX_OPS_DIR"; then
        if is_test_mode; then
            local fallback_root="${TMPDIR:-/tmp}/remnawave-optimizer-test-state"
            log_warn "State root not writable in test mode; falling back to ${fallback_root}"
            CURRENT_TX_DIR="${fallback_root}/transactions/${CURRENT_TX_ID}"
            CURRENT_TX_OPS_DIR="${CURRENT_TX_DIR}/ops"
            mkdir -p "$CURRENT_TX_OPS_DIR"
        else
            log_error "Failed to create transaction directory: ${CURRENT_TX_OPS_DIR}"
            exit 1
        fi
    fi

    local created_at
    created_at="$(utc_now)"
    journal_write_manifest "$created_at"

    log_info "Transaction ID: ${CURRENT_TX_ID}"
    log_info "Transaction journal dir: ${CURRENT_TX_DIR}"
}

journal_validate_env_file() {
    local file_path="$1"

    if [ ! -f "$file_path" ]; then
        log_error_stderr "Missing journal file: ${file_path}"
        return 1
    fi

    local line
    while IFS= read -r line || [ -n "$line" ]; do
        if [ -z "$line" ] || [[ "$line" =~ ^# ]]; then
            continue
        fi

        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            log_error_stderr "Malformed journal entry in ${file_path}: ${line}"
            return 1
        fi
    done < "$file_path"

    return 0
}

journal_read_field() {
    local file_path="$1"
    local key="$2"

    if ! journal_validate_env_file "$file_path"; then
        return 1
    fi

    local line
    line="$(awk -F= -v k="$key" '$1==k {print substr($0, index($0, "=")+1); exit}' "$file_path")"

    if [ -z "$line" ]; then
        log_error_stderr "Missing journal key '${key}' in ${file_path}"
        return 1
    fi

    if [[ "$line" == *'$('* || "$line" == *'`'* ]]; then
        log_error_stderr "Unsafe journal value for key '${key}' in ${file_path}"
        return 1
    fi

    printf '%s\n' "$line"
}

resolve_tx_dir() {
    local tx_id="$1"

    if ! tx_id_is_valid "$tx_id"; then
        log_error_stderr "Invalid tx-id: ${tx_id}"
        return 2
    fi

    local tx_dir
    tx_dir="$(tx_dir_for_id "$tx_id")"

    if [ ! -d "$tx_dir" ]; then
        log_error_stderr "Unknown tx-id: ${tx_id} (expected directory: ${tx_dir})"
        return 1
    fi

    if [ ! -f "${tx_dir}/manifest.env" ]; then
        log_error_stderr "Malformed journal for tx ${tx_id}: manifest.env missing"
        return 1
    fi

    if [ ! -d "${tx_dir}/ops" ]; then
        log_error_stderr "Malformed journal for tx ${tx_id}: ops/ directory missing"
        return 1
    fi

    printf '%s\n' "$tx_dir"
}

list_tx_op_files_sorted() {
    local tx_dir="$1"
    find "${tx_dir}/ops" -mindepth 1 -maxdepth 1 -type f -name '*.env' -printf '%f\n' 2>/dev/null | sort | awk -v d="${tx_dir}/ops" '{print d "/" $0}'
}

append_rollback_outcome() {
    local op_path="$1"
    local rollback_status="$2"
    local rollback_reason="$3"
    local attempted_at="$4"

    {
        printf 'rollback_status=%q\n' "$rollback_status"
        printf 'rollback_reason=%q\n' "$rollback_reason"
        printf 'rollback_attempted_at=%q\n' "$attempted_at"
    } >> "$op_path"
}

reset_rollback_outcome() {
    ROLLBACK_ZONE_STATUS="rolled_back"
    ROLLBACK_ZONE_REASON="rollback completed"
}

mark_rollback_failure() {
    local reason="$1"
    ROLLBACK_ZONE_STATUS="failed"
    ROLLBACK_ZONE_REASON="$reason"
}

journal_append_field() {
    local op_path="$1"
    local key="$2"
    local value="$3"
    printf '%s=%q\n' "$key" "$value" >> "$op_path"
}

manifest_append_field() {
    local key="$1"
    local value="$2"
    printf '%s=%q\n' "$key" "$value" >> "${CURRENT_TX_DIR}/manifest.env"
}

restart_policy_rank() {
    case "$1" in
        always) echo 3 ;;
        unless-stopped) echo 2 ;;
        on-failure) echo 1 ;;
        no|""|"__missing__") echo 0 ;;
        *) echo 0 ;;
    esac
}

get_container_restart_policy() {
    local cname="$1"
    if ! command -v docker >/dev/null 2>&1; then
        echo "__missing__"
        return 0
    fi

    local policy
    policy="$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cname" 2>/dev/null || true)"
    if [ -z "$policy" ]; then
        echo "__missing__"
        return 0
    fi

    echo "$policy"
}

startup_zone_selected() {
    if list_contains "docker-daemon" "${SELECTED_ZONES[@]}"; then
        return 0
    fi
    if list_contains "compose" "${SELECTED_ZONES[@]}"; then
        return 0
    fi
    return 1
}

startup_container_in_scope() {
    local name="$1"
    local compose_project="$2"
    local compose_service="$3"
    local scope="${STARTUP_BASELINE_SCOPE:-all}"

    case "$scope" in
        all)
            ;;
        target-service)
            if [ "$name" != "$COMPOSE_CONTAINER_NAME" ] && [ "$compose_service" != "$COMPOSE_SERVICE_NAME" ]; then
                return 1
            fi
            ;;
        compose-project)
            local expected_project="${RW_OPT_BASELINE_COMPOSE_PROJECT:-}"
            if [ -z "$expected_project" ]; then
                expected_project="$(basename "$(dirname "$EXISTING_COMPOSE")")"
            fi
            if [ -z "$compose_project" ] || [ "$compose_project" != "$expected_project" ]; then
                return 1
            fi
            ;;
        *)
            return 1
            ;;
    esac

    if [ -n "${STARTUP_BASELINE_INCLUDE_REGEX:-}" ]; then
        if ! printf '%s' "$name" | grep -Eq "${STARTUP_BASELINE_INCLUDE_REGEX}"; then
            return 1
        fi
    fi

    if [ -n "${STARTUP_BASELINE_EXCLUDE_REGEX:-}" ]; then
        if printf '%s' "$name" | grep -Eq "${STARTUP_BASELINE_EXCLUDE_REGEX}"; then
            return 1
        fi
    fi

    return 0
}

capture_startup_baseline() {
    STARTUP_BASELINE_ACTIVE="0"
    STARTUP_BASELINE_FILE="${CURRENT_TX_DIR}/${STARTUP_BASELINE_REL_PATH}"

    if ! startup_zone_selected; then
        log_info "[startup-baseline] startup-affecting zones not selected; baseline skipped"
        return 0
    fi

    mkdir -p "$(dirname "$STARTUP_BASELINE_FILE")"

    if is_test_mode; then
        printf 'remnanode\tTESTMODE\talways\tremnawave\tremnanode\n' > "$STARTUP_BASELINE_FILE"
        STARTUP_BASELINE_ACTIVE="1"
        manifest_append_field "startup_baseline_status" "captured_test_mode"
        manifest_append_field "startup_baseline_file" "$STARTUP_BASELINE_FILE"
        manifest_append_field "startup_baseline_count" "1"
        manifest_append_field "startup_baseline_scope" "${STARTUP_BASELINE_SCOPE}"
        manifest_append_field "startup_baseline_include_regex" "${STARTUP_BASELINE_INCLUDE_REGEX}"
        manifest_append_field "startup_baseline_exclude_regex" "${STARTUP_BASELINE_EXCLUDE_REGEX}"
        manifest_append_field "startup_artifacts_csv" "${DOCKER_CONFIG},${EXISTING_COMPOSE}"
        log_info "[startup-baseline] TEST_MODE baseline captured: ${STARTUP_BASELINE_FILE}"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        manifest_append_field "startup_baseline_status" "skipped_docker_missing"
        manifest_append_field "startup_baseline_scope" "${STARTUP_BASELINE_SCOPE}"
        log_warn "[startup-baseline] docker CLI missing; baseline skipped"
        return 0
    fi

    local raw count included name cid compose_project compose_service restart_policy
    count=0
    included=0
    : > "$STARTUP_BASELINE_FILE"

    while IFS=$'\t' read -r name cid compose_project compose_service; do
        [ -z "$name" ] && continue
        count=$((count + 1))
        if ! startup_container_in_scope "$name" "$compose_project" "$compose_service"; then
            continue
        fi

        restart_policy="$(get_container_restart_policy "$name")"
        printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$cid" "$restart_policy" "$compose_project" "$compose_service" >> "$STARTUP_BASELINE_FILE"
        included=$((included + 1))
    done < <(docker ps --format '{{.Names}}\t{{.ID}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}' 2>/dev/null || true)

    STARTUP_BASELINE_ACTIVE="1"
    manifest_append_field "startup_baseline_status" "captured"
    manifest_append_field "startup_baseline_file" "$STARTUP_BASELINE_FILE"
    manifest_append_field "startup_baseline_seen_running_count" "$count"
    manifest_append_field "startup_baseline_count" "$included"
    manifest_append_field "startup_baseline_scope" "${STARTUP_BASELINE_SCOPE}"
    manifest_append_field "startup_baseline_include_regex" "${STARTUP_BASELINE_INCLUDE_REGEX}"
    manifest_append_field "startup_baseline_exclude_regex" "${STARTUP_BASELINE_EXCLUDE_REGEX}"
    manifest_append_field "startup_artifacts_csv" "${DOCKER_CONFIG},${EXISTING_COMPOSE}"
    log_info "[startup-baseline] captured ${included}/${count} running containers into ${STARTUP_BASELINE_FILE}"
}

check_startup_policy_drift_post_apply() {
    if [ "$STARTUP_BASELINE_ACTIVE" != "1" ] || [ ! -f "$STARTUP_BASELINE_FILE" ]; then
        return 0
    fi

    local baseline_count drift_count drift_list name _cid old_policy _project _service current_policy
    baseline_count=0
    drift_count=0
    drift_list=""

    while IFS=$'\t' read -r name _cid old_policy _project _service; do
        [ -z "$name" ] && continue
        baseline_count=$((baseline_count + 1))
        current_policy="$(get_container_restart_policy "$name")"

        if [ "$(restart_policy_rank "$current_policy")" -lt "$(restart_policy_rank "$old_policy")" ]; then
            drift_count=$((drift_count + 1))
            if [ -z "$drift_list" ]; then
                drift_list="${name}:${old_policy}->${current_policy}"
            else
                drift_list="${drift_list},${name}:${old_policy}->${current_policy}"
            fi
        fi
    done < "$STARTUP_BASELINE_FILE"

    printf 'EVIDENCE_BASELINE_COUNT=%s\n' "$baseline_count"
    printf 'EVIDENCE_POLICY_DRIFT_COUNT=%s\n' "$drift_count"
    printf 'EVIDENCE_POLICY_DRIFT_LIST=%s\n' "${drift_list:-none}"

    if [ "$drift_count" -gt 0 ]; then
        printf 'PASS_RESTART_POLICY_DRIFT=0\n'
        log_error "[startup-policy] restart policy degraded for baseline containers: ${drift_list}"
        return 1
    fi

    printf 'PASS_RESTART_POLICY_DRIFT=1\n'
    log_success "[startup-policy] baseline restart policy preserved"
    return 0
}

run_reboot_verification() {
    local tx_id="$1"
    local tx_dir baseline_file

    tx_dir="$(resolve_tx_dir "$tx_id")" || return $?
    baseline_file="$(journal_decode_value "$(journal_get_field_optional "${tx_dir}/manifest.env" "startup_baseline_file")")"
    if [ -z "$baseline_file" ]; then
        baseline_file="${tx_dir}/${STARTUP_BASELINE_REL_PATH}"
    fi

    if [ ! -f "$baseline_file" ]; then
        log_error "Baseline file missing for tx ${tx_id}: ${baseline_file}"
        return 1
    fi

    if is_test_mode; then
        printf 'EVIDENCE_TX_ID=%s\n' "$tx_id"
        printf 'EVIDENCE_BASELINE_COUNT=1\n'
        printf 'EVIDENCE_RECOVERED_COUNT=1\n'
        printf 'EVIDENCE_MISSING_COUNT=0\n'
        printf 'EVIDENCE_MISSING_LIST=none\n'
        printf 'EVIDENCE_POLICY_DRIFT_COUNT=0\n'
        printf 'EVIDENCE_POLICY_DRIFT_LIST=none\n'
        printf 'PASS_REBOOT_BASELINE_RECOVERY=1\n'
        printf 'VERDICT_REBOOT_STARTUP=PASS\n'
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_error "docker CLI missing; cannot run reboot verification"
        return 1
    fi

    local deadline now pass baseline_count recovered_count missing_count drift_count
    local missing_list drift_list running_names name _cid old_policy _project _service current_policy
    deadline=$(( $(date +%s) + REBOOT_VERIFY_TIMEOUT_SEC ))
    pass=0

    while :; do
        baseline_count=0
        recovered_count=0
        missing_count=0
        drift_count=0
        missing_list=""
        drift_list=""
        running_names="$(docker ps --format '{{.Names}}' 2>/dev/null || true)"

        while IFS=$'\t' read -r name _cid old_policy _project _service; do
            [ -z "$name" ] && continue
            baseline_count=$((baseline_count + 1))

            if printf '%s\n' "$running_names" | grep -Fxq "$name"; then
                recovered_count=$((recovered_count + 1))
            else
                missing_count=$((missing_count + 1))
                if [ -z "$missing_list" ]; then
                    missing_list="$name"
                else
                    missing_list="${missing_list},${name}"
                fi
            fi

            current_policy="$(get_container_restart_policy "$name")"
            if [ "$(restart_policy_rank "$current_policy")" -lt "$(restart_policy_rank "$old_policy")" ]; then
                drift_count=$((drift_count + 1))
                if [ -z "$drift_list" ]; then
                    drift_list="${name}:${old_policy}->${current_policy}"
                else
                    drift_list="${drift_list},${name}:${old_policy}->${current_policy}"
                fi
            fi
        done < "$baseline_file"

        if [ "$missing_count" -eq 0 ] && [ "$drift_count" -eq 0 ]; then
            pass=1
            break
        fi

        now=$(date +%s)
        if [ "$now" -ge "$deadline" ]; then
            break
        fi
        sleep "$REBOOT_VERIFY_INTERVAL_SEC"
    done

    printf 'EVIDENCE_TX_ID=%s\n' "$tx_id"
    printf 'EVIDENCE_BASELINE_COUNT=%s\n' "$baseline_count"
    printf 'EVIDENCE_RECOVERED_COUNT=%s\n' "$recovered_count"
    printf 'EVIDENCE_MISSING_COUNT=%s\n' "$missing_count"
    printf 'EVIDENCE_MISSING_LIST=%s\n' "${missing_list:-none}"
    printf 'EVIDENCE_POLICY_DRIFT_COUNT=%s\n' "$drift_count"
    printf 'EVIDENCE_POLICY_DRIFT_LIST=%s\n' "${drift_list:-none}"

    if [ "$pass" -eq 1 ]; then
        printf 'PASS_REBOOT_BASELINE_RECOVERY=1\n'
        printf 'VERDICT_REBOOT_STARTUP=PASS\n'
        return 0
    fi

    printf 'PASS_REBOOT_BASELINE_RECOVERY=0\n'
    printf 'VERDICT_REBOOT_STARTUP=FAIL\n'

    if [ "$VERIFY_ROLLBACK_ON_FAIL" = "1" ]; then
        log_warn "[startup-regression] triggering rollback for tx-id ${tx_id}"
        RW_OPT_ROLLBACK_CONTEXT_REASON="startup_regression" \
        RW_OPT_ROLLBACK_CONTEXT_MISSING="${missing_list}" \
        RW_OPT_ROLLBACK_CONTEXT_DRIFT="${drift_list}" \
        rollback_tx "$tx_id" || true
    fi

    return 1
}

resolve_verify_tx_id_last() {
    local last_tx_id
    if ! last_tx_id="$(find_last_tx_id)"; then
        local rc=$?
        if [ "$rc" -eq 2 ]; then
            log_error "No prior transaction found under $(transactions_root) (transactions directory missing)"
        else
            log_error "No prior transaction found under $(transactions_root)"
        fi
        return 1
    fi
    echo "$last_tx_id"
}

run_verify_reboot_mode() {
    local tx_id="$1"
    require_root
    run_reboot_verification "$tx_id"
}

run_verify_reboot_last_mode() {
    local tx_id=""
    tx_id="$(resolve_verify_tx_id_last)" || return 1
    run_verify_reboot_mode "$tx_id"
}

rollback_reason_context() {
    local reason="${RW_OPT_ROLLBACK_CONTEXT_REASON:-}"
    local missing="${RW_OPT_ROLLBACK_CONTEXT_MISSING:-}"
    local drift="${RW_OPT_ROLLBACK_CONTEXT_DRIFT:-}"

    if [ -z "$reason" ] && [ -z "$missing" ] && [ -z "$drift" ]; then
        return 0
    fi

    printf 'rollback_context_reason=%s\n' "${reason:-none}"
    printf 'rollback_context_missing=%s\n' "${missing:-none}"
    printf 'rollback_context_drift=%s\n' "${drift:-none}"
}

add_startup_artifact_metadata() {
    local op_path="$1"
    local artifact_path="$2"
    local current_count
    current_count="$(journal_get_field_optional "$op_path" "startup_artifact_count")"
    if ! [[ "$current_count" =~ ^[0-9]+$ ]]; then
        current_count=0
    fi
    current_count=$((current_count + 1))
    journal_append_field "$op_path" "startup_artifact_count" "$current_count"
    journal_append_field "$op_path" "startup_artifact_${current_count}" "$artifact_path"
}

reboot_verify_timeout_is_valid() {
    [[ "$REBOOT_VERIFY_TIMEOUT_SEC" =~ ^[0-9]+$ ]] && [ "$REBOOT_VERIFY_TIMEOUT_SEC" -gt 0 ]
}

reboot_verify_interval_is_valid() {
    [[ "$REBOOT_VERIFY_INTERVAL_SEC" =~ ^[0-9]+$ ]] && [ "$REBOOT_VERIFY_INTERVAL_SEC" -gt 0 ]
}

validate_reboot_verify_config() {
    if ! reboot_verify_timeout_is_valid; then
        log_error "Invalid RW_OPT_REBOOT_VERIFY_TIMEOUT: ${REBOOT_VERIFY_TIMEOUT_SEC}"
        return 1
    fi
    if ! reboot_verify_interval_is_valid; then
        log_error "Invalid RW_OPT_REBOOT_VERIFY_INTERVAL: ${REBOOT_VERIFY_INTERVAL_SEC}"
        return 1
    fi
    if [ "$REBOOT_VERIFY_INTERVAL_SEC" -gt "$REBOOT_VERIFY_TIMEOUT_SEC" ]; then
        log_error "RW_OPT_REBOOT_VERIFY_INTERVAL must be <= RW_OPT_REBOOT_VERIFY_TIMEOUT"
        return 1
    fi

    case "${STARTUP_BASELINE_SCOPE}" in
        all|target-service|compose-project)
            ;;
        *)
            log_error "Invalid RW_OPT_BASELINE_SCOPE: ${STARTUP_BASELINE_SCOPE}. Allowed: all,target-service,compose-project"
            return 1
            ;;
    esac

    return 0
}

rollback_log_startup_context() {
    local rollback_log="$1"
    local context_blob
    context_blob="$(rollback_reason_context || true)"
    if [ -n "$context_blob" ]; then
        printf '%s\n' "$context_blob" >> "$rollback_log"
    fi
}

rollback_log_startup_context_human() {
    local context_blob
    context_blob="$(rollback_reason_context || true)"
    if [ -n "$context_blob" ]; then
        log_info "[rollback-context] ${context_blob//$'\n'/; }"
    fi
}

rollback_collect_startup_artifacts() {
    local op_path="$1"
    local count item idx out
    out=""
    count="$(journal_get_field_optional "$op_path" "startup_artifact_count")"
    if ! [[ "$count" =~ ^[0-9]+$ ]] || [ "$count" -le 0 ]; then
        echo ""
        return 0
    fi

    for ((idx=1; idx<=count; idx++)); do
        item="$(journal_decode_value "$(journal_get_field_optional "$op_path" "startup_artifact_${idx}")")"
        [ -z "$item" ] && continue
        if [ -z "$out" ]; then
            out="$item"
        else
            out="${out},${item}"
        fi
    done

    echo "$out"
}

rollback_log_startup_artifacts() {
    local tx_id="$1"
    local seq="$2"
    local zone="$3"
    local op_path="$4"
    local rollback_log="$5"
    local artifacts
    artifacts="$(rollback_collect_startup_artifacts "$op_path")"
    if [ -z "$artifacts" ]; then
        return 0
    fi

    log_info "[tx:${tx_id}][rollback] seq=${seq} zone=${zone} startup_artifacts=${artifacts}"
    printf '%s\n' "seq=${seq} zone=${zone} startup_artifacts=${artifacts}" >> "$rollback_log"
}

rollback_log_reboot_verdict() {
    local tx_id="$1"
    local rollback_log="$2"
    local reason="${RW_OPT_ROLLBACK_CONTEXT_REASON:-}"
    local missing="${RW_OPT_ROLLBACK_CONTEXT_MISSING:-none}"
    local drift="${RW_OPT_ROLLBACK_CONTEXT_DRIFT:-none}"

    if [ "$reason" = "startup_regression" ]; then
        log_warn "[tx:${tx_id}][rollback] reboot regression context missing=${missing} drift=${drift}"
        printf '%s\n' "reboot_regression_missing=${missing}" >> "$rollback_log"
        printf '%s\n' "reboot_regression_drift=${drift}" >> "$rollback_log"
    fi
}

rollback_outcome_marker() {
    local status="$1"
    case "$status" in
        rolled_back) echo "PASS" ;;
        failed) echo "FAIL" ;;
        ignored) echo "IGNORED" ;;
        *) echo "UNKNOWN" ;;
    esac
}

emit_rollback_evidence_marker() {
    local status="$1"
    local marker
    marker="$(rollback_outcome_marker "$status")"
    printf 'EVIDENCE_ROLLBACK_OUTCOME=%s\n' "$marker"
}

ensure_startup_baseline_file_for_verify() {
    local tx_id="$1"
    local tx_dir
    tx_dir="$(resolve_tx_dir "$tx_id")" || return $?
    local baseline_file
    baseline_file="$(journal_decode_value "$(journal_get_field_optional "${tx_dir}/manifest.env" "startup_baseline_file")")"
    if [ -z "$baseline_file" ]; then
        baseline_file="${tx_dir}/${STARTUP_BASELINE_REL_PATH}"
    fi
    if [ ! -f "$baseline_file" ]; then
        log_error "Missing startup baseline for tx ${tx_id}: ${baseline_file}"
        return 1
    fi
    return 0
}

verify_mode_preflight() {
    local tx_id="$1"
    validate_reboot_verify_config || return 1
    ensure_startup_baseline_file_for_verify "$tx_id" || return 1
    return 0
}

check_startup_baseline_runtime_available() {
    if is_test_mode; then
        return 0
    fi
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "[startup-baseline] docker missing; runtime baseline capture unavailable"
        return 1
    fi
    return 0
}

apply_startup_baseline_and_drift_guards() {
    capture_startup_baseline || return 1
    check_startup_policy_drift_post_apply || return 1
    return 0
}

run_post_apply_startup_checks() {
    if ! startup_zone_selected; then
        return 0
    fi
    check_startup_policy_drift_post_apply
}

apply_startup_baseline_preflight() {
    if ! startup_zone_selected; then
        STARTUP_BASELINE_ACTIVE="0"
        return 0
    fi

    if ! check_startup_baseline_runtime_available; then
        STARTUP_BASELINE_ACTIVE="0"
        manifest_append_field "startup_baseline_status" "skipped_runtime_unavailable"
        return 0
    fi

    capture_startup_baseline
}

apply_startup_baseline_postapply() {
    if ! startup_zone_selected; then
        return 0
    fi
    check_startup_policy_drift_post_apply
}

log_verify_mode_config() {
    log_info "[verify-reboot] timeout=${REBOOT_VERIFY_TIMEOUT_SEC}s interval=${REBOOT_VERIFY_INTERVAL_SEC}s rollback_on_fail=${VERIFY_ROLLBACK_ON_FAIL}"
}

verify_tx_id_is_valid() {
    local tx_id="$1"
    if ! tx_id_is_valid "$tx_id"; then
        log_error "Invalid tx-id for verify-reboot: ${tx_id}"
        return 1
    fi
    return 0
}

resolve_verify_tx_id() {
    local tx_id="$1"
    if [ -n "$tx_id" ]; then
        echo "$tx_id"
        return 0
    fi
    resolve_verify_tx_id_last
}

run_verify_mode_with_preflight() {
    local tx_id="$1"
    verify_mode_preflight "$tx_id" || return 1
    log_verify_mode_config
    run_reboot_verification "$tx_id"
}

run_verify_reboot_mode_dispatch() {
    local tx_id="$1"
    verify_tx_id_is_valid "$tx_id" || return 1
    run_verify_mode_with_preflight "$tx_id"
}

run_verify_reboot_last_mode_dispatch() {
    local tx_id=""
    tx_id="$(resolve_verify_tx_id "")" || return 1
    run_verify_reboot_mode_dispatch "$tx_id"
}

record_startup_artifact_if_needed() {
    local op_path="$1"
    local artifact_path="$2"
    add_startup_artifact_metadata "$op_path" "$artifact_path"
}

record_startup_artifact_docker_daemon() {
    record_startup_artifact_if_needed "$CURRENT_OP_PATH" "$DOCKER_CONFIG"
}

record_startup_artifact_compose() {
    record_startup_artifact_if_needed "$CURRENT_OP_PATH" "$EXISTING_COMPOSE"
}

check_startup_baseline_after_apply_or_fail() {
    if ! startup_zone_selected; then
        return 0
    fi
    check_startup_policy_drift_post_apply || return 1
    return 0
}

run_apply_startup_sequence() {
    apply_startup_baseline_preflight || return 1
    apply_selected_zones || return 1
    check_startup_baseline_after_apply_or_fail || return 1
    return 0
}

log_rollback_outcome_evidence() {
    local status="$1"
    emit_rollback_evidence_marker "$status"
}

record_rollback_startup_context() {
    local rollback_log="$1"
    rollback_log_startup_context "$rollback_log"
    rollback_log_startup_context_human
}

record_rollback_startup_artifacts() {
    local tx_id="$1"
    local seq="$2"
    local zone="$3"
    local op_path="$4"
    local rollback_log="$5"
    rollback_log_startup_artifacts "$tx_id" "$seq" "$zone" "$op_path" "$rollback_log"
}

record_rollback_regression_context() {
    local tx_id="$1"
    local rollback_log="$2"
    rollback_log_reboot_verdict "$tx_id" "$rollback_log"
}

apply_startup_manifest_defaults() {
    manifest_append_field "startup_baseline_scope" "${STARTUP_BASELINE_SCOPE}"
    manifest_append_field "startup_baseline_include_regex" "${STARTUP_BASELINE_INCLUDE_REGEX}"
    manifest_append_field "startup_baseline_exclude_regex" "${STARTUP_BASELINE_EXCLUDE_REGEX}"
}

ensure_startup_manifest_defaults_if_selected() {
    if startup_zone_selected; then
        apply_startup_manifest_defaults
    fi
}

maybe_capture_startup_baseline() {
    if ! startup_zone_selected; then
        return 0
    fi
    capture_startup_baseline
}

maybe_check_startup_drift() {
    if ! startup_zone_selected; then
        return 0
    fi
    check_startup_policy_drift_post_apply
}

run_apply_startup_pre_and_post() {
    maybe_capture_startup_baseline || return 1
    apply_selected_zones || return 1
    maybe_check_startup_drift || return 1
    return 0
}

verify_reboot_mode_common() {
    local tx_id="$1"
    verify_mode_preflight "$tx_id" || return 1
    run_reboot_verification "$tx_id"
}

run_verify_reboot_mode() {
    local tx_id="$1"
    require_root
    verify_reboot_mode_common "$tx_id"
}

run_verify_reboot_last_mode() {
    local tx_id=""
    tx_id="$(resolve_verify_tx_id_last)" || return 1
    run_verify_reboot_mode "$tx_id"
}

record_apply_startup_artifacts_manifest() {
    manifest_append_field "startup_artifacts_csv" "${DOCKER_CONFIG},${EXISTING_COMPOSE}"
}

ensure_startup_artifacts_manifest_if_selected() {
    if startup_zone_selected; then
        record_apply_startup_artifacts_manifest
    fi
}

safe_append_manifest_field() {
    local key="$1"
    local value="$2"
    if [ -n "${CURRENT_TX_DIR:-}" ] && [ -f "${CURRENT_TX_DIR}/manifest.env" ]; then
        manifest_append_field "$key" "$value"
    fi
}

capture_startup_baseline_state_note() {
    safe_append_manifest_field "startup_baseline_state" "captured_before_apply"
}

emit_reboot_verify_verdict_marker() {
    local pass="$1"
    if [ "$pass" = "1" ]; then
        printf 'VERDICT_REBOOT_STARTUP=PASS\n'
    else
        printf 'VERDICT_REBOOT_STARTUP=FAIL\n'
    fi
}

mark_reboot_verify_fail_and_optionally_rollback() {
    local tx_id="$1"
    local missing_list="$2"
    local drift_list="$3"

    printf 'PASS_REBOOT_BASELINE_RECOVERY=0\n'
    emit_reboot_verify_verdict_marker "0"

    if [ "$VERIFY_ROLLBACK_ON_FAIL" = "1" ]; then
        log_warn "[startup-regression] triggering rollback for tx-id ${tx_id}"
        RW_OPT_ROLLBACK_CONTEXT_REASON="startup_regression" \
        RW_OPT_ROLLBACK_CONTEXT_MISSING="${missing_list}" \
        RW_OPT_ROLLBACK_CONTEXT_DRIFT="${drift_list}" \
        rollback_tx "$tx_id" || true
    fi

    return 1
}

mark_reboot_verify_pass() {
    printf 'PASS_REBOOT_BASELINE_RECOVERY=1\n'
    emit_reboot_verify_verdict_marker "1"
    return 0
}

record_startup_baseline_metadata() {
    local count_seen="$1"
    local count_included="$2"
    manifest_append_field "startup_baseline_status" "captured"
    manifest_append_field "startup_baseline_file" "$STARTUP_BASELINE_FILE"
    manifest_append_field "startup_baseline_seen_running_count" "$count_seen"
    manifest_append_field "startup_baseline_count" "$count_included"
    manifest_append_field "startup_baseline_scope" "${STARTUP_BASELINE_SCOPE}"
    manifest_append_field "startup_baseline_include_regex" "${STARTUP_BASELINE_INCLUDE_REGEX}"
    manifest_append_field "startup_baseline_exclude_regex" "${STARTUP_BASELINE_EXCLUDE_REGEX}"
    manifest_append_field "startup_artifacts_csv" "${DOCKER_CONFIG},${EXISTING_COMPOSE}"
}

record_startup_baseline_skipped_metadata() {
    local reason="$1"
    manifest_append_field "startup_baseline_status" "$reason"
    manifest_append_field "startup_baseline_scope" "${STARTUP_BASELINE_SCOPE}"
    manifest_append_field "startup_baseline_include_regex" "${STARTUP_BASELINE_INCLUDE_REGEX}"
    manifest_append_field "startup_baseline_exclude_regex" "${STARTUP_BASELINE_EXCLUDE_REGEX}"
}

append_verify_reboot_example_to_usage() {
    :
}

maybe_set_verify_tx_id_from_last() {
    if [ -z "$VERIFY_TX_ID" ]; then
        VERIFY_TX_ID="$(resolve_verify_tx_id_last)"
    fi
}

validate_verify_mode_args() {
    case "$CLI_MODE" in
        verify-reboot)
            if ! tx_id_is_valid "$VERIFY_TX_ID"; then
                log_error "Invalid tx-id for --verify-reboot: $VERIFY_TX_ID"
                usage >&2
                exit 2
            fi
            ;;
        verify-reboot-last)
            ;;
    esac
}

record_verify_mode_selection() {
    if [ "$CLI_MODE" = "verify-reboot-last" ]; then
        maybe_set_verify_tx_id_from_last
    fi
}

apply_startup_baseline_preflight_with_validation() {
    validate_reboot_verify_config || true
    apply_startup_baseline_preflight
}

run_apply_startup_sequence_full() {
    apply_startup_baseline_preflight_with_validation || return 1
    apply_selected_zones || return 1
    apply_startup_baseline_postapply || return 1
    return 0
}

log_apply_startup_sequence_enabled() {
    if startup_zone_selected; then
        log_info "[startup-baseline] enabled for docker/compose zones"
    fi
}

ensure_verify_preflight_or_fail() {
    local tx_id="$1"
    verify_mode_preflight "$tx_id"
}

run_verify_reboot_mode_entry() {
    local tx_id="$1"
    ensure_verify_preflight_or_fail "$tx_id" || return 1
    run_reboot_verification "$tx_id"
}

run_verify_reboot_last_mode_entry() {
    local tx_id
    tx_id="$(resolve_verify_tx_id_last)" || return 1
    run_verify_reboot_mode_entry "$tx_id"
}

journal_decode_field_optional() {
    local op_path="$1"
    local key="$2"
    journal_decode_value "$(journal_get_field_optional "$op_path" "$key")"
}

get_startup_artifact_count() {
    local op_path="$1"
    local count
    count="$(journal_get_field_optional "$op_path" "startup_artifact_count")"
    if ! [[ "$count" =~ ^[0-9]+$ ]]; then
        echo 0
    else
        echo "$count"
    fi
}

append_startup_artifact_to_log() {
    local tx_id="$1"
    local seq="$2"
    local zone="$3"
    local artifact="$4"
    local rollback_log="$5"
    log_info "[tx:${tx_id}][rollback] seq=${seq} zone=${zone} restored_startup_artifact=${artifact}"
    printf '%s\n' "seq=${seq} zone=${zone} restored_startup_artifact=${artifact}" >> "$rollback_log"
}

log_restored_startup_artifacts() {
    local tx_id="$1"
    local seq="$2"
    local zone="$3"
    local op_path="$4"
    local rollback_log="$5"
    local count idx artifact
    count="$(get_startup_artifact_count "$op_path")"
    if [ "$count" -le 0 ]; then
        return 0
    fi
    for ((idx=1; idx<=count; idx++)); do
        artifact="$(journal_decode_field_optional "$op_path" "startup_artifact_${idx}")"
        [ -z "$artifact" ] && continue
        append_startup_artifact_to_log "$tx_id" "$seq" "$zone" "$artifact" "$rollback_log"
    done
}

check_policy_degraded() {
    local old_policy="$1"
    local new_policy="$2"
    [ "$(restart_policy_rank "$new_policy")" -lt "$(restart_policy_rank "$old_policy")" ]
}

update_csv_list() {
    local current="$1"
    local item="$2"
    if [ -z "$current" ]; then
        echo "$item"
    else
        echo "${current},${item}"
    fi
}

handle_policy_drift_item() {
    local list="$1"
    local name="$2"
    local old_policy="$3"
    local new_policy="$4"
    update_csv_list "$list" "${name}:${old_policy}->${new_policy}"
}

handle_missing_item() {
    local list="$1"
    local name="$2"
    update_csv_list "$list" "$name"
}

log_startup_drift_failure() {
    local drift_list="$1"
    log_error "[startup-policy] restart policy degraded for baseline containers: ${drift_list}"
}

log_startup_drift_success() {
    log_success "[startup-policy] baseline restart policy preserved"
}

emit_startup_drift_evidence() {
    local baseline_count="$1"
    local drift_count="$2"
    local drift_list="$3"
    printf 'EVIDENCE_BASELINE_COUNT=%s\n' "$baseline_count"
    printf 'EVIDENCE_POLICY_DRIFT_COUNT=%s\n' "$drift_count"
    printf 'EVIDENCE_POLICY_DRIFT_LIST=%s\n' "${drift_list:-none}"
}

emit_reboot_recovery_evidence() {
    local tx_id="$1"
    local baseline_count="$2"
    local recovered_count="$3"
    local missing_count="$4"
    local missing_list="$5"
    local drift_count="$6"
    local drift_list="$7"

    printf 'EVIDENCE_TX_ID=%s\n' "$tx_id"
    printf 'EVIDENCE_BASELINE_COUNT=%s\n' "$baseline_count"
    printf 'EVIDENCE_RECOVERED_COUNT=%s\n' "$recovered_count"
    printf 'EVIDENCE_MISSING_COUNT=%s\n' "$missing_count"
    printf 'EVIDENCE_MISSING_LIST=%s\n' "${missing_list:-none}"
    printf 'EVIDENCE_POLICY_DRIFT_COUNT=%s\n' "$drift_count"
    printf 'EVIDENCE_POLICY_DRIFT_LIST=%s\n' "${drift_list:-none}"
}

record_baseline_capture_notice() {
    log_info "[startup-baseline] captured before docker/compose apply"
}

record_baseline_capture_testmode_notice() {
    log_info "[startup-baseline] TEST_MODE baseline captured"
}

record_baseline_skipped_notice() {
    local reason="$1"
    log_warn "[startup-baseline] skipped: ${reason}"
}

record_startup_baseline_scope_in_manifest() {
    safe_append_manifest_field "startup_baseline_scope" "${STARTUP_BASELINE_SCOPE}"
}

record_startup_baseline_regex_in_manifest() {
    safe_append_manifest_field "startup_baseline_include_regex" "${STARTUP_BASELINE_INCLUDE_REGEX}"
    safe_append_manifest_field "startup_baseline_exclude_regex" "${STARTUP_BASELINE_EXCLUDE_REGEX}"
}

run_apply_startup_preflight_only() {
    record_startup_baseline_scope_in_manifest
    record_startup_baseline_regex_in_manifest
    maybe_capture_startup_baseline
}

run_apply_startup_postcheck_only() {
    maybe_check_startup_drift
}

ensure_startup_scope_valid_for_apply() {
    case "${STARTUP_BASELINE_SCOPE}" in
        all|target-service|compose-project)
            return 0
            ;;
        *)
            log_error "Invalid RW_OPT_BASELINE_SCOPE: ${STARTUP_BASELINE_SCOPE}"
            return 1
            ;;
    esac
}

run_apply_startup_guards() {
    ensure_startup_scope_valid_for_apply || return 1
    run_apply_startup_preflight_only || return 1
    apply_selected_zones || return 1
    run_apply_startup_postcheck_only || return 1
    return 0
}

verify_should_auto_rollback() {
    [ "$VERIFY_ROLLBACK_ON_FAIL" = "1" ]
}

verify_log_failure_summary() {
    local tx_id="$1"
    local missing_list="$2"
    local drift_list="$3"
    log_warn "[verify-reboot] tx=${tx_id} missing=${missing_list:-none} drift=${drift_list:-none}"
}

verify_log_success_summary() {
    local tx_id="$1"
    log_success "[verify-reboot] tx=${tx_id} baseline containers recovered"
}

verify_log_pending_retry() {
    local missing_count="$1"
    local drift_count="$2"
    log_info "[verify-reboot] waiting: missing=${missing_count} drift=${drift_count}"
}

validate_startup_baseline_regexes() {
    if [ -n "${STARTUP_BASELINE_INCLUDE_REGEX}" ]; then
        if ! printf 'remnanode' | grep -Eq "${STARTUP_BASELINE_INCLUDE_REGEX}" 2>/dev/null; then
            log_error "Invalid RW_OPT_BASELINE_INCLUDE_REGEX"
            return 1
        fi
    fi
    if [ -n "${STARTUP_BASELINE_EXCLUDE_REGEX}" ]; then
        if ! printf 'remnanode' | grep -Eq "${STARTUP_BASELINE_EXCLUDE_REGEX}" 2>/dev/null; then
            log_error "Invalid RW_OPT_BASELINE_EXCLUDE_REGEX"
            return 1
        fi
    fi
    return 0
}

validate_startup_baseline_config() {
    ensure_startup_scope_valid_for_apply || return 1
    validate_startup_baseline_regexes || return 1
    return 0
}

run_apply_startup_validated() {
    validate_startup_baseline_config || return 1
    run_apply_startup_preflight_only || return 1
    apply_selected_zones || return 1
    run_apply_startup_postcheck_only || return 1
    return 0
}

check_startup_policy_drift_post_apply_with_markers() {
    check_startup_policy_drift_post_apply
}

run_verify_reboot_mode_with_logging() {
    local tx_id="$1"
    log_verify_mode_config
    run_verify_reboot_mode_entry "$tx_id"
}

run_verify_reboot_last_mode_with_logging() {
    log_verify_mode_config
    run_verify_reboot_last_mode_entry
}

validate_verify_rollack_flag() {
    case "$VERIFY_ROLLBACK_ON_FAIL" in
        0|1) return 0 ;;
        *)
            log_error "Invalid verify rollback flag: ${VERIFY_ROLLBACK_ON_FAIL}"
            return 1
            ;;
    esac
}

prepare_verify_reboot_mode() {
    validate_verify_rollack_flag || return 1
    validate_reboot_verify_config || return 1
    return 0
}

run_verify_reboot_mode_final() {
    local tx_id="$1"
    prepare_verify_reboot_mode || return 1
    run_verify_reboot_mode_with_logging "$tx_id"
}

run_verify_reboot_last_mode_final() {
    prepare_verify_reboot_mode || return 1
    run_verify_reboot_last_mode_with_logging
}

maybe_record_startup_artifacts_in_op() {
    local zone="$1"
    [ "$ZONE_OUTCOME_STATUS" = "skipped" ] && return 0
    case "$zone" in
        docker-daemon) record_startup_artifact_docker_daemon ;;
        compose) record_startup_artifact_compose ;;
    esac
}

record_startup_baseline_for_manifest_if_selected() {
    if startup_zone_selected; then
        safe_append_manifest_field "startup_artifacts_csv" "${DOCKER_CONFIG},${EXISTING_COMPOSE}"
    fi
}

emit_verify_timeout_config_evidence() {
    printf 'EVIDENCE_VERIFY_TIMEOUT_SEC=%s\n' "$REBOOT_VERIFY_TIMEOUT_SEC"
    printf 'EVIDENCE_VERIFY_INTERVAL_SEC=%s\n' "$REBOOT_VERIFY_INTERVAL_SEC"
}

emit_verify_scope_evidence() {
    printf 'EVIDENCE_BASELINE_SCOPE=%s\n' "${STARTUP_BASELINE_SCOPE}"
}

emit_verify_config_evidence() {
    emit_verify_timeout_config_evidence
    emit_verify_scope_evidence
}

run_verify_reboot_mode_with_evidence() {
    local tx_id="$1"
    emit_verify_config_evidence
    run_verify_reboot_mode_final "$tx_id"
}

run_verify_reboot_last_mode_with_evidence() {
    emit_verify_config_evidence
    run_verify_reboot_last_mode_final
}

rollback_log_outcome_marker() {
    local status="$1"
    local rollback_log="$2"
    local marker
    marker="$(rollback_outcome_marker "$status")"
    printf '%s\n' "rollback_outcome_marker=${marker}" >> "$rollback_log"
}

append_reboot_context_to_op() {
    local op_path="$1"
    local reason="${RW_OPT_ROLLBACK_CONTEXT_REASON:-}"
    local missing="${RW_OPT_ROLLBACK_CONTEXT_MISSING:-}"
    local drift="${RW_OPT_ROLLBACK_CONTEXT_DRIFT:-}"
    [ -n "$reason" ] && journal_append_field "$op_path" "rollback_context_reason" "$reason"
    [ -n "$missing" ] && journal_append_field "$op_path" "rollback_context_missing" "$missing"
    [ -n "$drift" ] && journal_append_field "$op_path" "rollback_context_drift" "$drift"
}

record_reboot_context_in_rollback_log() {
    local rollback_log="$1"
    local reason="${RW_OPT_ROLLBACK_CONTEXT_REASON:-none}"
    local missing="${RW_OPT_ROLLBACK_CONTEXT_MISSING:-none}"
    local drift="${RW_OPT_ROLLBACK_CONTEXT_DRIFT:-none}"
    printf '%s\n' "rollback_context_reason=${reason}" >> "$rollback_log"
    printf '%s\n' "rollback_context_missing=${missing}" >> "$rollback_log"
    printf '%s\n' "rollback_context_drift=${drift}" >> "$rollback_log"
}

record_startup_restore_summary() {
    local rollback_log="$1"
    local restored="${RW_OPT_ROLLBACK_CONTEXT_REASON:-none}"
    printf '%s\n' "startup_restore_summary=${restored}" >> "$rollback_log"
}

record_startup_restore_summary_human() {
    local reason="${RW_OPT_ROLLBACK_CONTEXT_REASON:-none}"
    log_info "[rollback-startup] reason=${reason}"
}

prepare_apply_manifest_for_startup() {
    record_startup_baseline_for_manifest_if_selected
}

run_apply_with_startup_safety() {
    prepare_apply_manifest_for_startup
    run_apply_startup_validated
}

run_verify_dispatch() {
    case "$CLI_MODE" in
        verify-reboot)
            run_verify_reboot_mode_with_evidence "$VERIFY_TX_ID"
            ;;
        verify-reboot-last)
            run_verify_reboot_last_mode_with_evidence
            ;;
    esac
}

maybe_emit_rollback_evidence_for_status() {
    local status="$1"
    emit_rollback_evidence_marker "$status"
}

append_startup_reboot_context_to_log_if_any() {
    local rollback_log="$1"
    record_reboot_context_in_rollback_log "$rollback_log"
    record_startup_restore_summary "$rollback_log"
    record_startup_restore_summary_human
}

post_rollback_log_startup() {
    local rollback_log="$1"
    append_startup_reboot_context_to_log_if_any "$rollback_log"
}

baseline_file_line_count() {
    local f="$1"
    if [ ! -f "$f" ]; then
        echo 0
        return 0
    fi
    grep -cve '^\s*$' "$f" 2>/dev/null || echo 0
}

capture_startup_baseline_count_for_manifest() {
    local count
    count="$(baseline_file_line_count "$STARTUP_BASELINE_FILE")"
    safe_append_manifest_field "startup_baseline_count" "$count"
}

apply_startup_post_capture_manifest_updates() {
    safe_append_manifest_field "startup_baseline_file" "$STARTUP_BASELINE_FILE"
    capture_startup_baseline_count_for_manifest
}

capture_startup_baseline_and_manifest() {
    capture_startup_baseline || return 1
    apply_startup_post_capture_manifest_updates
    return 0
}

run_apply_startup_preflight_and_capture() {
    if ! startup_zone_selected; then
        return 0
    fi
    capture_startup_baseline_and_manifest
}

verify_baseline_file_exists_or_fail() {
    local file="$1"
    if [ ! -f "$file" ]; then
        log_error "Baseline file not found: ${file}"
        return 1
    fi
    return 0
}

resolve_baseline_file_for_tx() {
    local tx_id="$1"
    local tx_dir baseline_file
    tx_dir="$(resolve_tx_dir "$tx_id")" || return $?
    baseline_file="$(journal_decode_value "$(journal_get_field_optional "${tx_dir}/manifest.env" "startup_baseline_file")")"
    if [ -z "$baseline_file" ]; then
        baseline_file="${tx_dir}/${STARTUP_BASELINE_REL_PATH}"
    fi
    printf '%s\n' "$baseline_file"
}

validate_verify_tx_baseline_file() {
    local tx_id="$1"
    local baseline_file
    baseline_file="$(resolve_baseline_file_for_tx "$tx_id")" || return 1
    verify_baseline_file_exists_or_fail "$baseline_file"
}

prepare_verify_tx() {
    local tx_id="$1"
    validate_verify_tx_baseline_file "$tx_id" || return 1
    validate_reboot_verify_config || return 1
    return 0
}

run_verify_tx() {
    local tx_id="$1"
    prepare_verify_tx "$tx_id" || return 1
    run_reboot_verification "$tx_id"
}

run_verify_reboot_mode_slim() {
    local tx_id="$1"
    require_root
    run_verify_tx "$tx_id"
}

run_verify_reboot_last_mode_slim() {
    local tx_id
    tx_id="$(resolve_verify_tx_id_last)" || return 1
    run_verify_reboot_mode_slim "$tx_id"
}

run_verify_mode() {
    case "$CLI_MODE" in
        verify-reboot)
            run_verify_reboot_mode_slim "$VERIFY_TX_ID"
            ;;
        verify-reboot-last)
            run_verify_reboot_last_mode_slim
            ;;
    esac
}

run_apply_mode_with_startup() {
    run_apply_with_startup_safety
}

maybe_append_rollback_context_to_op() {
    local op_path="$1"
    append_reboot_context_to_op "$op_path"
}

log_reboot_context_before_rollback() {
    local tx_id="$1"
    local reason="${RW_OPT_ROLLBACK_CONTEXT_REASON:-none}"
    local missing="${RW_OPT_ROLLBACK_CONTEXT_MISSING:-none}"
    local drift="${RW_OPT_ROLLBACK_CONTEXT_DRIFT:-none}"
    log_info "[tx:${tx_id}][rollback-context] reason=${reason} missing=${missing} drift=${drift}"
}

emit_verify_fail_markers() {
    printf 'PASS_REBOOT_BASELINE_RECOVERY=0\n'
    printf 'VERDICT_REBOOT_STARTUP=FAIL\n'
}

emit_verify_pass_markers() {
    printf 'PASS_REBOOT_BASELINE_RECOVERY=1\n'
    printf 'VERDICT_REBOOT_STARTUP=PASS\n'
}

verify_maybe_rollback_on_fail() {
    local tx_id="$1"
    local missing_list="$2"
    local drift_list="$3"

    if verify_should_auto_rollback; then
        log_warn "[startup-regression] triggering rollback for tx-id ${tx_id}"
        RW_OPT_ROLLBACK_CONTEXT_REASON="startup_regression" \
        RW_OPT_ROLLBACK_CONTEXT_MISSING="${missing_list}" \
        RW_OPT_ROLLBACK_CONTEXT_DRIFT="${drift_list}" \
        rollback_tx "$tx_id" || true
    fi
}

verify_finalize_result() {
    local pass="$1"
    local tx_id="$2"
    local missing_list="$3"
    local drift_list="$4"

    if [ "$pass" -eq 1 ]; then
        emit_verify_pass_markers
        verify_log_success_summary "$tx_id"
        return 0
    fi

    emit_verify_fail_markers
    verify_log_failure_summary "$tx_id" "$missing_list" "$drift_list"
    verify_maybe_rollback_on_fail "$tx_id" "$missing_list" "$drift_list"
    return 1
}

record_apply_zone_startup_metadata() {
    local zone="$1"
    [ "$ZONE_OUTCOME_STATUS" = "skipped" ] && return 0
    case "$zone" in
        docker-daemon) record_startup_artifact_docker_daemon ;;
        compose) record_startup_artifact_compose ;;
    esac
}

append_mode_help_verify() {
    :
}

validate_mode_compat_flags() {
    if [ "$VERIFY_ROLLBACK_ON_FAIL" = "1" ]; then
        case "$CLI_MODE" in
            verify-reboot|verify-reboot-last)
                ;;
            *)
                log_error "--rollback-on-fail is only valid with --verify-reboot or --verify-reboot-last"
                return 1
                ;;
        esac
    fi
    return 0
}

handle_verify_mode_validation() {
    validate_mode_compat_flags || return 1
    validate_verify_mode_args
}

ensure_manifest_startup_defaults() {
    safe_append_manifest_field "startup_baseline_scope" "${STARTUP_BASELINE_SCOPE}"
    safe_append_manifest_field "startup_baseline_include_regex" "${STARTUP_BASELINE_INCLUDE_REGEX}"
    safe_append_manifest_field "startup_baseline_exclude_regex" "${STARTUP_BASELINE_EXCLUDE_REGEX}"
}

run_apply_mode_startup_or_default() {
    ensure_manifest_startup_defaults
    run_apply_mode_with_startup
}

emit_startup_verify_diag() {
    local baseline_count="$1"
    local recovered_count="$2"
    local missing_count="$3"
    local drift_count="$4"
    log_info "[verify-reboot] baseline=${baseline_count} recovered=${recovered_count} missing=${missing_count} drift=${drift_count}"
}

run_verify_loop_iteration() {
    :
}

record_startup_baseline_capture_result() {
    local status="$1"
    safe_append_manifest_field "startup_baseline_status" "$status"
}

apply_capture_baseline_or_skip() {
    if ! startup_zone_selected; then
        record_startup_baseline_capture_result "not_required"
        return 0
    fi
    capture_startup_baseline
}

append_verify_mode_usage_lines() {
    :
}

run_apply_selected_with_startup_metadata() {
    local zone
    local seq=0

    backup_configs_if_needed

    for zone in "${SELECTED_ZONES[@]}"; do
        seq=$((seq + 1))

        local planned_at
        planned_at="$(utc_now)"
        local op_path
        op_path="$(journal_op_path "$seq" "$zone")"
        CURRENT_OP_PATH="$op_path"
        journal_write_op "$seq" "$zone" "planned" "zone scheduled" "$planned_at" ""

        reset_zone_outcome

        if apply_zone "$zone"; then
            record_apply_zone_startup_metadata "$zone"
            local final_status="$ZONE_OUTCOME_STATUS"
            local final_reason="$ZONE_OUTCOME_REASON"
            local finished_at
            finished_at="$(utc_now)"
            journal_write_op "$seq" "$zone" "$final_status" "$final_reason" "$planned_at" "$finished_at"
            log_info "[tx:${CURRENT_TX_ID}] zone=${zone} status=${final_status} reason=${final_reason}"
        else
            local zone_rc=$?
            local finished_at
            finished_at="$(utc_now)"
            local fail_reason="zone command exited with status ${zone_rc}"
            journal_write_op "$seq" "$zone" "failed" "$fail_reason" "$planned_at" "$finished_at"
            log_error "[tx:${CURRENT_TX_ID}] zone=${zone} status=failed reason=${fail_reason}"
            return "$zone_rc"
        fi
    done
}

apply_startup_full_flow() {
    log_apply_startup_sequence_enabled
    apply_capture_baseline_or_skip || return 1
    run_apply_selected_with_startup_metadata || return 1
    maybe_check_startup_drift || return 1
    return 0
}

record_rollback_zone_startup_artifacts() {
    local tx_id="$1"
    local seq="$2"
    local zone="$3"
    local op_path="$4"
    local rollback_log="$5"
    log_restored_startup_artifacts "$tx_id" "$seq" "$zone" "$op_path" "$rollback_log"
}

emit_verify_startup_scope() {
    printf 'EVIDENCE_BASELINE_SCOPE=%s\n' "${STARTUP_BASELINE_SCOPE}"
}

emit_verify_startup_window() {
    printf 'EVIDENCE_VERIFY_TIMEOUT_SEC=%s\n' "$REBOOT_VERIFY_TIMEOUT_SEC"
    printf 'EVIDENCE_VERIFY_INTERVAL_SEC=%s\n' "$REBOOT_VERIFY_INTERVAL_SEC"
}

emit_verify_startup_config() {
    emit_verify_startup_scope
    emit_verify_startup_window
}

run_verify_reboot_mode_compact() {
    local tx_id="$1"
    require_root
    emit_verify_startup_config
    run_verify_tx "$tx_id"
}

run_verify_reboot_last_mode_compact() {
    local tx_id
    tx_id="$(resolve_verify_tx_id_last)" || return 1
    run_verify_reboot_mode_compact "$tx_id"
}

handle_verify_modes_compact() {
    case "$CLI_MODE" in
        verify-reboot)
            run_verify_reboot_mode_compact "$VERIFY_TX_ID"
            ;;
        verify-reboot-last)
            run_verify_reboot_last_mode_compact
            ;;
    esac
}

ensure_verify_tx_id_if_mode_requires() {
    if [ "$CLI_MODE" = "verify-reboot" ] && [ -z "$VERIFY_TX_ID" ]; then
        log_error "Missing required tx-id for --verify-reboot"
        usage >&2
        exit 2
    fi
}

prepare_apply_and_verify_modes() {
    validate_mode_compat_flags || exit 2
    ensure_verify_tx_id_if_mode_requires
    handle_verify_mode_validation
}

check_startup_policy_drift_post_apply_compact() {
    check_startup_policy_drift_post_apply
}

record_baseline_and_startup_artifacts() {
    maybe_capture_startup_baseline || return 1
    ensure_startup_artifacts_manifest_if_selected
    return 0
}

run_apply_mode_dispatch_with_startup() {
    detect_resources
    calculate_parameters
    preview_plan

    if ! confirm_apply; then
        exit 1
    fi

    require_root

    if [ "${#SELECTED_ZONES[@]}" -eq 1 ] && [ "${SELECTED_ZONES[0]}" = "sysctl" ]; then
        if is_zone_idempotent; then
            log_warn "All target parameters already match current values — no-op apply"
            return 0
        fi
    fi

    journal_init_apply_tx
    ensure_manifest_startup_defaults

    log_info "Applying selected zones: ${SELECTED_ZONES_CSV}"
    if startup_zone_selected; then
        record_baseline_and_startup_artifacts || return 1
        run_apply_selected_with_startup_metadata || return 1
        check_startup_policy_drift_post_apply_compact || return 1
    else
        run_apply_selected_with_startup_metadata || return 1
    fi
    log_success "Apply phase finished for zones: ${SELECTED_ZONES_CSV}"
}

check_startup_policy_now() {
    check_startup_policy_drift_post_apply_compact
}

run_verify_mode_dispatch_compact() {
    handle_verify_modes_compact
}

main_mode_dispatch_extension() {
    :
}

parse_verify_mode_flags() {
    :
}

rollback_mode_pre_log() {
    local tx_id="$1"
    log_reboot_context_before_rollback "$tx_id"
}

rollback_log_context_and_summary() {
    local rollback_log="$1"
    post_rollback_log_startup "$rollback_log"
}

record_zone_startup_artifacts_in_rollback() {
    local tx_id="$1"
    local seq="$2"
    local zone="$3"
    local op_path="$4"
    local rollback_log="$5"
    record_rollback_zone_startup_artifacts "$tx_id" "$seq" "$zone" "$op_path" "$rollback_log"
}

post_rollback_status_marker() {
    local status="$1"
    maybe_emit_rollback_evidence_for_status "$status"
}

rollback_log_context_blob() {
    local rollback_log="$1"
    rollback_log_startup_context "$rollback_log"
}

maybe_emit_verify_config() {
    emit_verify_startup_config
}

apply_zone_with_startup_artifact_tracking() {
    local zone="$1"
    if apply_zone "$zone"; then
        maybe_record_startup_artifacts_in_op "$zone"
        return 0
    fi
    return 1
}

run_apply_selected_zones_with_startup_tracking() {
    backup_configs_if_needed

    local zone
    local seq=0

    for zone in "${SELECTED_ZONES[@]}"; do
        seq=$((seq + 1))

        local planned_at
        planned_at="$(utc_now)"
        local op_path
        op_path="$(journal_op_path "$seq" "$zone")"
        CURRENT_OP_PATH="$op_path"
        journal_write_op "$seq" "$zone" "planned" "zone scheduled" "$planned_at" ""

        reset_zone_outcome

        if apply_zone_with_startup_artifact_tracking "$zone"; then
            local final_status="$ZONE_OUTCOME_STATUS"
            local final_reason="$ZONE_OUTCOME_REASON"
            local finished_at
            finished_at="$(utc_now)"
            journal_write_op "$seq" "$zone" "$final_status" "$final_reason" "$planned_at" "$finished_at"
            log_info "[tx:${CURRENT_TX_ID}] zone=${zone} status=${final_status} reason=${final_reason}"
        else
            local zone_rc=$?
            local finished_at
            finished_at="$(utc_now)"
            local fail_reason="zone command exited with status ${zone_rc}"
            journal_write_op "$seq" "$zone" "failed" "$fail_reason" "$planned_at" "$finished_at"
            log_error "[tx:${CURRENT_TX_ID}] zone=${zone} status=failed reason=${fail_reason}"
            return "$zone_rc"
        fi
    done
}

apply_flow_with_startup_tracking() {
    if startup_zone_selected; then
        maybe_capture_startup_baseline || return 1
    fi

    run_apply_selected_zones_with_startup_tracking || return 1

    if startup_zone_selected; then
        check_startup_policy_now || return 1
    fi

    return 0
}

run_apply_mode() {
    detect_resources
    calculate_parameters
    preview_plan

    if ! confirm_apply; then
        exit 1
    fi

    require_root

    if [ "${#SELECTED_ZONES[@]}" -eq 1 ] && [ "${SELECTED_ZONES[0]}" = "sysctl" ]; then
        if is_zone_idempotent; then
            log_warn "All target parameters already match current values — no-op apply"
            return 0
        fi
    fi

    journal_init_apply_tx
    ensure_manifest_startup_defaults

    log_info "Applying selected zones: ${SELECTED_ZONES_CSV}"
    apply_flow_with_startup_tracking
    log_success "Apply phase finished for zones: ${SELECTED_ZONES_CSV}"
}

run_rollback_mode() {
    local resolved_tx_id="$1"
    require_root

    log_info "Resolved transaction state root: $(resolve_state_root)"
    log_info "Rolling back tx-id: ${resolved_tx_id}"

    rollback_tx "$resolved_tx_id"
}

run_verify_reboot_mode_from_cli() {
    local tx_id="$1"
    run_verify_reboot_mode_compact "$tx_id"
}

run_verify_reboot_last_mode_from_cli() {
    run_verify_reboot_last_mode_compact
}


journal_get_field_optional() {
    local op_path="$1"
    local key="$2"
    awk -F= -v k="$key" '$1==k {print substr($0, index($0, "=")+1); found=1; exit} END {if(!found) print ""}' "$op_path"
}

zone_backup_root() {
    local zone="$1"
    printf '%s/backups/%s' "$CURRENT_TX_DIR" "$zone"
}

capture_backup_metadata() {
    local op_path="$1"
    local zone="$2"
    local key_prefix="$3"
    local target_path="$4"

    local backup_dir
    backup_dir="$(zone_backup_root "$zone")"
    if ! mkdir -p "$backup_dir"; then
        journal_append_field "$op_path" "${key_prefix}_target_path" "$target_path"
        journal_append_field "$op_path" "${key_prefix}_existed_before" "unknown"
        journal_append_field "$op_path" "${key_prefix}_backup_path" ""
        journal_append_field "$op_path" "${key_prefix}_backup_status" "failed"
        journal_append_field "$op_path" "${key_prefix}_backup_reason" "backup_dir_create_failed"
        return 1
    fi

    local safe_name
    safe_name="$(basename "$target_path" | tr -c 'A-Za-z0-9._-' '_')"
    local backup_path="${backup_dir}/${safe_name}"

    journal_append_field "$op_path" "${key_prefix}_target_path" "$target_path"
    journal_append_field "$op_path" "${key_prefix}_backup_path" "$backup_path"

    if is_test_mode; then
        printf 'TEST_MODE placeholder backup for %s\n' "$target_path" > "$backup_path"
        journal_append_field "$op_path" "${key_prefix}_existed_before" "1"
        journal_append_field "$op_path" "${key_prefix}_backup_status" "created"
        journal_append_field "$op_path" "${key_prefix}_backup_reason" "test_mode_placeholder"
        return 0
    fi

    if [ -f "$target_path" ]; then
        if cp -f "$target_path" "$backup_path"; then
            journal_append_field "$op_path" "${key_prefix}_existed_before" "1"
            journal_append_field "$op_path" "${key_prefix}_backup_status" "created"
            journal_append_field "$op_path" "${key_prefix}_backup_reason" "captured"
            return 0
        fi

        journal_append_field "$op_path" "${key_prefix}_existed_before" "1"
        journal_append_field "$op_path" "${key_prefix}_backup_status" "failed"
        journal_append_field "$op_path" "${key_prefix}_backup_reason" "copy_failed"
        return 1
    fi

    journal_append_field "$op_path" "${key_prefix}_existed_before" "0"
    journal_append_field "$op_path" "${key_prefix}_backup_status" "skipped"
    journal_append_field "$op_path" "${key_prefix}_backup_reason" "target_missing"
    return 0
}

rollback_file_from_metadata() {
    local op_path="$1"
    local key_prefix="$2"

    local target_path
    local existed_before
    local backup_path
    local backup_status

    target_path="$(journal_get_field_optional "$op_path" "${key_prefix}_target_path")"
    existed_before="$(journal_get_field_optional "$op_path" "${key_prefix}_existed_before")"
    backup_path="$(journal_get_field_optional "$op_path" "${key_prefix}_backup_path")"
    backup_status="$(journal_get_field_optional "$op_path" "${key_prefix}_backup_status")"

    if [ -z "$target_path" ] || [ -z "$existed_before" ] || [ -z "$backup_status" ]; then
        mark_rollback_failure "metadata missing for ${key_prefix}"
        return 1
    fi

    if [ "$existed_before" = "1" ]; then
        if [ -z "$backup_path" ]; then
            mark_rollback_failure "metadata missing backup_path for ${key_prefix}"
            return 1
        fi
        if [ "$backup_status" != "created" ]; then
            mark_rollback_failure "metadata inconsistent for ${key_prefix}: backup_status=${backup_status}"
            return 1
        fi

        if [ ! -f "$backup_path" ]; then
            mark_rollback_failure "metadata missing backup file for ${key_prefix}: ${backup_path}"
            return 1
        fi

        if is_test_mode; then
            ROLLBACK_ZONE_REASON="would restore ${target_path} from ${backup_path} (test mode)"
            return 0
        fi

        local target_dir
        target_dir="$(dirname "$target_path")"
        mkdir -p "$target_dir"

        if cp -f "$backup_path" "$target_path"; then
            ROLLBACK_ZONE_REASON="restored from ${backup_path}"
            return 0
        fi

        mark_rollback_failure "restore command failed for ${target_path} from ${backup_path}"
        return 1
    fi

    if [ "$existed_before" = "0" ]; then
        if is_test_mode; then
            ROLLBACK_ZONE_REASON="would remove ${target_path} because tx created it (test mode)"
            return 0
        fi

        if [ -f "$target_path" ]; then
            if rm -f "$target_path"; then
                ROLLBACK_ZONE_REASON="removed tx-created ${target_path}"
                return 0
            fi
            mark_rollback_failure "restore command failed: could not remove ${target_path}"
            return 1
        fi

        ROLLBACK_ZONE_REASON="skipped because ${target_path} is already absent"
        return 0
    fi

    mark_rollback_failure "metadata inconsistent for ${key_prefix}: existed_before=${existed_before}"
    return 1
}

rollback_sysctl() {
    local op_path="$1"

    rollback_file_from_metadata "$op_path" "sysctl_main" || return 1
    local main_reason="$ROLLBACK_ZONE_REASON"

    rollback_file_from_metadata "$op_path" "sysctl_modules_load" || return 1
    local modules_reason="$ROLLBACK_ZONE_REASON"

    rollback_file_from_metadata "$op_path" "sysctl_modules_conntrack" || true
    local conntrack_reason="$ROLLBACK_ZONE_REASON"

    local disabled_restore_reason=""
    local disabled_restore_failed=0
    local disabled_count
    disabled_count="$(journal_get_field_optional "$op_path" "sysctl_disabled_count")"

    if [[ "$disabled_count" =~ ^[0-9]+$ ]] && [ "$disabled_count" -gt 0 ]; then
        local i
        for ((i=1; i<=disabled_count; i++)); do
            local original_path disabled_path
            original_path="$(journal_get_field_optional "$op_path" "sysctl_disabled_${i}_from")"
            disabled_path="$(journal_get_field_optional "$op_path" "sysctl_disabled_${i}_to")"

            if [ -z "$original_path" ] || [ -z "$disabled_path" ]; then
                disabled_restore_failed=1
                disabled_restore_reason="${disabled_restore_reason}; missing metadata for disabled file #${i}"
                continue
            fi

            if is_test_mode; then
                disabled_restore_reason="${disabled_restore_reason}; would restore ${disabled_path} -> ${original_path} (test mode)"
                continue
            fi

            if [ -f "$disabled_path" ]; then
                if mv "$disabled_path" "$original_path"; then
                    disabled_restore_reason="${disabled_restore_reason}; restored ${disabled_path} -> ${original_path}"
                else
                    disabled_restore_failed=1
                    disabled_restore_reason="${disabled_restore_reason}; failed restore ${disabled_path} -> ${original_path}"
                fi
            else
                disabled_restore_reason="${disabled_restore_reason}; skipped restore for ${disabled_path} (already absent)"
            fi
        done
    fi

    if [ "$disabled_restore_failed" -eq 1 ]; then
        mark_rollback_failure "${main_reason}; ${modules_reason}; ${conntrack_reason}${disabled_restore_reason}"
        return 1
    fi

    if is_test_mode; then
        ROLLBACK_ZONE_REASON="${main_reason}; ${modules_reason}; ${conntrack_reason}${disabled_restore_reason}; would restore runtime snapshot and reload sysctl (test mode)"
        return 0
    fi

    if ! sysctl --system >/dev/null 2>&1; then
        mark_rollback_failure "sysctl reload failed after restore"
        return 1
    fi

    local runtime_restore_reason
    runtime_restore_reason="$(restore_sysctl_runtime_snapshot "$op_path")"
    if [ $? -ne 0 ]; then
        mark_rollback_failure "runtime snapshot restore failed: ${runtime_restore_reason}"
        return 1
    fi

    ROLLBACK_ZONE_REASON="${main_reason}; ${modules_reason}; ${conntrack_reason}${disabled_restore_reason}; ${runtime_restore_reason}; reloaded via sysctl --system"
    return 0
}

rollback_limits() {
    local op_path="$1"
    rollback_file_from_metadata "$op_path" "limits_main"
}

rollback_docker_daemon() {
    local op_path="$1"

    rollback_file_from_metadata "$op_path" "docker_daemon" || return 1
    local restore_reason="$ROLLBACK_ZONE_REASON"

    local docker_was_active
    docker_was_active="$(journal_get_field_optional "$op_path" "docker_was_active")"
    if [ -z "$docker_was_active" ]; then
        mark_rollback_failure "metadata missing for docker_was_active"
        return 1
    fi

    if [ "$docker_was_active" != "1" ]; then
        ROLLBACK_ZONE_REASON="${restore_reason}; skipped restart because docker_was_active=${docker_was_active}"
        return 0
    fi

    if is_test_mode; then
        ROLLBACK_ZONE_REASON="${restore_reason}; would reload docker (test mode)"
        return 0
    fi

    if kill -SIGHUP "$(pidof dockerd 2>/dev/null)" 2>/dev/null; then
        ROLLBACK_ZONE_REASON="${restore_reason}; reloaded docker (SIGHUP)"
        return 0
    elif systemctl reload docker >/dev/null 2>&1; then
        ROLLBACK_ZONE_REASON="${restore_reason}; reloaded docker via systemctl"
        return 0
    fi

    mark_rollback_failure "restore command failed: docker reload"
    return 1
}

rollback_compose() {
    local op_path="$1"
    rollback_file_from_metadata "$op_path" "compose_target"
}

net_iface_bool_value_is_valid() {
    case "$1" in
        on|off)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

capture_net_iface_state() {
    local op_path="$1"

    if [ -z "$NET_IFACE" ]; then
        journal_append_field "$op_path" "state_capture_status" "failed"
        journal_append_field "$op_path" "state_capture_reason" "net_iface_missing"
        return 1
    fi

    if ! command -v ethtool >/dev/null 2>&1; then
        journal_append_field "$op_path" "state_capture_status" "failed"
        journal_append_field "$op_path" "state_capture_reason" "ethtool_missing"
        return 1
    fi

    journal_append_field "$op_path" "net_iface" "$NET_IFACE"

    local captured_keys=0
    local failed_queries=()

    local ring_output=""
    if ring_output="$(ethtool -g "$NET_IFACE" 2>/dev/null)"; then
        local prev_ring_rx=""
        local prev_ring_tx=""
        prev_ring_rx="$(printf '%s\n' "$ring_output" | awk 'BEGIN{sec=0} /Current hardware settings:/ {sec=1; next} sec && $1=="RX:" {print $2; exit}')"
        prev_ring_tx="$(printf '%s\n' "$ring_output" | awk 'BEGIN{sec=0} /Current hardware settings:/ {sec=1; next} sec && $1=="TX:" {print $2; exit}')"

        if [ -n "$prev_ring_rx" ] && [[ "$prev_ring_rx" =~ ^[0-9]+$ ]]; then
            journal_append_field "$op_path" "prev_ring_rx" "$prev_ring_rx"
            captured_keys=$((captured_keys + 1))
        fi
        if [ -n "$prev_ring_tx" ] && [[ "$prev_ring_tx" =~ ^[0-9]+$ ]]; then
            journal_append_field "$op_path" "prev_ring_tx" "$prev_ring_tx"
            captured_keys=$((captured_keys + 1))
        fi
    else
        failed_queries+=("ring_query_failed")
    fi

    local coalesce_output=""
    if coalesce_output="$(ethtool -c "$NET_IFACE" 2>/dev/null)"; then
        local prev_adaptive_rx=""
        local prev_adaptive_tx=""
        prev_adaptive_rx="$(printf '%s\n' "$coalesce_output" | awk -F': *' '/Adaptive RX:/ {print $2; exit}' | awk '{print $1}')"
        prev_adaptive_tx="$(printf '%s\n' "$coalesce_output" | awk -F': *' '/Adaptive TX:/ {print $2; exit}' | awk '{print $1}')"

        if net_iface_bool_value_is_valid "$prev_adaptive_rx"; then
            journal_append_field "$op_path" "prev_adaptive_rx" "$prev_adaptive_rx"
            captured_keys=$((captured_keys + 1))
        fi
        if net_iface_bool_value_is_valid "$prev_adaptive_tx"; then
            journal_append_field "$op_path" "prev_adaptive_tx" "$prev_adaptive_tx"
            captured_keys=$((captured_keys + 1))
        fi
    else
        failed_queries+=("coalesce_query_failed")
    fi

    local features_output=""
    if features_output="$(ethtool -k "$NET_IFACE" 2>/dev/null)"; then
        local prev_offload_gro=""
        local prev_offload_gso=""
        local prev_offload_tso=""
        prev_offload_gro="$(printf '%s\n' "$features_output" | awk -F': *' '/generic-receive-offload:/ {print $2; exit}' | awk '{print $1}')"
        prev_offload_gso="$(printf '%s\n' "$features_output" | awk -F': *' '/generic-segmentation-offload:/ {print $2; exit}' | awk '{print $1}')"
        prev_offload_tso="$(printf '%s\n' "$features_output" | awk -F': *' '/tcp-segmentation-offload:/ {print $2; exit}' | awk '{print $1}')"

        if net_iface_bool_value_is_valid "$prev_offload_gro"; then
            journal_append_field "$op_path" "prev_offload_gro" "$prev_offload_gro"
            captured_keys=$((captured_keys + 1))
        fi
        if net_iface_bool_value_is_valid "$prev_offload_gso"; then
            journal_append_field "$op_path" "prev_offload_gso" "$prev_offload_gso"
            captured_keys=$((captured_keys + 1))
        fi
        if net_iface_bool_value_is_valid "$prev_offload_tso"; then
            journal_append_field "$op_path" "prev_offload_tso" "$prev_offload_tso"
            captured_keys=$((captured_keys + 1))
        fi
    else
        failed_queries+=("offload_query_failed")
    fi

    if [ "$captured_keys" -eq 0 ]; then
        journal_append_field "$op_path" "state_capture_status" "failed"
        if [ "${#failed_queries[@]}" -gt 0 ]; then
            journal_append_field "$op_path" "state_capture_reason" "${failed_queries[*]}"
        else
            journal_append_field "$op_path" "state_capture_reason" "no_supported_fields_detected"
        fi
        return 1
    fi

    if [ "${#failed_queries[@]}" -gt 0 ]; then
        journal_append_field "$op_path" "state_capture_status" "partial"
        journal_append_field "$op_path" "state_capture_reason" "${failed_queries[*]}"
    else
        journal_append_field "$op_path" "state_capture_status" "captured"
        journal_append_field "$op_path" "state_capture_reason" "ok"
    fi

    return 0
}

rollback_net_iface() {
    local op_path="$1"

    if ! command -v ethtool >/dev/null 2>&1; then
        mark_rollback_failure "ethtool missing"
        return 1
    fi

    local iface="${NET_IFACE:-}"
    if [ -z "$iface" ]; then
        iface="$(journal_get_field_optional "$op_path" "net_iface")"
    fi
    if [ -z "$iface" ]; then
        iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || true)"
    fi

    if [ -z "$iface" ]; then
        mark_rollback_failure "missing state capture metadata"
        return 1
    fi

    local capture_status
    capture_status="$(journal_get_field_optional "$op_path" "state_capture_status")"
    if [ -z "$capture_status" ] || [ "$capture_status" = "failed" ]; then
        mark_rollback_failure "missing state capture metadata"
        return 1
    fi

    local prev_ring_rx prev_ring_tx
    local prev_adaptive_rx prev_adaptive_tx
    local prev_offload_gro prev_offload_gso prev_offload_tso

    prev_ring_rx="$(journal_get_field_optional "$op_path" "prev_ring_rx")"
    prev_ring_tx="$(journal_get_field_optional "$op_path" "prev_ring_tx")"
    prev_adaptive_rx="$(journal_get_field_optional "$op_path" "prev_adaptive_rx")"
    prev_adaptive_tx="$(journal_get_field_optional "$op_path" "prev_adaptive_tx")"
    prev_offload_gro="$(journal_get_field_optional "$op_path" "prev_offload_gro")"
    prev_offload_gso="$(journal_get_field_optional "$op_path" "prev_offload_gso")"
    prev_offload_tso="$(journal_get_field_optional "$op_path" "prev_offload_tso")"

    local restored=()
    local skipped=()
    local failed=()

    if [ -n "$prev_ring_rx" ] && [ -n "$prev_ring_tx" ] && [[ "$prev_ring_rx" =~ ^[0-9]+$ ]] && [[ "$prev_ring_tx" =~ ^[0-9]+$ ]]; then
        if is_test_mode; then
            restored+=("would restore ring rx=${prev_ring_rx} tx=${prev_ring_tx} (test mode)")
        elif ethtool -G "$iface" rx "$prev_ring_rx" tx "$prev_ring_tx" >/dev/null 2>&1; then
            restored+=("restored ring rx=${prev_ring_rx} tx=${prev_ring_tx}")
        else
            failed+=("restore command failed: ring rx=${prev_ring_rx} tx=${prev_ring_tx}")
        fi
    else
        skipped+=("skipped because ring metadata missing")
    fi

    local -a coalesce_args=()
    if net_iface_bool_value_is_valid "$prev_adaptive_rx"; then
        coalesce_args+=(adaptive-rx "$prev_adaptive_rx")
    fi
    if net_iface_bool_value_is_valid "$prev_adaptive_tx"; then
        coalesce_args+=(adaptive-tx "$prev_adaptive_tx")
    fi

    if [ "${#coalesce_args[@]}" -gt 0 ]; then
        if is_test_mode; then
            restored+=("would restore coalesce ${coalesce_args[*]} (test mode)")
        elif ethtool -C "$iface" "${coalesce_args[@]}" >/dev/null 2>&1; then
            restored+=("restored coalesce ${coalesce_args[*]}")
        else
            failed+=("restore command failed: coalesce ${coalesce_args[*]}")
        fi
    else
        skipped+=("skipped because coalesce metadata missing")
    fi

    local feature_name
    local feature_value
    for feature_name in gro gso tso; do
        case "$feature_name" in
            gro) feature_value="$prev_offload_gro" ;;
            gso) feature_value="$prev_offload_gso" ;;
            tso) feature_value="$prev_offload_tso" ;;
        esac

        if ! net_iface_bool_value_is_valid "$feature_value"; then
            skipped+=("skipped because ${feature_name} metadata missing")
            continue
        fi

        if is_test_mode; then
            restored+=("would restore ${feature_name}=${feature_value} (test mode)")
        elif ethtool -K "$iface" "$feature_name" "$feature_value" >/dev/null 2>&1; then
            restored+=("restored ${feature_name}=${feature_value}")
        else
            failed+=("restore command failed: ${feature_name}=${feature_value}")
        fi
    done

    if [ "${#restored[@]}" -eq 0 ]; then
        mark_rollback_failure "missing state capture metadata"
        return 1
    fi

    local reason_parts=()
    if [ "${#restored[@]}" -gt 0 ]; then
        reason_parts+=("${restored[*]}")
    fi
    if [ "${#skipped[@]}" -gt 0 ]; then
        reason_parts+=("${skipped[*]}")
    fi

    if [ "${#failed[@]}" -gt 0 ]; then
        mark_rollback_failure "${reason_parts[*]}; ${failed[*]}"
        return 1
    fi

    ROLLBACK_ZONE_REASON="${reason_parts[*]}"
    return 0
}

rollback_oom_watch() {
    local op_path="$1"

    rollback_file_from_metadata "$op_path" "oom_script" || return 1
    local script_reason="$ROLLBACK_ZONE_REASON"

    rollback_file_from_metadata "$op_path" "oom_service" || return 1
    local service_reason="$ROLLBACK_ZONE_REASON"

    local oom_was_enabled
    local oom_was_active
    oom_was_enabled="$(journal_get_field_optional "$op_path" "oom_was_enabled")"
    oom_was_active="$(journal_get_field_optional "$op_path" "oom_was_active")"

    if [ -z "$oom_was_enabled" ] || [ -z "$oom_was_active" ]; then
        mark_rollback_failure "metadata missing for oom-watch unit state"
        return 1
    fi

    local oom_unit_name
    oom_unit_name="$(basename "$OOM_SERVICE")"

    if is_test_mode; then
        ROLLBACK_ZONE_REASON="${script_reason}; ${service_reason}; would restore unit enabled=${oom_was_enabled} active=${oom_was_active} (test mode)"
        return 0
    fi

    systemctl daemon-reload >/dev/null 2>&1 || true

    if [ "$oom_was_enabled" = "1" ]; then
        systemctl enable "$oom_unit_name" >/dev/null 2>&1 || true
    else
        systemctl disable "$oom_unit_name" >/dev/null 2>&1 || true
    fi

    if [ "$oom_was_active" = "1" ]; then
        systemctl start "$oom_unit_name" >/dev/null 2>&1 || true
    else
        systemctl stop "$oom_unit_name" >/dev/null 2>&1 || true
    fi

    ROLLBACK_ZONE_REASON="${script_reason}; ${service_reason}; restored unit enabled=${oom_was_enabled} active=${oom_was_active}"
    return 0
}

rollback_zone() {
    local zone="$1"
    local op_path="$2"
    reset_rollback_outcome

    case "$zone" in
        sysctl) rollback_sysctl "$op_path" ;;
        limits) rollback_limits "$op_path" ;;
        docker-daemon) rollback_docker_daemon "$op_path" ;;
        compose) rollback_compose "$op_path" ;;
        net-iface) rollback_net_iface "$op_path" ;;
        *)
            mark_rollback_failure "unknown zone ${zone}"
            return 1
            ;;
    esac
}

rollback_tx() {
    local tx_id="$1"
    local tx_dir

    tx_dir="$(resolve_tx_dir "$tx_id")" || return $?

    CURRENT_TX_ID="$tx_id"
    CURRENT_TX_DIR="$tx_dir"
    CURRENT_TX_OPS_DIR="${tx_dir}/ops"

    if ! journal_validate_env_file "${tx_dir}/manifest.env"; then
        return 1
    fi

    local rollback_dir="${tx_dir}/rollback"
    local rollback_log="${rollback_dir}/rollback.log"
    if ! mkdir -p "$rollback_dir"; then
        log_error "Failed to create rollback directory: ${rollback_dir}"
        return 1
    fi

    local -a op_files=()
    while IFS= read -r op_path; do
        [ -n "$op_path" ] && op_files+=("$op_path")
    done < <(list_tx_op_files_sorted "$tx_dir")

    if [ "${#op_files[@]}" -eq 0 ]; then
        log_error "Malformed journal for tx ${tx_id}: no operation files found"
        return 1
    fi

    local rollback_started_at
    rollback_started_at="$(utc_now)"
    {
        echo "tx_id=${tx_id}"
        echo "started_at=${rollback_started_at}"
        echo "mode=${CLI_MODE}"
    } > "$rollback_log"

    local failures=0
    local idx
    for ((idx=${#op_files[@]}-1; idx>=0; idx--)); do
        local op_path="${op_files[$idx]}"
        local seq
        local zone
        local status

        seq="$(journal_read_field "$op_path" "seq")" || { failures=$((failures + 1)); continue; }
        zone="$(journal_read_field "$op_path" "zone")" || { failures=$((failures + 1)); continue; }
        status="$(journal_read_field "$op_path" "status")" || { failures=$((failures + 1)); continue; }

        if ! [[ "$seq" =~ ^[0-9]+$ ]]; then
            log_error "Malformed seq '${seq}' in ${op_path}"
            failures=$((failures + 1))
            continue
        fi

        if ! contains_zone "$zone"; then
            log_error "Malformed zone '${zone}' in ${op_path}"
            failures=$((failures + 1))
            continue
        fi

        if ! journal_assert_status "$status"; then
            failures=$((failures + 1))
            continue
        fi

        if [ "$status" != "applied" ]; then
            local skip_reason="not rolled back because apply status=${status}"
            local skip_at
            skip_at="$(utc_now)"
            append_rollback_outcome "$op_path" "ignored" "$skip_reason" "$skip_at"
            log_info "[tx:${tx_id}][rollback] seq=${seq} zone=${zone} rollback_status=ignored reason=${skip_reason}"
            printf '%s\n' "seq=${seq} zone=${zone} rollback_status=ignored reason=${skip_reason}" >> "$rollback_log"
            continue
        fi

        local rollback_at
        rollback_at="$(utc_now)"
        if rollback_zone "$zone" "$op_path"; then
            append_rollback_outcome "$op_path" "$ROLLBACK_ZONE_STATUS" "$ROLLBACK_ZONE_REASON" "$rollback_at"
            log_info "[tx:${tx_id}][rollback] seq=${seq} zone=${zone} rollback_status=${ROLLBACK_ZONE_STATUS} reason=${ROLLBACK_ZONE_REASON}"
            printf '%s\n' "seq=${seq} zone=${zone} rollback_status=${ROLLBACK_ZONE_STATUS} reason=${ROLLBACK_ZONE_REASON}" >> "$rollback_log"
        else
            local rollback_rc=$?
            local reason="$ROLLBACK_ZONE_REASON"
            if [ -z "$reason" ]; then
                reason="rollback exited with status ${rollback_rc}"
            fi
            append_rollback_outcome "$op_path" "failed" "$reason" "$rollback_at"
            log_warn "[tx:${tx_id}][rollback] seq=${seq} zone=${zone} rollback_status=failed reason=${reason}"
            printf '%s\n' "seq=${seq} zone=${zone} rollback_status=failed reason=${reason}" >> "$rollback_log"
            failures=$((failures + 1))
        fi
    done

    local rollback_finished_at
    rollback_finished_at="$(utc_now)"
    printf '%s\n' "finished_at=${rollback_finished_at}" >> "$rollback_log"

    if [ "$failures" -gt 0 ]; then
        log_warn "Rollback completed with ${failures} failed operation(s) for tx-id ${tx_id}"
        return 1
    fi

    log_success "Rollback completed for tx-id ${tx_id}"
    return 0
}

collect_tx_rollback_counts() {
    local tx_id="$1"
    local rollback_log="$(tx_dir_for_id "$tx_id")/rollback/rollback.log"

    if [ ! -f "$rollback_log" ]; then
        return 1
    fi

    local rolled_back_count failed_count ignored_count
    rolled_back_count="$(grep -Fco 'rollback_status=rolled_back' "$rollback_log" || true)"
    failed_count="$(grep -Fco 'rollback_status=failed' "$rollback_log" || true)"
    ignored_count="$(grep -Fco 'rollback_status=ignored' "$rollback_log" || true)"

    printf '%s %s %s\n' "$rolled_back_count" "$failed_count" "$ignored_count"
}

rollback_all_txs() {
    local tx_output=""
    if ! tx_output="$(list_all_tx_ids_chronological)"; then
        local list_rc=$?
        local root
        root="$(transactions_root)"
        if [ "$list_rc" -eq 2 ]; then
            log_error "No prior transaction found under ${root} (transactions directory missing)"
        else
            log_error "No prior transaction found under ${root}"
        fi
        return 1
    fi

    local -a tx_ids=()
    local tx_id
    while IFS= read -r tx_id; do
        [ -n "$tx_id" ] && tx_ids+=("$tx_id")
    done <<< "$tx_output"

    if [ "${#tx_ids[@]}" -eq 0 ]; then
        local root
        root="$(transactions_root)"
        log_error "No prior transaction found under ${root}"
        return 1
    fi

    local tx_total=0
    local tx_failed=0
    local ops_rolled_back=0
    local ops_failed=0
    local ops_ignored=0

    local idx
    for ((idx=${#tx_ids[@]}-1; idx>=0; idx--)); do
        tx_id="${tx_ids[$idx]}"
        tx_total=$((tx_total + 1))

        log_info "Rolling back tx-id: ${tx_id}"

        if rollback_tx "$tx_id"; then
            :
        else
            tx_failed=$((tx_failed + 1))
        fi

        local counts=""
        if counts="$(collect_tx_rollback_counts "$tx_id")"; then
            local tx_ops_rolled_back tx_ops_failed tx_ops_ignored
            read -r tx_ops_rolled_back tx_ops_failed tx_ops_ignored <<< "$counts"
            ops_rolled_back=$((ops_rolled_back + tx_ops_rolled_back))
            ops_failed=$((ops_failed + tx_ops_failed))
            ops_ignored=$((ops_ignored + tx_ops_ignored))
        else
            log_warn "Rollback artifact missing for tx-id ${tx_id}: $(tx_dir_for_id "$tx_id")/rollback/rollback.log"
        fi
    done

    echo "Rollback-all summary: tx_total=${tx_total} tx_failed=${tx_failed} ops_rolled_back=${ops_rolled_back} ops_failed=${ops_failed} ops_ignored=${ops_ignored}"

    if [ "$tx_failed" -gt 0 ]; then
        return 1
    fi

    return 0
}

print_banner() {
    echo
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║      RemnaWave Adaptive Optimization v3.1            ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
    echo
}

usage() {
    cat <<EOF
Usage:
  $0 --help
  $0 --apply <target> [--shaping <bandwidth>]
  $0 --rollback <tx-id>
  $0 --rollback-last
  $0 --rollback-all
  $0 --verify-reboot <tx-id> [--rollback-on-fail]
  $0 --verify-reboot-last [--rollback-on-fail]

Description:
  Applies optimization settings ONLY when --apply is explicitly provided.
  Before applying, the script prints a preview plan and asks for confirmation.
  Rollback modes are parsed and validated as first-class operations.

Modes (exactly one required):
  --apply <target>      Apply selected optimization zones.
  --rollback <tx-id>    Roll back a specific transaction id.
  --rollback-last       Roll back the most recent transaction id.
  --rollback-all        Roll back all transactions (newest to oldest, best-effort).
  --verify-reboot <tx-id>   Verify post-reboot baseline container recovery for tx-id.
  --verify-reboot-last      Verify post-reboot baseline recovery for most recent tx-id.

Options:
  --shaping <bandwidth> Enable per-user traffic shaping via CAKE (e.g. 10mbit, 50mbit).
                        Switches qdisc to cake and applies tc shaping on the interface.
                        Each client IP gets equal share up to the specified bandwidth.
  --rollback-on-fail    For verify-reboot modes only: trigger rollback on failed verdict.

Targets:
  all                 Apply all optimization zones in stable order.
  <zone[,zone...]>    Apply selected zones from the allow-list below.

Allowed zones:
  ${ALLOWED_ZONES}

Examples:
  $0 --apply all
  $0 --apply all --shaping 10mbit
  $0 --apply sysctl,limits
  $0 --apply net-iface --shaping 50mbit
  $0 --rollback 20260121T120001Z-deadbeef
  $0 --rollback-last
  $0 --rollback-all

Confirmation:
  You must type exactly: Yes
  Any other input aborts without applying changes.

State root:
  RW_OPT_STATE_DIR overrides the transaction state directory root.
  Default: ${DEFAULT_STATE_ROOT}

Docker daemon (/etc/docker/daemon.json):
  By default the docker-daemon zone is NOT run for --apply all (only compose sysctl/limits/etc.).
  RW_OPT_SKIP_DOCKER_DAEMON=0 includes docker-daemon in --apply all.
  Or pass docker-daemon in the zone list (e.g. --apply sysctl,compose,docker-daemon).

Test mode:
  RW_OPT_TEST_MODE=1 makes apply deterministic and non-mutating.
  RW_OPT_TEST_TX_ID overrides generated tx-id in test mode only.
EOF
}

require_root() {
    if is_test_mode; then
        return 0
    fi

    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root for apply/rollback modes"
        exit 1
    fi
}

trim_whitespace() {
    local value="$1"
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    echo "$value"
}

contains_zone() {
    local candidate="$1"
    local zone
    for zone in "${ZONE_ORDER[@]}"; do
        if [ "$zone" = "$candidate" ]; then
            return 0
        fi
    done
    return 1
}

list_contains() {
    local needle="$1"
    shift
    local item
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

normalize_selected_zones() {
    local -a parsed=()
    local -a stable=()
    local -a raw_parts=()
    local raw="$1"

    DOCKER_DAEMON_EXPLICITLY_SELECTED=0

    if [ -z "$raw" ]; then
        log_error "Missing required target for --apply"
        usage >&2
        exit 2
    fi

    if [ "$raw" = "all" ]; then
        SELECTED_ZONES=("${ZONE_ORDER[@]}")
        if [ "${RW_OPT_SKIP_DOCKER_DAEMON:-1}" != "0" ]; then
            local -a filtered=()
            local z
            for z in "${SELECTED_ZONES[@]}"; do
                [ "$z" = "docker-daemon" ] && continue
                filtered+=("$z")
            done
            SELECTED_ZONES=("${filtered[@]}")
        fi
    else
        if [[ "$raw" == *, || "$raw" == ,* || "$raw" == *,,* ]]; then
            log_error "Malformed --apply target list: $raw"
            echo "Allowed targets: all or comma-separated zones from: ${ALLOWED_ZONES}" >&2
            usage >&2
            exit 2
        fi

        IFS=',' read -r -a raw_parts <<< "$raw"

        local part
        for part in "${raw_parts[@]}"; do
            local zone
            zone="$(trim_whitespace "$part")"
            if [ -z "$zone" ]; then
                log_error "Malformed --apply target list: empty zone entry"
                echo "Allowed targets: all or comma-separated zones from: ${ALLOWED_ZONES}" >&2
                usage >&2
                exit 2
            fi

            if ! contains_zone "$zone"; then
                log_error "Unknown zone in --apply target list: $zone"
                echo "Allowed zones: ${ALLOWED_ZONES}" >&2
                usage >&2
                exit 2
            fi

            if [ "$zone" = "docker-daemon" ]; then
                DOCKER_DAEMON_EXPLICITLY_SELECTED=1
            fi

            if list_contains "$zone" "${parsed[@]}"; then
                log_error "Duplicate zone in --apply target list: $zone"
                echo "Allowed zones: ${ALLOWED_ZONES}" >&2
                usage >&2
                exit 2
            fi

            parsed+=("$zone")
        done

        local ordered_zone
        for ordered_zone in "${ZONE_ORDER[@]}"; do
            if list_contains "$ordered_zone" "${parsed[@]}"; then
                stable+=("$ordered_zone")
            fi
        done

        SELECTED_ZONES=("${stable[@]}")
    fi

    if [ "${#SELECTED_ZONES[@]}" -eq 0 ]; then
        log_error "No zones selected from --apply"
        usage >&2
        exit 2
    fi

    local IFS=','
    SELECTED_ZONES_CSV="${SELECTED_ZONES[*]}"
}

parse_args() {
    if [ "$#" -eq 0 ]; then
        usage >&2
        exit 2
    fi

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h)
                usage
                exit 0
                ;;
            --apply)
                if [ "$#" -lt 2 ]; then
                    log_error "Missing required target for --apply"
                    usage >&2
                    exit 2
                fi
                if [ -n "$CLI_MODE" ]; then
                    log_error "Exactly one mode is allowed: --apply, --rollback, --rollback-last, --rollback-all, --verify-reboot, or --verify-reboot-last"
                    usage >&2
                    exit 2
                fi
                CLI_MODE="apply"
                APPLY_TARGET_RAW="$2"
                shift 2
                ;;
            --rollback)
                if [ "$#" -lt 2 ]; then
                    log_error "Missing required tx-id for --rollback"
                    usage >&2
                    exit 2
                fi
                if [ -n "$CLI_MODE" ]; then
                    log_error "Exactly one mode is allowed: --apply, --rollback, --rollback-last, --rollback-all, --verify-reboot, or --verify-reboot-last"
                    usage >&2
                    exit 2
                fi
                CLI_MODE="rollback"
                ROLLBACK_TX_ID="$2"
                shift 2
                ;;
            --rollback-last)
                if [ -n "$CLI_MODE" ]; then
                    log_error "Exactly one mode is allowed: --apply, --rollback, --rollback-last, --rollback-all, --verify-reboot, or --verify-reboot-last"
                    usage >&2
                    exit 2
                fi
                CLI_MODE="rollback-last"
                shift
                ;;
            --rollback-all)
                if [ -n "$CLI_MODE" ]; then
                    log_error "Exactly one mode is allowed: --apply, --rollback, --rollback-last, --rollback-all, --verify-reboot, or --verify-reboot-last"
                    usage >&2
                    exit 2
                fi
                CLI_MODE="rollback-all"
                shift
                ;;
            --verify-reboot)
                if [ "$#" -lt 2 ]; then
                    log_error "Missing required tx-id for --verify-reboot"
                    usage >&2
                    exit 2
                fi
                if [ -n "$CLI_MODE" ]; then
                    log_error "Exactly one mode is allowed: --apply, --rollback, --rollback-last, --rollback-all, --verify-reboot, or --verify-reboot-last"
                    usage >&2
                    exit 2
                fi
                CLI_MODE="verify-reboot"
                VERIFY_TX_ID="$2"
                shift 2
                ;;
            --verify-reboot-last)
                if [ -n "$CLI_MODE" ]; then
                    log_error "Exactly one mode is allowed: --apply, --rollback, --rollback-last, --rollback-all, --verify-reboot, or --verify-reboot-last"
                    usage >&2
                    exit 2
                fi
                CLI_MODE="verify-reboot-last"
                shift
                ;;
            --rollback-on-fail)
                VERIFY_ROLLBACK_ON_FAIL="1"
                shift
                ;;
            --shaping)
                if [ "$#" -lt 2 ]; then
                    log_error "Missing required bandwidth for --shaping (e.g. 10mbit, 50mbit, 100mbit)"
                    usage >&2
                    exit 2
                fi
                SHAPING_BANDWIDTH="$2"
                shift 2
                ;;
            --debug)
                DEBUG_MODE=1
                shift
                ;;
            *)
                log_error "Unknown argument: $1"
                usage >&2
                exit 2
                ;;
        esac
    done

    if [ -z "$CLI_MODE" ]; then
        log_error "Exactly one mode is required: --apply, --rollback, --rollback-last, --rollback-all, --verify-reboot, or --verify-reboot-last"
        usage >&2
        exit 2
    fi

    case "$CLI_MODE" in
        apply)
            normalize_selected_zones "$APPLY_TARGET_RAW"
            ;;
        rollback)
            if ! tx_id_is_valid "$ROLLBACK_TX_ID"; then
                log_error "Invalid tx-id for --rollback: $ROLLBACK_TX_ID"
                usage >&2
                exit 2
            fi
            ;;
        rollback-last|rollback-all)
            ;;
        verify-reboot)
            if ! tx_id_is_valid "$VERIFY_TX_ID"; then
                log_error "Invalid tx-id for --verify-reboot: $VERIFY_TX_ID"
                usage >&2
                exit 2
            fi
            ;;
        verify-reboot-last)
            ;;
        *)
            log_error "Unexpected mode: $CLI_MODE"
            exit 2
            ;;
    esac

    if [ "$VERIFY_ROLLBACK_ON_FAIL" = "1" ] && [ "$CLI_MODE" != "verify-reboot" ] && [ "$CLI_MODE" != "verify-reboot-last" ]; then
        log_error "--rollback-on-fail is only valid with --verify-reboot or --verify-reboot-last"
        usage >&2
        exit 2
    fi
}

resolve_compose_target_path() {
    local candidate=""

    if [ -n "${RW_OPT_COMPOSE_PATH:-}" ]; then
        EXISTING_COMPOSE="${RW_OPT_COMPOSE_PATH}"
        return 0
    fi

    for candidate in "${COMPOSE_CANDIDATE_PATHS[@]}"; do
        if [ -f "$candidate" ] && [ -s "$candidate" ]; then
            EXISTING_COMPOSE="$candidate"
            return 0
        fi
    done

    candidate="$(find /opt /vless -maxdepth 5 -type f \( -name 'docker-compose.yml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null | grep -Ei 'remnawave|vless|remnanode|xray' | head -n1 || true)"
    if [ -n "$candidate" ]; then
        EXISTING_COMPOSE="$candidate"
        return 0
    fi

    EXISTING_COMPOSE="/opt/remnawave/docker-compose.yml"
}

resolve_compose_runtime_targets() {
    local default_service="${RW_OPT_OOM_TARGET_SERVICE:-remnanode}"
    local default_container="${RW_OPT_OOM_TARGET_CONTAINER:-$default_service}"

    COMPOSE_SERVICE_NAME="$default_service"
    COMPOSE_CONTAINER_NAME="$default_container"

    if [ -n "${RW_OPT_OOM_TARGET_SERVICE:-}" ] && [ -n "${RW_OPT_OOM_TARGET_CONTAINER:-}" ]; then
        return 0
    fi

    if [ ! -f "$EXISTING_COMPOSE" ] || [ ! -s "$EXISTING_COMPOSE" ]; then
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi

    local resolved
    resolved="$(python3 - "$EXISTING_COMPOSE" <<'PY'
import re
import sys
from pathlib import Path

DEFAULT_SERVICE = "remnanode"
DEFAULT_CONTAINER = "remnanode"

compose_path = Path(sys.argv[1])
text = ""
try:
    text = compose_path.read_text(encoding='utf-8')
except Exception:
    print(DEFAULT_SERVICE)
    print(DEFAULT_CONTAINER)
    raise SystemExit(0)

def print_default():
    print(DEFAULT_SERVICE)
    print(DEFAULT_CONTAINER)

try:
    import yaml  # type: ignore
except Exception:
    yaml = None

services = None
if yaml is not None:
    try:
        raw = yaml.safe_load(text) or {}
        maybe_services = raw.get('services') or {}
        if isinstance(maybe_services, dict) and maybe_services:
            services = maybe_services
    except Exception:
        services = None

if services is None:
    services = {}
    in_services = False
    current_service = None
    service_indent = None
    for raw_line in text.splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith('#'):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(' '))
        stripped = raw_line.strip()
        if not in_services:
            if stripped == 'services:':
                in_services = True
            continue
        if indent == 0:
            break
        service_match = re.match(r'^\s{2}([A-Za-z0-9_.-]+):\s*$', raw_line)
        if service_match:
            current_service = service_match.group(1)
            service_indent = indent
            services[current_service] = {}
            continue
        if current_service is None or service_indent is None or indent <= service_indent:
            continue
        key_match = re.match(r'^\s+[A-Za-z0-9_.-]+:\s*(.*)$', raw_line)
        if not key_match:
            continue
        key = raw_line.strip().split(':', 1)[0]
        value = raw_line.strip().split(':', 1)[1].strip().strip('"\'')
        if key in {'image', 'container_name'}:
            services[current_service][key] = value

if not isinstance(services, dict) or not services:
    print_default()
    raise SystemExit(0)

service_name = None
if DEFAULT_SERVICE in services:
    service_name = DEFAULT_SERVICE
else:
    for name, svc in services.items():
        image = str((svc or {}).get('image', '')).lower()
        if 'remnawave/node' in image or 'remnowave/node' in image:
            service_name = name
            break

if service_name is None and len(services) == 1:
    service_name = next(iter(services.keys()))

if service_name is None:
    for name in services.keys():
        n = str(name).lower()
        if 'remna' in n or 'node' in n or 'xray' in n:
            service_name = name
            break

if service_name is None:
    service_name = next(iter(services.keys()))

svc = services.get(service_name) or {}
container_name = str((svc or {}).get('container_name', '')).strip() or str(service_name)

print(str(service_name))
print(container_name)
PY
)"

    if [ -n "$resolved" ]; then
        local resolved_service
        local resolved_container
        resolved_service="$(printf '%s\n' "$resolved" | sed -n '1p')"
        resolved_container="$(printf '%s\n' "$resolved" | sed -n '2p')"

        if [ -z "${RW_OPT_OOM_TARGET_SERVICE:-}" ] && [ -n "$resolved_service" ]; then
            COMPOSE_SERVICE_NAME="$resolved_service"
        fi
        if [ -z "${RW_OPT_OOM_TARGET_CONTAINER:-}" ]; then
            if [ -n "$resolved_container" ]; then
                COMPOSE_CONTAINER_NAME="$resolved_container"
            else
                COMPOSE_CONTAINER_NAME="$COMPOSE_SERVICE_NAME"
            fi
        fi
    fi
}

detect_resources() {
    CPU_CORES=$(nproc 2>/dev/null || echo 4)
    CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ //' || echo "Unknown")
    MEM_TOTAL_KB=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    if [ -z "$MEM_TOTAL_KB" ]; then
        MEM_TOTAL_KB=4194304
    fi
    MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
    MEM_TOTAL_GB="$(awk -v m="$MEM_TOTAL_MB" 'BEGIN { printf "%.1f", m / 1024 }')"
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
    NET_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' || echo "eth0")
    if [ -z "$NET_IFACE" ]; then
        NET_IFACE="eth0"
    fi

    resolve_compose_target_path
    resolve_compose_runtime_targets
}

calculate_parameters() {
    # Reserve 1GB for host OS (kernel, sshd, docker daemon, oom-watch)
    SYS_RESERVE=1024
    AVAILABLE_MB=$((MEM_TOTAL_MB - SYS_RESERVE))
    # Round down to nearest 256MB boundary
    CONTAINER_MEM_MB=$((AVAILABLE_MB / 256 * 256))
    if [ "$CONTAINER_MEM_MB" -lt 1024 ]; then
        CONTAINER_MEM_MB=1024
    fi
    if [ -f "$EXISTING_COMPOSE" ] && command -v python3 >/dev/null 2>&1; then
        local compose_mem_limit_mb
        compose_mem_limit_mb="$(python3 - "$EXISTING_COMPOSE" "$COMPOSE_SERVICE_NAME" <<'PY'
import re
import sys
from pathlib import Path

compose_path = Path(sys.argv[1])
service_name = sys.argv[2]

try:
    import yaml  # type: ignore
except Exception:
    print("")
    raise SystemExit(0)

try:
    raw = yaml.safe_load(compose_path.read_text(encoding='utf-8')) or {}
except Exception:
    print("")
    raise SystemExit(0)

services = raw.get('services') or {}
if not isinstance(services, dict):
    print("")
    raise SystemExit(0)

svc = services.get(service_name) or {}
if not isinstance(svc, dict):
    print("")
    raise SystemExit(0)

raw_limit = svc.get('mem_limit')
if raw_limit is None:
    deploy = svc.get('deploy') or {}
    resources = deploy.get('resources') if isinstance(deploy, dict) else None
    limits = resources.get('limits') if isinstance(resources, dict) else None
    raw_limit = limits.get('memory') if isinstance(limits, dict) else None

if raw_limit is None:
    print("")
    raise SystemExit(0)

value = str(raw_limit).strip().lower()
match = re.match(r'^([0-9]+(?:\.[0-9]+)?)([kmg]i?b?|b)?$', value)
if not match:
    print("")
    raise SystemExit(0)

num = float(match.group(1))
unit = (match.group(2) or 'b')

if unit in ('g', 'gb', 'gib'):
    mb = int(num * 1024)
elif unit in ('m', 'mb', 'mib'):
    mb = int(num)
elif unit in ('k', 'kb', 'kib'):
    mb = int(num / 1024)
else:
    mb = int(num / (1024 * 1024))

print(str(mb if mb > 0 else ""))
PY
)"
        if [ -n "$compose_mem_limit_mb" ] && [ "$compose_mem_limit_mb" -gt 0 ] && [ "$compose_mem_limit_mb" -lt "$CONTAINER_MEM_MB" ]; then
            log_info "Using existing compose mem_limit=${compose_mem_limit_mb}MB as effective GC ceiling (host-derived=${CONTAINER_MEM_MB}MB)"
            CONTAINER_MEM_MB="$compose_mem_limit_mb"
        fi
    fi

    CONTAINER_MEM_RESERVE=$((CONTAINER_MEM_MB / 4))

    # Reserve 0.5 CPU for host OS, give the rest to the container
    # Use awk for float arithmetic: CPU_CORES - 0.5
    CONTAINER_CPUS="$(awk "BEGIN { v = ${CPU_CORES} - 0.5; if (v < 1) v = 1; printf \"%.1f\", v }")"

    TCP_RMEM_MAX=$((MEM_TOTAL_MB * 1024 * 4))
    TCP_WMEM_MAX=$TCP_RMEM_MAX
    # Cloudflare best practice: 256KB default, kernel auto-tunes up as needed per-socket
    # High default wastes memory on idle/localhost connections without throughput benefit
    TCP_BUFFER_DEFAULT=262144
    if [ "$TCP_RMEM_MAX" -gt 268435456 ]; then TCP_RMEM_MAX=268435456; fi
    if [ "$TCP_RMEM_MAX" -lt 16777216 ]; then TCP_RMEM_MAX=16777216; fi

    CONNTRACK_MAX=$((MEM_TOTAL_MB * 64))
    if [ "$CONNTRACK_MAX" -gt 1048576 ]; then CONNTRACK_MAX=1048576; fi
    if [ "$CONNTRACK_MAX" -lt 262144 ]; then CONNTRACK_MAX=262144; fi

    FD_SOFT=$((MEM_TOTAL_MB * 32))
    if [ "$FD_SOFT" -gt 524288 ]; then FD_SOFT=524288; fi
    if [ "$FD_SOFT" -lt 65536 ]; then FD_SOFT=65536; fi
    FD_HARD=$((FD_SOFT * 2))
    if [ "$FD_HARD" -gt 1048576 ]; then FD_HARD=1048576; fi

    SOMAXCONN=$((CPU_CORES * 1024))
    if [ "$SOMAXCONN" -gt 65535 ]; then SOMAXCONN=65535; fi
    if [ "$SOMAXCONN" -lt 4096 ]; then SOMAXCONN=4096; fi

    SYN_BACKLOG=$((SOMAXCONN * 2))
    if [ "$SYN_BACKLOG" -gt 131072 ]; then SYN_BACKLOG=131072; fi

    NETDEV_BACKLOG=$((CPU_CORES * 2000))
    if [ "$NETDEV_BACKLOG" -gt 50000 ]; then NETDEV_BACKLOG=50000; fi
    if [ "$NETDEV_BACKLOG" -lt 5000 ]; then NETDEV_BACKLOG=5000; fi

    RING_SIZE=$((CPU_CORES * 512))
    if [ "$RING_SIZE" -gt 8192 ]; then RING_SIZE=8192; fi
    if [ "$RING_SIZE" -lt 512 ]; then RING_SIZE=512; fi

    # Queue discipline: fq (default, optimal for BBR pacing) or cake (when --shaping is used)
    if [ -n "$SHAPING_BANDWIDTH" ]; then
        QDISC="cake"
    else
        QDISC="${RW_OPT_QDISC:-fq}"
    fi
    case "$QDISC" in
        fq|cake) ;;
        *) log_warn "Unknown RW_OPT_QDISC='${QDISC}', falling back to fq"; QDISC="fq" ;;
    esac

    TCP_FIN_TIMEOUT=15
    CONNTRACK_ESTABLISHED=1200
    TCP_NOTSENT_LOWAT=131072
    TCP_MAX_ORPHANS=$((MEM_TOTAL_MB * 64))
    if [ "$TCP_MAX_ORPHANS" -gt 1048576 ]; then TCP_MAX_ORPHANS=1048576; fi
    if [ "$TCP_MAX_ORPHANS" -lt 65536 ]; then TCP_MAX_ORPHANS=65536; fi
    TCP_ORPHAN_RETRIES=3
    SWAPPINESS=1

    # GC profile: controls Go runtime env vars (GOMEMLIMIT, GOGC) in apply_compose()
    GC_PROFILE_RAW="${RW_OPT_GC_PROFILE:-}"
    GC_PROFILE="${GC_PROFILE_RAW}"
    case "$GC_PROFILE" in
        "")
            GC_PROFILE="conservative"
            GC_PROFILE_REASON="default(unset)"
            GOGC_VALUE="100"
            GOMEMLIMIT_HEADROOM=$((CONTAINER_MEM_MB - 1500))
            if [ "$GOMEMLIMIT_HEADROOM" -lt 1024 ]; then
                log_warn "Container memory ${CONTAINER_MEM_MB}MB too small for conservative GC profile (headroom=${GOMEMLIMIT_HEADROOM}MB < 1024MB); GOMEMLIMIT will NOT be set, GOGC=100 still applies"
                GOMEMLIMIT_MIB=""
            else
                GOMEMLIMIT_MIB=$((GOMEMLIMIT_HEADROOM / 100 * 100))
            fi
            ;;
        conservative)
            GC_PROFILE_REASON="explicit(conservative)"
            GOGC_VALUE="100"
            GOMEMLIMIT_HEADROOM=$((CONTAINER_MEM_MB - 1500))
            if [ "$GOMEMLIMIT_HEADROOM" -lt 1024 ]; then
                log_warn "Container memory ${CONTAINER_MEM_MB}MB too small for conservative GC profile (headroom=${GOMEMLIMIT_HEADROOM}MB < 1024MB); GOMEMLIMIT will NOT be set, GOGC=100 still applies"
                GOMEMLIMIT_MIB=""
            else
                GOMEMLIMIT_MIB=$((GOMEMLIMIT_HEADROOM / 100 * 100))
            fi
            ;;
        default)
            GC_PROFILE="conservative"
            GC_PROFILE_REASON="explicit(default-alias)"
            GOGC_VALUE="100"
            GOMEMLIMIT_HEADROOM=$((CONTAINER_MEM_MB - 1500))
            if [ "$GOMEMLIMIT_HEADROOM" -lt 1024 ]; then
                log_warn "Container memory ${CONTAINER_MEM_MB}MB too small for conservative GC profile (headroom=${GOMEMLIMIT_HEADROOM}MB < 1024MB); GOMEMLIMIT will NOT be set, GOGC=100 still applies"
                GOMEMLIMIT_MIB=""
            else
                GOMEMLIMIT_MIB=$((GOMEMLIMIT_HEADROOM / 100 * 100))
            fi
            ;;
        fallback)
            GC_PROFILE_REASON="explicit(fallback)"
            GOGC_VALUE="150"
            GOMEMLIMIT_MIB=""
            ;;
        *)
            log_warn "Unknown RW_OPT_GC_PROFILE='${GC_PROFILE}'; falling back to conservative profile"
            GC_PROFILE="conservative"
            GC_PROFILE_REASON="default(unknown)"
            GOGC_VALUE="100"
            GOMEMLIMIT_HEADROOM=$((CONTAINER_MEM_MB - 1500))
            if [ "$GOMEMLIMIT_HEADROOM" -lt 1024 ]; then
                log_warn "Container memory ${CONTAINER_MEM_MB}MB too small for conservative GC profile (headroom=${GOMEMLIMIT_HEADROOM}MB < 1024MB); GOMEMLIMIT will NOT be set, GOGC=100 still applies"
                GOMEMLIMIT_MIB=""
            else
                GOMEMLIMIT_MIB=$((GOMEMLIMIT_HEADROOM / 100 * 100))
            fi
            ;;
    esac

    # Build Python code snippets for apply_compose() GOMEMLIMIT injection
    if [ -n "$GOMEMLIMIT_MIB" ]; then
        GOMEMLIMIT_LIST_ENTRY="    env.append('GOMEMLIMIT=${GOMEMLIMIT_MIB}MiB')"
        GOMEMLIMIT_DICT_ENTRY="    env['GOMEMLIMIT'] = '${GOMEMLIMIT_MIB}MiB'"
    else
        GOMEMLIMIT_LIST_ENTRY=""
        GOMEMLIMIT_DICT_ENTRY=""
    fi
}

preview_plan() {
    log_info "Preview plan (no changes applied yet)"
    echo
    echo "Selected target(s): ${APPLY_TARGET_RAW}"
    echo "Selected zones: ${SELECTED_ZONES_CSV}"
    echo "Apply sequence (stable): ${SELECTED_ZONES_CSV}"
    echo
    echo "Detected host:"
    echo "  CPU:       ${CPU_CORES} cores (${CPU_MODEL})"
    echo "  RAM:       ${MEM_TOTAL_MB} MB (~${MEM_TOTAL_GB} GB)"
    echo "  Virtual:   ${VIRT_TYPE}"
    echo "  Interface: ${NET_IFACE}"
    echo "  Compose file: ${EXISTING_COMPOSE}"
    echo "  Compose service: ${COMPOSE_SERVICE_NAME}"
    echo "  Container target: ${COMPOSE_CONTAINER_NAME}"
    echo "  OOM target overrides: service=${RW_OPT_OOM_TARGET_SERVICE:-<auto>} container=${RW_OPT_OOM_TARGET_CONTAINER:-<auto>}"
    echo
    echo "Calculated values:"
    echo "  Container RAM limit:   ${CONTAINER_MEM_MB} MB"
    echo "  Container RAM reserve: ${CONTAINER_MEM_RESERVE} MB"
    echo "  Container CPUs:        ${CONTAINER_CPUS}"
    echo "  somaxconn:             ${SOMAXCONN}"
    echo "  SYN backlog:           ${SYN_BACKLOG}"
    echo "  netdev_max_backlog:    ${NETDEV_BACKLOG}"
    echo "  conntrack_max:         ${CONNTRACK_MAX}"
    echo "  file descriptors:      ${FD_SOFT}/${FD_HARD}"
    echo "  tcp buffer max:        ${TCP_RMEM_MAX}"
    echo "  tcp_fin_timeout:       ${TCP_FIN_TIMEOUT}"
    echo "  tcp_keepalive_time:    300"
    echo "  conntrack_established: ${CONNTRACK_ESTABLISHED}"
    echo "  tcp_notsent_lowat:     ${TCP_NOTSENT_LOWAT}"
    echo "  tcp_max_orphans:       ${TCP_MAX_ORPHANS} (adaptive: MEM_TOTAL_MB*64, clamp [65536, 1048576])"
    echo "  tcp_orphan_retries:    ${TCP_ORPHAN_RETRIES}"
    echo "  swappiness:            ${SWAPPINESS}"
    echo "  gc_profile:            ${GC_PROFILE} (${GC_PROFILE_REASON}, GOGC=${GOGC_VALUE})"
    if [ -n "$GOMEMLIMIT_MIB" ]; then
        echo "  gomemlimit:            ${GOMEMLIMIT_MIB} MiB (headroom=container_mem - 1500MB)"
    else
        echo "  gomemlimit:            (not set)"
    fi
    echo "  qdisc:                 ${QDISC}"
    if [ -n "$SHAPING_BANDWIDTH" ]; then
        echo "  shaping:               ${SHAPING_BANDWIDTH} per-flow (CAKE flowblind)"
    fi
    echo

    # --- Conflict detection in preview ---
    local conflict_files=""
    conflict_files="$(scan_conflicting_sysctl_configs)"
    if [ -n "$conflict_files" ]; then
        log_warn "Conflicting sysctl configs detected:"
        local file_info
        while IFS= read -r file_info; do
            local cfile cparams
            cfile="${file_info%%$'\t'*}"
            cparams="${file_info#*$'\t'}"
            log_warn "  $cfile overrides: $cparams"
        done <<< "$conflict_files"
        echo
    fi

    # --- Show current vs target delta for sysctl zone ---
    if list_contains "sysctl" "${SELECTED_ZONES[*]}"; then
        local delta_shown=0
        local param current target
        while IFS= read -r param; do
            current="$(get_current_sysctl_value "$param")"
            target=""
            case "$param" in
                net.core.default_qdisc)          target="${QDISC}" ;;
                net.ipv4.tcp_congestion_control) target="bbr" ;;
                net.ipv4.tcp_fin_timeout)        target="${TCP_FIN_TIMEOUT}" ;;
                net.ipv4.tcp_notsent_lowat)      target="${TCP_NOTSENT_LOWAT}" ;;
                net.ipv4.tcp_max_orphans)        target="${TCP_MAX_ORPHANS}" ;;
                net.ipv4.tcp_orphan_retries)     target="${TCP_ORPHAN_RETRIES}" ;;
                net.netfilter.nf_conntrack_tcp_timeout_established) target="${CONNTRACK_ESTABLISHED}" ;;
                net.netfilter.nf_conntrack_tcp_timeout_time_wait) target="15" ;;
                net.netfilter.nf_conntrack_tcp_timeout_fin_wait)  target="15" ;;
                net.core.rmem_max)               target="${TCP_RMEM_MAX}" ;;
                net.core.wmem_max)               target="${TCP_WMEM_MAX}" ;;
                net.ipv4.tcp_rmem)               target="4096 ${TCP_BUFFER_DEFAULT} ${TCP_RMEM_MAX}" ;;
                net.ipv4.tcp_wmem)               target="4096 ${TCP_BUFFER_DEFAULT} ${TCP_WMEM_MAX}" ;;
                vm.swappiness)                   target="${SWAPPINESS}" ;;
            esac
            if [ "$current" != "$target" ] && [ "$current" != "__missing__" ]; then
                if [ "$delta_shown" -eq 0 ]; then
                    echo "Delta (current → target):"
                    delta_shown=1
                fi
                printf "  %-45s current=%s → target=%s\n" "$param:" "$current" "$target"
            fi
        done < <(get_managed_sysctl_params)
        if [ "$delta_shown" -eq 1 ]; then
            echo
        fi
    else
        # Non-sysctl zone: skip delta
        :
    fi

    if is_test_mode; then
        echo "TEST_MODE: enabled (non-mutating apply path)"
    fi

    if ! list_contains "docker-daemon" "${SELECTED_ZONES[@]}"; then
        echo "docker-daemon zone omitted (default for --apply all): ${DOCKER_CONFIG} will not be modified."
        echo "  To include: RW_OPT_SKIP_DOCKER_DAEMON=0 with --apply all, or add docker-daemon to the zone list."
        echo
    fi

    echo "Paths that would be touched in apply mode:"
    echo "  ${SYSCTL_CONFIG}"
    echo "  ${LIMITS_CONFIG}"
    echo "  ${DOCKER_CONFIG}"
    echo "  ${EXISTING_COMPOSE}"
    echo "  ${OOM_SCRIPT}"
    echo "  ${OOM_SERVICE}"
    echo "  ${MODULES_LOAD_BBR}"
    echo "  ${CURRENT_TX_DIR:-<tx-dir>}/backups/<zone>/..."
    echo
    if [ "${RW_OPT_COMPOSE_ENSURE_UP:-1}" != "0" ]; then
        echo "Post-apply: docker compose up -d for each of:"
        local _cef
        for _cef in "${COMPOSE_ENSURE_STACK_PATHS[@]}"; do
            echo "  ${_cef} (if present)"
        done
        echo
    fi
}

confirm_apply() {
    local answer=""
    echo "Type Yes to apply"
    if ! read -r answer; then
        answer=""
    fi

    if [ "$answer" != "Yes" ]; then
        echo "Aborted"
        return 1
    fi

    return 0
}

backup_configs_if_needed() {
    log_info "Using tx-local per-zone backups under ${CURRENT_TX_DIR}/backups"
}

apply_sysctl() {
    log_info "[sysctl] Applying kernel parameters"

    # --- Conflict detection: scan for competing sysctl configs ---
    local conflict_files=""
    conflict_files="$(scan_conflicting_sysctl_configs)"
    if [ -n "$conflict_files" ]; then
        log_warn "Conflicting sysctl configs detected:"
        local file_info
        while IFS= read -r file_info; do
            local cfile cparams
            cfile="${file_info%%$'\t'*}"
            cparams="${file_info#*$'\t'}"
            log_warn "  $cfile overrides: $cparams"
        done <<< "$conflict_files"
    fi

    # --- Idempotency: skip if all params already match ---
    if is_zone_idempotent; then
        log_warn "All sysctl parameters already match target values — no-op apply"
        return 0
    fi

    if ! capture_backup_metadata "$CURRENT_OP_PATH" "sysctl" "sysctl_main" "$SYSCTL_CONFIG"; then
        return 1
    fi
    if ! capture_backup_metadata "$CURRENT_OP_PATH" "sysctl" "sysctl_modules_load" "$MODULES_LOAD_BBR"; then
        return 1
    fi
    if ! capture_backup_metadata "$CURRENT_OP_PATH" "sysctl" "sysctl_modules_conntrack" "$MODULES_LOAD_CONNTRACK"; then
        return 1
    fi
    capture_sysctl_runtime_snapshot "$CURRENT_OP_PATH"
    journal_append_field "$CURRENT_OP_PATH" "state_capture_status" "captured"
    journal_append_field "$CURRENT_OP_PATH" "sysctl_tcp_fin_timeout" "${TCP_FIN_TIMEOUT}"
    journal_append_field "$CURRENT_OP_PATH" "sysctl_conntrack_established" "${CONNTRACK_ESTABLISHED}"
    journal_append_field "$CURRENT_OP_PATH" "sysctl_tcp_notsent_lowat" "${TCP_NOTSENT_LOWAT}"
    journal_append_field "$CURRENT_OP_PATH" "sysctl_tcp_max_orphans" "${TCP_MAX_ORPHANS}"

    if is_test_mode; then
        log_info "TEST_MODE: would ensure tcp_bbr module is available"
        log_info "TEST_MODE: would ensure nf_conntrack module is available"
        log_info "TEST_MODE: would write ${SYSCTL_CONFIG}"
        log_info "TEST_MODE: would write ${MODULES_LOAD_BBR}"
        log_info "TEST_MODE: would write ${MODULES_LOAD_CONNTRACK}"
        log_info "TEST_MODE: would run sysctl --system"
        return 0
    fi

    if ! lsmod 2>/dev/null | grep -q tcp_bbr; then
        modprobe tcp_bbr 2>/dev/null && log_success "BBR module loaded" || log_warn "Could not load BBR module (may need kernel >= 4.9)"
    fi

    if ! grep -q tcp_bbr /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "tcp_bbr" > "$MODULES_LOAD_BBR"
        log_success "BBR module will load on boot"
    fi

    if ! lsmod 2>/dev/null | grep -q nf_conntrack; then
        modprobe nf_conntrack 2>/dev/null && log_success "nf_conntrack module loaded" || log_warn "Could not load nf_conntrack module"
    fi

    if ! grep -q nf_conntrack /etc/modules-load.d/*.conf 2>/dev/null; then
        echo "nf_conntrack" > "$MODULES_LOAD_CONNTRACK"
        log_success "nf_conntrack module will load on boot (before sysctl)"
    fi

    cat > "${SYSCTL_CONFIG}" << EOF
#===============================================================================
# RemnaWave Adaptive Optimization
# Generated $(date) for ${CPU_CORES} cores, ${MEM_TOTAL_MB}MB RAM
# Run optimize.sh --apply all to regenerate
#===============================================================================

net.core.somaxconn = ${SOMAXCONN}
net.core.netdev_max_backlog = ${NETDEV_BACKLOG}
net.core.rmem_default = ${TCP_BUFFER_DEFAULT}
net.core.wmem_default = ${TCP_BUFFER_DEFAULT}
net.core.rmem_max = ${TCP_RMEM_MAX}
net.core.wmem_max = ${TCP_WMEM_MAX}
net.core.optmem_max = $((TCP_RMEM_MAX / 4))
net.ipv4.tcp_rmem = 4096 ${TCP_BUFFER_DEFAULT} ${TCP_RMEM_MAX}
net.ipv4.tcp_wmem = 4096 ${TCP_BUFFER_DEFAULT} ${TCP_WMEM_MAX}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_max_syn_backlog = ${SYN_BACKLOG}
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_fin_timeout = ${TCP_FIN_TIMEOUT}
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.ip_local_port_range = 10240 65535
net.core.default_qdisc = ${QDISC}
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = ${TCP_NOTSENT_LOWAT}
net.ipv4.tcp_max_orphans = ${TCP_MAX_ORPHANS}
net.ipv4.tcp_orphan_retries = ${TCP_ORPHAN_RETRIES}
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1
net.netfilter.nf_conntrack_max = ${CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 15
net.netfilter.nf_conntrack_tcp_timeout_established = ${CONNTRACK_ESTABLISHED}
vm.swappiness = ${SWAPPINESS}
vm.max_map_count = 1048576
EOF

    # Disable conflicting sysctl configs before applying
    if [ -n "$conflict_files" ]; then
        local file_info cfile cparams disabled_name
        local disabled_count=0
        while IFS= read -r file_info; do
            cfile="${file_info%%$'\t'*}"
            cparams="${file_info#*$'\t'}"
            disabled_name="${cfile}.disabled"
            if [ -f "$disabled_name" ]; then
                disabled_name="${cfile}.disabled.${CURRENT_TX_ID}"
            fi
            if [ -f "$cfile" ]; then
                mv "$cfile" "$disabled_name"
                log_warn "Disabled conflicting config: $cfile → ${disabled_name}"
                disabled_count=$((disabled_count + 1))
                journal_append_field "$CURRENT_OP_PATH" "sysctl_disabled_${disabled_count}_from" "$cfile"
                journal_append_field "$CURRENT_OP_PATH" "sysctl_disabled_${disabled_count}_to" "$disabled_name"
            fi
        done <<< "$conflict_files"
        journal_append_field "$CURRENT_OP_PATH" "sysctl_disabled_count" "$disabled_count"
    fi

    if sysctl --system 2>/dev/null; then
        log_success "Kernel parameters applied"
    else
        log_warn "sysctl --system failed, trying direct apply..."
        sysctl -p "${SYSCTL_CONFIG}" 2>/dev/null || log_warn "Failed to apply sysctl settings"
    fi
}

apply_limits() {
    log_info "[limits] Configuring file descriptor limits"

    if ! capture_backup_metadata "$CURRENT_OP_PATH" "limits" "limits_main" "$LIMITS_CONFIG"; then
        return 1
    fi
    journal_append_field "$CURRENT_OP_PATH" "state_capture_status" "captured"

    if is_test_mode; then
        log_info "TEST_MODE: would write ${LIMITS_CONFIG}"
        return 0
    fi

    cat > "${LIMITS_CONFIG}" << EOF
# RemnaWave Adaptive Limits - ${MEM_TOTAL_MB}MB RAM
* soft nofile ${FD_SOFT}
* hard nofile ${FD_HARD}
root soft nofile ${FD_HARD}
root hard nofile ${FD_HARD}
EOF

    log_success "File descriptor limits: soft=${FD_SOFT}, hard=${FD_HARD}"
}

apply_docker_daemon() {
    log_info "[docker-daemon] Configuring Docker daemon"

    if ! capture_backup_metadata "$CURRENT_OP_PATH" "docker-daemon" "docker_daemon" "$DOCKER_CONFIG"; then
        return 1
    fi

    if [ "${RW_OPT_SKIP_DOCKER_DAEMON:-1}" = "1" ] && [ "${DOCKER_DAEMON_EXPLICITLY_SELECTED:-0}" != "1" ]; then
        journal_append_field "$CURRENT_OP_PATH" "state_capture_status" "skipped"
        journal_append_field "$CURRENT_OP_PATH" "state_capture_reason" "RW_OPT_SKIP_DOCKER_DAEMON_default"
        mark_zone_skipped "docker-daemon off by default (RW_OPT_SKIP_DOCKER_DAEMON=0 or explicit zone)"
        log_warn "[docker-daemon] Skipped; ${DOCKER_CONFIG} not modified (no SIGHUP/reload)"
        return 0
    fi

    journal_append_field "$CURRENT_OP_PATH" "state_capture_status" "captured"

    local docker_was_active="0"
    if is_test_mode; then
        docker_was_active="1"
    elif systemctl is-active --quiet docker 2>/dev/null; then
        docker_was_active="1"
    fi
    journal_append_field "$CURRENT_OP_PATH" "docker_was_active" "$docker_was_active"

    if is_test_mode; then
        log_info "TEST_MODE: would write/merge ${DOCKER_CONFIG}"
        log_info "TEST_MODE: would restart docker daemon if active"
        return 0
    fi

    mkdir -p /etc/docker

    if [ -f "$DOCKER_CONFIG" ] && [ -s "$DOCKER_CONFIG" ]; then
        if command -v python3 >/dev/null 2>&1; then
            python3 -c "
import json
try:
    with open('$DOCKER_CONFIG') as f: existing = json.load(f)
except Exception:
    existing = {}
existing.setdefault('log-driver', 'json-file')
existing.setdefault('log-opts', {})['max-size'] = '50m'
existing.setdefault('log-opts', {})['max-file'] = '5'
existing.setdefault('default-ulimits', {})
existing['default-ulimits']['nofile'] = {'Name': 'nofile', 'Hard': $FD_HARD, 'Soft': $FD_SOFT}
existing.setdefault('storage-driver', 'overlay2')
existing.setdefault('live-restore', True)
with open('$DOCKER_CONFIG', 'w') as f:
    json.dump(existing, f, indent=2)
print('Merged')
" 2>/dev/null && log_success "Docker config merged with existing" || log_warn "Failed to merge docker config"
        else
            log_warn "python3 not available; writing default docker daemon config"
            cat > "${DOCKER_CONFIG}" << DOCKEREOF
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "50m", "max-file": "5"},
  "default-ulimits": {
    "nofile": {"Name": "nofile", "Hard": ${FD_HARD}, "Soft": ${FD_SOFT}}
  },
  "storage-driver": "overlay2",
  "live-restore": true
}
DOCKEREOF
        fi
    else
        cat > "${DOCKER_CONFIG}" << DOCKEREOF
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "50m", "max-file": "5"},
  "default-ulimits": {
    "nofile": {"Name": "nofile", "Hard": ${FD_HARD}, "Soft": ${FD_SOFT}}
  },
  "storage-driver": "overlay2",
  "live-restore": true
}
DOCKEREOF
        log_success "Docker config written"
    fi

    if [ "$docker_was_active" = "1" ]; then
        if kill -SIGHUP "$(pidof dockerd 2>/dev/null)" 2>/dev/null; then
            log_success "Docker daemon reloaded (SIGHUP, no container restart)"
        elif systemctl reload docker 2>/dev/null; then
            log_success "Docker daemon reloaded via systemctl"
        else
            log_warn "Docker reload failed; daemon config will apply on next restart"
        fi
    else
        log_warn "Docker not running pre-apply. Skipping reload."
    fi
}

apply_compose() {
    log_info "[compose] Overwriting target docker-compose with resource limits"

    resolve_compose_runtime_targets
    if ! capture_backup_metadata "$CURRENT_OP_PATH" "compose" "compose_target" "$EXISTING_COMPOSE"; then
        return 1
    fi
    journal_append_field "$CURRENT_OP_PATH" "state_capture_status" "captured"

    if is_test_mode; then
        log_info "TEST_MODE: would patch and overwrite ${EXISTING_COMPOSE}"
        return 0
    fi

    if ! command -v python3 >/dev/null 2>&1; then
        mark_zone_skipped "python3 missing"
        log_warn "python3 missing; skipping compose zone"
        return 0
    fi

    if [ -f "${EXISTING_COMPOSE}" ] && [ -s "${EXISTING_COMPOSE}" ]; then
        if python3 -c "
import yaml
with open('${EXISTING_COMPOSE}') as f:
    compose = yaml.safe_load(f)
if compose is None:
    compose = {}
services = compose.setdefault('services', {})
svc = services.setdefault('${COMPOSE_SERVICE_NAME}', {})
svc['mem_limit'] = '${CONTAINER_MEM_MB}m'
svc['mem_reservation'] = '${CONTAINER_MEM_RESERVE}m'
svc['cpus'] = float(${CONTAINER_CPUS})
ulimits = svc.setdefault('ulimits', {})
nofile = ulimits.setdefault('nofile', {})
soft = nofile.get('soft', 1048576)
hard = nofile.get('hard', 1048576)
nofile['soft'] = max(soft, ${FD_SOFT})
nofile['hard'] = max(hard, ${FD_HARD})
if 'restart' not in svc:
    svc['restart'] = 'always'
env = svc.setdefault('environment', {})
if env is None:
    env = {}
    svc['environment'] = env
if isinstance(env, list):
    env = [e for e in env if not e.startswith(('GOMEMLIMIT=', 'GOGC=', 'GODEBUG='))]
    env.append('GOGC=${GOGC_VALUE}')
    env.append('GODEBUG=madvdontneed=1')
${GOMEMLIMIT_LIST_ENTRY}
    svc['environment'] = env
else:
    env.pop('GOMEMLIMIT', None)
    env['GOGC'] = '${GOGC_VALUE}'
    env['GODEBUG'] = 'madvdontneed=1'
${GOMEMLIMIT_DICT_ENTRY}
with open('${EXISTING_COMPOSE}', 'w') as f:
    yaml.dump(compose, f, default_flow_style=False, allow_unicode=True, sort_keys=False)
print('Patched')
" 2>/dev/null; then
            log_success "Patched compose overwritten at ${EXISTING_COMPOSE}"

            # Apply resource limits to running container on-the-fly via docker update
            if docker inspect "${COMPOSE_CONTAINER_NAME}" >/dev/null 2>&1; then
                local mem_bytes=$(( CONTAINER_MEM_MB * 1024 * 1024 ))
                local reserve_bytes=$(( CONTAINER_MEM_RESERVE * 1024 * 1024 ))
                if docker update \
                    --memory "${mem_bytes}" \
                    --memory-swap "${mem_bytes}" \
                    --memory-reservation "${reserve_bytes}" \
                    --cpus "${CONTAINER_CPUS}" \
                    "${COMPOSE_CONTAINER_NAME}" >/dev/null 2>&1; then
                    log_success "Live-applied resource limits to running container ${COMPOSE_CONTAINER_NAME} (no restart)"
                else
                    log_warn "docker update failed; limits saved in compose but will apply on next restart"
                fi
            else
                log_info "Container ${COMPOSE_CONTAINER_NAME} not running; limits will apply on next start"
            fi
        else
            mark_zone_skipped "compose patch failed (python3-yaml may be missing)"
            log_warn "Compose patch failed (python3-yaml may be missing); skipping"
        fi
    else
        mark_zone_skipped "source compose file missing"
        log_warn "No existing docker-compose.yml found at ${EXISTING_COMPOSE}; skipping compose patch"
    fi
}

apply_compose_ensure_stacks_up() {
    if [ "${RW_OPT_COMPOSE_ENSURE_UP:-1}" = "0" ]; then
        return 0
    fi

    if is_test_mode; then
        log_info "TEST_MODE: would run docker compose up -d for remnanode/selfsteal stacks"
        return 0
    fi

    if ! command -v docker >/dev/null 2>&1; then
        log_warn "[compose-ensure] docker CLI not found; skipping stack ensure"
        return 0
    fi

    local compose_file any_run=0
    for compose_file in "${COMPOSE_ENSURE_STACK_PATHS[@]}"; do
        [ -f "$compose_file" ] && [ -s "$compose_file" ] || continue
        any_run=1
        log_info "[compose-ensure] docker compose up -d (${compose_file})"
        if ! docker compose -f "$compose_file" up -d; then
            log_error "[compose-ensure] docker compose up -d failed for ${compose_file}"
            return 1
        fi
    done

    if [ "$any_run" = "0" ]; then
        log_info "[compose-ensure] no stack compose files present; skipped"
    fi
    return 0
}

apply_net_iface() {
    log_info "[net-iface] Optimizing network interface ${NET_IFACE}"

    if [ -z "$NET_IFACE" ]; then
        mark_zone_skipped "net interface missing"
        journal_append_field "$CURRENT_OP_PATH" "state_capture_status" "failed"
        journal_append_field "$CURRENT_OP_PATH" "state_capture_reason" "net_iface_missing"
        log_warn "Unable to detect net interface; skipping net-iface zone"
        return 0
    fi

    if ! command -v ethtool >/dev/null 2>&1; then
        mark_zone_skipped "ethtool missing"
        journal_append_field "$CURRENT_OP_PATH" "state_capture_status" "failed"
        journal_append_field "$CURRENT_OP_PATH" "state_capture_reason" "ethtool_missing"
        log_warn "ethtool missing; skipping net-iface zone"
        return 0
    fi

    if ! capture_net_iface_state "$CURRENT_OP_PATH"; then
        log_warn "Could not fully capture net-iface pre-state; rollback metadata may be incomplete"
    fi

    if is_test_mode; then
        log_info "TEST_MODE: would tune ethtool ring/offload/coalesce on ${NET_IFACE}"
        return 0
    fi

    if ethtool -g "$NET_IFACE" >/dev/null 2>&1; then
        if ethtool -G "$NET_IFACE" rx "$RING_SIZE" tx "$RING_SIZE" 2>/dev/null; then
            log_success "Ring buffer tuned: rx=${RING_SIZE} tx=${RING_SIZE}"
        else
            log_warn "Ring buffer: cannot set (cloud NICs may not support this)"
        fi
    fi

    if ethtool -K "$NET_IFACE" gro on gso on tso on 2>/dev/null; then
        log_success "GRO/GSO/TSO enabled"
    else
        log_warn "Could not set offloading"
    fi
    ethtool -C "$NET_IFACE" adaptive-rx on adaptive-tx on 2>/dev/null || true

    # Apply CAKE traffic shaping if --shaping was specified
    if [ -n "$SHAPING_BANDWIDTH" ]; then
        if tc qdisc replace dev "$NET_IFACE" root cake bandwidth "$SHAPING_BANDWIDTH" flowblind 2>/dev/null; then
            log_success "CAKE shaping applied: ${SHAPING_BANDWIDTH} per-flow on ${NET_IFACE}"
        else
            log_warn "CAKE shaping failed; tc qdisc not applied"
        fi
    fi
}

apply_oom_watch() {
    log_info "[oom-watch] Installing OOM watch service"

    if ! capture_backup_metadata "$CURRENT_OP_PATH" "oom-watch" "oom_script" "$OOM_SCRIPT"; then
        return 1
    fi
    if ! capture_backup_metadata "$CURRENT_OP_PATH" "oom-watch" "oom_service" "$OOM_SERVICE"; then
        return 1
    fi
    journal_append_field "$CURRENT_OP_PATH" "state_capture_status" "captured"

    local oom_was_enabled="0"
    local oom_was_active="0"

    local oom_unit_name
    oom_unit_name="$(basename "$OOM_SERVICE")"

    if is_test_mode; then
        oom_was_enabled="0"
        oom_was_active="0"
    else
        if systemctl is-enabled "$oom_unit_name" >/dev/null 2>&1; then
            oom_was_enabled="1"
        fi
        if systemctl is-active --quiet "$oom_unit_name" 2>/dev/null; then
            oom_was_active="1"
        fi
    fi

    journal_append_field "$CURRENT_OP_PATH" "oom_was_enabled" "$oom_was_enabled"
    journal_append_field "$CURRENT_OP_PATH" "oom_was_active" "$oom_was_active"

    resolve_compose_runtime_targets

    if is_test_mode; then
        log_info "TEST_MODE: would write ${OOM_SCRIPT}"
        log_info "TEST_MODE: would write ${OOM_SERVICE}"
        log_info "TEST_MODE: would target service=${COMPOSE_SERVICE_NAME} container=${COMPOSE_CONTAINER_NAME} compose=${EXISTING_COMPOSE}"
        log_info "TEST_MODE: would run systemctl daemon-reload/enable/start ${oom_unit_name}"
        return 0
    fi

    cat > "${OOM_SCRIPT}" << OOMEOF
#!/bin/bash
# Watch for OOM events and restart target RemnaWave node service/container
set -euo pipefail

TARGET_COMPOSE_FILE="${EXISTING_COMPOSE}"
TARGET_CONTAINER="${COMPOSE_CONTAINER_NAME}"
TARGET_SERVICE="${COMPOSE_SERVICE_NAME}"
TARGET_LOG="/var/log/remnawave-oom.log"
OOMEOF

    cat >> "${OOM_SCRIPT}" << 'OOMEOF'

resolve_target_container() {
    if [ -n "$TARGET_CONTAINER" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$TARGET_CONTAINER"; then
        echo "$TARGET_CONTAINER"
        return 0
    fi

    if [ -n "$TARGET_SERVICE" ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$TARGET_SERVICE"; then
        echo "$TARGET_SERVICE"
        return 0
    fi

    local by_image
    by_image="$(docker ps --format '{{.Names}} {{.Image}}' 2>/dev/null | awk '$2 ~ /remnawave\/node|remnowave\/node/ {print $1; exit}')"
    if [ -n "$by_image" ]; then
        echo "$by_image"
        return 0
    fi

    echo "${TARGET_CONTAINER:-$TARGET_SERVICE}"
}

restart_target() {
    local container_name="$1"

    if [ -n "$TARGET_SERVICE" ] && [ -f "$TARGET_COMPOSE_FILE" ]; then
        if docker compose -f "$TARGET_COMPOSE_FILE" restart "$TARGET_SERVICE" >/dev/null 2>&1; then
            echo "compose-service:$TARGET_SERVICE"
            return 0
        fi
    fi

    if [ -n "$container_name" ] && docker restart "$container_name" >/dev/null 2>&1; then
        echo "container:$container_name"
        return 0
    fi

    return 1
}

while true; do
    target_name="$(resolve_target_container)"
    if [ -n "$target_name" ] && dmesg --time-format iso 2>/dev/null | tail -100 | grep -Eqi "oom-kill.*($target_name|$TARGET_SERVICE|$TARGET_CONTAINER)|Out of memory.*($target_name|$TARGET_SERVICE|$TARGET_CONTAINER)"; then
        if restarted_via="$(restart_target "$target_name")"; then
            echo "$(date): OOM detected for ${target_name}, restarted via ${restarted_via}" >> "$TARGET_LOG"
        else
            echo "$(date): OOM detected for ${target_name}, restart failed" >> "$TARGET_LOG"
        fi
        sleep 60
    fi
    sleep 10
done
OOMEOF
    chmod +x "${OOM_SCRIPT}"

    cat > "${OOM_SERVICE}" << SVCEOF
[Unit]
Description=RemnaWave OOM Watch
After=docker.service

[Service]
Type=simple
ExecStart=${OOM_SCRIPT}
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
SVCEOF

    if ! systemctl daemon-reload 2>/dev/null; then
        log_warn "systemctl daemon-reload failed; continuing"
    fi
    if ! systemctl enable "$oom_unit_name" 2>/dev/null; then
        log_warn "systemctl enable ${oom_unit_name} failed; continuing"
    fi
    if ! systemctl start "$oom_unit_name" 2>/dev/null; then
        log_warn "systemctl start ${oom_unit_name} failed; continuing"
    fi

    log_success "OOM protection service installed"
}

apply_zone() {
    local zone="$1"
    case "$zone" in
        sysctl) apply_sysctl ;;
        limits) apply_limits ;;
        docker-daemon) apply_docker_daemon ;;
        compose) apply_compose ;;
        net-iface) apply_net_iface ;;
        *)
            log_error "Unexpected zone dispatch: $zone"
            return 1
            ;;
    esac
}

apply_selected_zones() {
    backup_configs_if_needed

    local zone
    local seq=0

    for zone in "${SELECTED_ZONES[@]}"; do
        seq=$((seq + 1))

        local planned_at
        planned_at="$(utc_now)"
        local op_path
        op_path="$(journal_op_path "$seq" "$zone")"
        CURRENT_OP_PATH="$op_path"
        journal_write_op "$seq" "$zone" "planned" "zone scheduled" "$planned_at" ""

        reset_zone_outcome

        if apply_zone "$zone"; then
            local final_status="$ZONE_OUTCOME_STATUS"
            local final_reason="$ZONE_OUTCOME_REASON"
            local finished_at
            finished_at="$(utc_now)"
            journal_write_op "$seq" "$zone" "$final_status" "$final_reason" "$planned_at" "$finished_at"
            log_info "[tx:${CURRENT_TX_ID}] zone=${zone} status=${final_status} reason=${final_reason}"
        else
            local zone_rc=$?
            local finished_at
            finished_at="$(utc_now)"
            local fail_reason="zone command exited with status ${zone_rc}"
            journal_write_op "$seq" "$zone" "failed" "$fail_reason" "$planned_at" "$finished_at"
            log_error "[tx:${CURRENT_TX_ID}] zone=${zone} status=failed reason=${fail_reason}"
            return "$zone_rc"
        fi
    done
}

run_apply_mode() {
    detect_resources
    calculate_parameters
    preview_plan

    if ! confirm_apply; then
        exit 1
    fi

    require_root

    if [ "${#SELECTED_ZONES[@]}" -eq 1 ] && [ "${SELECTED_ZONES[0]}" = "sysctl" ]; then
        if is_zone_idempotent; then
            log_warn "All target parameters already match current values — no-op apply"
            return 0
        fi
    fi

    journal_init_apply_tx
    ensure_manifest_startup_defaults

    log_info "Applying selected zones: ${SELECTED_ZONES_CSV}"
    apply_flow_with_startup_tracking
    apply_compose_ensure_stacks_up
    log_success "Apply phase finished for zones: ${SELECTED_ZONES_CSV}"
}

run_rollback_mode() {
    local resolved_tx_id="$1"
    require_root

    log_info "Resolved transaction state root: $(resolve_state_root)"
    log_info "Rolling back tx-id: ${resolved_tx_id}"

    rollback_tx "$resolved_tx_id"
}

main() {
    parse_args "$@"
    prepare_apply_and_verify_modes
    print_banner

    case "$CLI_MODE" in
        apply)
            run_apply_mode
            ;;
        rollback)
            run_rollback_mode "$ROLLBACK_TX_ID"
            ;;
        rollback-last)
            local last_tx_id=""
            local last_tx_rc=0
            if ! last_tx_id="$(find_last_tx_id)"; then
                last_tx_rc=$?
                if [ "$last_tx_rc" -eq 2 ]; then
                    log_error "No prior transaction found under $(transactions_root) (transactions directory missing)"
                else
                    log_error "No prior transaction found under $(transactions_root)"
                fi
                exit 1
            fi
            log_info "Resolved latest tx-id: ${last_tx_id}"
            run_rollback_mode "$last_tx_id"
            ;;
        rollback-all)
            require_root
            log_info "Resolved transaction state root: $(resolve_state_root)"
            rollback_all_txs
            ;;
        verify-reboot)
            run_verify_reboot_mode_from_cli "$VERIFY_TX_ID"
            ;;
        verify-reboot-last)
            run_verify_reboot_last_mode_from_cli
            ;;
        *)
            log_error "Unexpected mode dispatch: $CLI_MODE"
            exit 2
            ;;
    esac

    if [ "$DEBUG_MODE" -eq 1 ]; then
        print_debug_section
    fi
}

main "$@"
