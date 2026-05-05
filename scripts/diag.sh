#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# RemnaWave Adaptive Diagnostics v3.1 (read-only)
# Debian/Ubuntu-scoped runtime diagnostics for remnanode container.
#===============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

RW_DIAG_TEST_MODE="${RW_DIAG_TEST_MODE:-0}"
RW_DIAG_TEST_DOCKER_MISSING="${RW_DIAG_TEST_DOCKER_MISSING:-0}"

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

unknown_with_reason() {
  local reason="${1:-not available}"
  printf 'unknown (%s)' "$reason"
}

read_os_release() {
  local os_file="/etc/os-release"
  OS_ID="unknown"
  OS_ID_LIKE=""
  OS_PRETTY="unknown"

  if [ "$RW_DIAG_TEST_MODE" = "1" ]; then
    OS_ID="ubuntu"
    OS_ID_LIKE="debian"
    OS_PRETTY="Ubuntu (test mode)"
    return
  fi

  if [ -r "$os_file" ]; then
    # shellcheck disable=SC1090
    . "$os_file"
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
    OS_PRETTY="${PRETTY_NAME:-${NAME:-unknown}}"
  fi
}

is_supported_os() {
  case "${OS_ID,,}" in
    debian|ubuntu) return 0 ;;
  esac

  case " ${OS_ID_LIKE,,} " in
    *" debian "*|*" ubuntu "*) return 0 ;;
  esac

  return 1
}

get_host_baseline() {
  if [ "$RW_DIAG_TEST_MODE" = "1" ]; then
    CPU_CORES=4
    CPU_MODEL="Test CPU"
    MEM_TOTAL_KB=4194304
    MEM_AVAIL_KB=3145728
    VIRT_TYPE="test"
  else
    CPU_CORES=$(nproc 2>/dev/null || echo 0)
    CPU_MODEL=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | sed 's/^ //' || echo "Unknown")
    MEM_TOTAL_KB=$(awk '/MemTotal/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    MEM_AVAIL_KB=$(awk '/MemAvailable/ {print $2; exit}' /proc/meminfo 2>/dev/null || echo 0)
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "unknown")
  fi

  is_uint "$CPU_CORES" || CPU_CORES=0
  is_uint "$MEM_TOTAL_KB" || MEM_TOTAL_KB=0
  is_uint "$MEM_AVAIL_KB" || MEM_AVAIL_KB=0

  MEM_TOTAL_MB=$((MEM_TOTAL_KB / 1024))
  MEM_AVAIL_MB=$((MEM_AVAIL_KB / 1024))
}

# Runtime-scoped values
DOCKER_AVAILABLE=0
CONTAINER_FOUND=0
CONTAINER_NAME="remnanode"
CONTAINER_STATUS=""
CONTAINER_IMAGE=""
CONTAINER_STARTED_AT=""
CONTAINER_PID=""
CONTAINER_MEM_LIMIT_BYTES=""
CONTAINER_MEM_USAGE_BYTES=""
CONTAINER_CPU_QUOTA=""
CONTAINER_CPU_PERIOD=""
CONTAINER_CPU_NANO=""
CONTAINER_NOFILE_SOFT=""
CONTAINER_NOFILE_HARD=""
DOCKER_SERVER_VERSION=""
DOCKER_REASON=""

RUNTIME_THREADS=""
RUNTIME_OPEN_FDS=""
RUNTIME_TCP_TOTAL=""
RUNTIME_ESTABLISHED=""
RUNTIME_TIME_WAIT=""
RUNTIME_SYN_RECV=""
RUNTIME_CLOSE_WAIT=""
RUNTIME_LISTEN=""
RUNTIME_TCP_SOURCE=""
RUNTIME_REASON=""
RUNTIME_PORT_RANGE_LOW=""
RUNTIME_PORT_RANGE_HIGH=""
WORKER_PID=""
WORKER_CMDLINE=""
COMPOSE_FILE_PATH=""

COMPOSE_SEARCH_PATHS=(
  "/opt/remnawave/docker-compose.yml"
  "/opt/remnanode/docker-compose.yml"
  "/vless/docker-compose.yml"
  "/vless/remnanode/docker-compose.yml"
)

find_compose_file() {
  local candidate
  for candidate in "${COMPOSE_SEARCH_PATHS[@]}"; do
    if [ -f "$candidate" ] && [ -s "$candidate" ]; then
      COMPOSE_FILE_PATH="$candidate"
      return 0
    fi
  done
  return 1
}

find_worker_pid() {
  local dir pid comm cmdline

  for dir in /proc/[0-9]*; do
    [ -r "$dir/comm" ] || continue
    comm="$(cat "$dir/comm" 2>/dev/null || true)"
    if [ "$comm" = "rw-core" ]; then
      pid="${dir##*/}"
      WORKER_CMDLINE="$(tr '\0' ' ' < "$dir/cmdline" 2>/dev/null || true)"
      printf '%s\n' "$pid"
      return 0
    fi
  done

  for dir in /proc/[0-9]*; do
    [ -r "$dir/cmdline" ] || continue
    cmdline="$(tr '\0' ' ' < "$dir/cmdline" 2>/dev/null || true)"
    case " $cmdline " in
      *" rw-core "*|*" /usr/local/bin/rw-core "*|*"/usr/local/bin/rw-core "*)
        pid="${dir##*/}"
        WORKER_CMDLINE="$cmdline"
        printf '%s\n' "$pid"
        return 0
        ;;
    esac
  done

  return 1
}

count_tcp_namespace_states() {
  local pid="$1"
  local tcp_files=()
  local tcp_file="/proc/$pid/net/tcp"
  local tcp6_file="/proc/$pid/net/tcp6"

  [ -r "$tcp_file" ] && tcp_files+=("$tcp_file")
  [ -r "$tcp6_file" ] && tcp_files+=("$tcp6_file")

  if [ "${#tcp_files[@]}" -eq 0 ]; then
    printf 'n/a\tn/a\tn/a\tn/a\tn/a\tn/a\n'
    return 0
  fi

  awk '
    FNR > 1 {
      total++
      state[$4]++
    }
    END {
      printf "%d\t%d\t%d\t%d\t%d\t%d\n",
        total + 0,
        state["01"] + 0,
        state["03"] + 0,
        state["06"] + 0,
        state["08"] + 0,
        state["0A"] + 0
    }
  ' "${tcp_files[@]}"
}

collect_runtime() {
  if [ "$RW_DIAG_TEST_DOCKER_MISSING" = "1" ]; then
    DOCKER_REASON="test flag RW_DIAG_TEST_DOCKER_MISSING=1"
    return
  fi

  if ! command -v docker >/dev/null 2>&1; then
    DOCKER_REASON="docker CLI not installed"
    return
  fi

  if ! docker info >/dev/null 2>&1; then
    DOCKER_REASON="docker daemon not accessible (permission denied?)"
    return
  fi

  DOCKER_AVAILABLE=1
  DOCKER_SERVER_VERSION=$(docker version --format '{{.Server.Version}}' 2>/dev/null || true)

  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq "$CONTAINER_NAME"; then
    DOCKER_REASON="container '$CONTAINER_NAME' is not running"
    return
  fi

  CONTAINER_FOUND=1

  find_compose_file || true

  CONTAINER_STATUS=$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)
  CONTAINER_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$CONTAINER_NAME" 2>/dev/null || true)
  CONTAINER_STARTED_AT=$(docker inspect -f '{{.State.StartedAt}}' "$CONTAINER_NAME" 2>/dev/null || true)
  CONTAINER_PID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER_NAME" 2>/dev/null || true)

  CONTAINER_MEM_LIMIT_BYTES=$(docker inspect -f '{{.HostConfig.Memory}}' "$CONTAINER_NAME" 2>/dev/null || true)
  # Capture actual memory usage in bytes from cgroup
  if is_uint "$CONTAINER_PID" && [ "$CONTAINER_PID" -gt 0 ]; then
    local cgroup_mem_file="/sys/fs/cgroup/memory/docker/$(docker inspect -f '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null)/memory.usage_in_bytes"
    if [ -r "$cgroup_mem_file" ]; then
      CONTAINER_MEM_USAGE_BYTES=$(cat "$cgroup_mem_file" 2>/dev/null || true)
    fi
    # cgroup v2 fallback
    if ! is_uint "$CONTAINER_MEM_USAGE_BYTES" || [ "$CONTAINER_MEM_USAGE_BYTES" -le 0 ]; then
      local cgroup_v2_file="/sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' "$CONTAINER_NAME" 2>/dev/null).scope/memory.current"
      if [ -r "$cgroup_v2_file" ]; then
        CONTAINER_MEM_USAGE_BYTES=$(cat "$cgroup_v2_file" 2>/dev/null || true)
      fi
    fi
    # docker stats fallback
    if ! is_uint "$CONTAINER_MEM_USAGE_BYTES" || [ "$CONTAINER_MEM_USAGE_BYTES" -le 0 ]; then
      local stats_mem
      stats_mem="$(docker stats --no-stream --format '{{.MemUsage}}' "$CONTAINER_NAME" 2>/dev/null | awk -F'/' '{gsub(/[[:space:]]/, "", $1); print $1}')"
      if [ -n "$stats_mem" ]; then
        # Parse values like "2.127GiB" or "512MiB"
        local mem_val mem_unit
        mem_val="$(printf '%s' "$stats_mem" | sed 's/[A-Za-z]*$//')"
        mem_unit="$(printf '%s' "$stats_mem" | sed 's/[0-9.]*//')"
        case "$mem_unit" in
          GiB) CONTAINER_MEM_USAGE_BYTES="$(awk -v v="$mem_val" 'BEGIN { printf "%d", v * 1073741824 }')" ;;
          MiB) CONTAINER_MEM_USAGE_BYTES="$(awk -v v="$mem_val" 'BEGIN { printf "%d", v * 1048576 }')" ;;
          KiB) CONTAINER_MEM_USAGE_BYTES="$(awk -v v="$mem_val" 'BEGIN { printf "%d", v * 1024 }')" ;;
        esac
      fi
    fi
  fi
  CONTAINER_CPU_QUOTA=$(docker inspect -f '{{.HostConfig.CpuQuota}}' "$CONTAINER_NAME" 2>/dev/null || true)
  CONTAINER_CPU_PERIOD=$(docker inspect -f '{{.HostConfig.CpuPeriod}}' "$CONTAINER_NAME" 2>/dev/null || true)
  CONTAINER_CPU_NANO=$(docker inspect -f '{{.HostConfig.NanoCpus}}' "$CONTAINER_NAME" 2>/dev/null || true)

  local ulimits
  ulimits=$(docker inspect -f '{{range .HostConfig.Ulimits}}{{if eq .Name "nofile"}}{{.Soft}} {{.Hard}}{{end}}{{end}}' "$CONTAINER_NAME" 2>/dev/null || true)
  if [ -n "$ulimits" ]; then
    CONTAINER_NOFILE_SOFT=$(echo "$ulimits" | awk '{print $1}')
    CONTAINER_NOFILE_HARD=$(echo "$ulimits" | awk '{print $2}')
  fi

  # Resolve the actual worker process instead of the container entrypoint.
  WORKER_PID="$(find_worker_pid 2>/dev/null || true)"
  if is_uint "$WORKER_PID" && [ "$WORKER_PID" -gt 0 ] && [ -d "/proc/$WORKER_PID" ]; then
    RUNTIME_THREADS=$(awk '/^Threads/ {print $2; exit}' "/proc/$WORKER_PID/status" 2>/dev/null || true)
    RUNTIME_OPEN_FDS=$(ls "/proc/$WORKER_PID/fd" 2>/dev/null | wc -l | tr -d ' ' || true)

    local tcp_state_stats
    tcp_state_stats="$(count_tcp_namespace_states "$WORKER_PID")"
    if [ -n "$tcp_state_stats" ]; then
      IFS=$'\t' read -r RUNTIME_TCP_TOTAL RUNTIME_ESTABLISHED RUNTIME_SYN_RECV RUNTIME_TIME_WAIT RUNTIME_CLOSE_WAIT RUNTIME_LISTEN <<< "$tcp_state_stats"
      RUNTIME_TCP_SOURCE="host procfs /proc/$WORKER_PID/net/tcp*"
    fi

    if [ -r "/proc/$WORKER_PID/root/proc/sys/net/ipv4/ip_local_port_range" ]; then
      local pr
      pr=$(cat "/proc/$WORKER_PID/root/proc/sys/net/ipv4/ip_local_port_range" 2>/dev/null || true)
      if [ -n "$pr" ]; then
        RUNTIME_PORT_RANGE_LOW=$(echo "$pr" | awk '{print $1}')
        RUNTIME_PORT_RANGE_HIGH=$(echo "$pr" | awk '{print $2}')
      fi
    fi
  else
    RUNTIME_REASON="rw-core worker process not found on host"
  fi
}

print_banner() {
  echo
  echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║     RemnaWave Runtime Diagnostics v3.1 (Read-Only)  ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
  echo -e "  Host: $(hostname)  |  $(date)"

  if [ "$RW_DIAG_TEST_MODE" = "1" ]; then
    echo -e "  Mode: ${YELLOW}RW_DIAG_TEST_MODE=1 (deterministic self-test)${NC}"
  fi

  if is_supported_os; then
    echo -e "  OS Scope: ${GREEN}Supported${NC} (${OS_PRETTY})"
  else
    echo -e "  OS Scope: ${YELLOW}Degraded${NC} (${OS_PRETTY}; expected Debian/Ubuntu)"
  fi

  echo
}

print_resources() {
  echo -e "${BOLD}${CYAN}━━━ HOST BASELINE (informational only) ━━━${NC}"
  echo "  CPU:      ${CPU_CORES:-0} cores (${CPU_MODEL:-Unknown})"
  if is_uint "$MEM_TOTAL_MB" && [ "$MEM_TOTAL_MB" -gt 0 ] && is_uint "$MEM_AVAIL_MB" && [ "$MEM_AVAIL_MB" -gt 0 ]; then
    local ram_gb
    ram_gb="$(awk -v m="$MEM_TOTAL_MB" 'BEGIN { printf "%.1f", m / 1024 }')"
    echo "  RAM:      ${ram_gb} GB total, ${MEM_AVAIL_MB} MB available"
  else
    echo "  RAM:      $(unknown_with_reason "cannot read /proc/meminfo reliably")"
  fi
  echo "  Virtual:  ${VIRT_TYPE:-unknown}"
  echo
}

print_container_section() {
  echo -e "${BOLD}${CYAN}━━━ CONTAINER RUNTIME SCOPE ━━━${NC}"

  if [ "$CONTAINER_FOUND" -ne 1 ]; then
    echo -e "  ${YELLOW}Container 'remnanode' not found or Docker not available${NC}"
    echo "  Runtime scope: $(unknown_with_reason "${DOCKER_REASON:-docker runtime unavailable}")"
    echo
    return
  fi

  echo -e "  Status:   ${GREEN}${CONTAINER_STATUS:-unknown}${NC}"
  if [ -n "$DOCKER_SERVER_VERSION" ]; then
    echo "  Docker:   ${DOCKER_SERVER_VERSION}"
  else
    echo "  Docker:   $(unknown_with_reason "docker server version unavailable")"
  fi
  echo "  Image:    ${CONTAINER_IMAGE:-$(unknown_with_reason "docker inspect image unavailable")}" 

  if [ -n "$COMPOSE_FILE_PATH" ]; then
    echo "  Compose:  ${COMPOSE_FILE_PATH}"
  else
    echo "  Compose:  $(unknown_with_reason "not found in known paths")"
  fi

  if [ -n "$CONTAINER_STARTED_AT" ] && [ "$CONTAINER_STARTED_AT" != "<no value>" ]; then
    echo "  Started:  $CONTAINER_STARTED_AT"
  else
    echo "  Started:  $(unknown_with_reason "docker inspect startedAt unavailable")"
  fi

  if is_uint "$CONTAINER_PID" && [ "$CONTAINER_PID" -gt 0 ]; then
    echo "  PID:      $CONTAINER_PID"
  else
    echo "  PID:      $(unknown_with_reason "docker inspect pid unavailable")"
  fi

  docker stats --no-stream --format "  Usage:    CPU {{.CPUPerc}}  |  RAM {{.MemUsage}} ({{.MemPerc}})" "$CONTAINER_NAME" 2>/dev/null \
    || echo "  Usage:    $(unknown_with_reason "docker stats unavailable")"

  if is_uint "$CONTAINER_MEM_LIMIT_BYTES" && [ "$CONTAINER_MEM_LIMIT_BYTES" -gt 0 ]; then
    echo "  Mem limit: $((CONTAINER_MEM_LIMIT_BYTES / 1024 / 1024)) MB"
  else
    echo "  Mem limit: $(unknown_with_reason "docker memory limit not set")"
  fi

  if is_uint "$CONTAINER_CPU_NANO" && [ "$CONTAINER_CPU_NANO" -gt 0 ]; then
    printf '  CPU limit: %.2f cores\n' "$(awk "BEGIN {print $CONTAINER_CPU_NANO/1000000000}")"
  elif is_uint "$CONTAINER_CPU_QUOTA" && [ "$CONTAINER_CPU_QUOTA" -gt 0 ] && is_uint "$CONTAINER_CPU_PERIOD" && [ "$CONTAINER_CPU_PERIOD" -gt 0 ]; then
    printf '  CPU limit: %.2f cores\n' "$(awk "BEGIN {print $CONTAINER_CPU_QUOTA/$CONTAINER_CPU_PERIOD}")"
  else
    echo "  CPU limit: $(unknown_with_reason "docker cpu limit not set")"
  fi

  if is_uint "$CONTAINER_NOFILE_SOFT" && [ "$CONTAINER_NOFILE_SOFT" -gt 0 ]; then
    echo "  nofile:    soft=${CONTAINER_NOFILE_SOFT} hard=${CONTAINER_NOFILE_HARD:-unknown}"
  else
    echo "  nofile:    $(unknown_with_reason "container nofile ulimit not set in HostConfig.Ulimits")"
  fi

  echo
}

print_runtime_stats() {
  echo -e "${BOLD}${CYAN}━━━ RUNTIME PROCESS / NETWORK METRICS ━━━${NC}"

  if [ "$CONTAINER_FOUND" -ne 1 ]; then
    echo "  Worker:          $(unknown_with_reason "container runtime unavailable")"
    echo "  Process threads: $(unknown_with_reason "container runtime unavailable")"
    echo "  Open FDs:        $(unknown_with_reason "container runtime unavailable")"
    echo "  TCP source:      $(unknown_with_reason "container runtime unavailable")"
    echo "  TCP entries:     $(unknown_with_reason "container runtime unavailable")"
    echo "  Established:     $(unknown_with_reason "container runtime unavailable")"
    echo "  Time-Wait:       $(unknown_with_reason "container runtime unavailable")"
    echo "  Syn-Recv:        $(unknown_with_reason "container runtime unavailable")"
    echo "  Close-Wait:      $(unknown_with_reason "container runtime unavailable")"
    echo "  Listen:          $(unknown_with_reason "container runtime unavailable")"
    echo
    return
  fi

  if is_uint "$WORKER_PID" && [ "$WORKER_PID" -gt 0 ]; then
    echo "  Worker:          rw-core (pid $WORKER_PID)"
    if [ -n "$WORKER_CMDLINE" ]; then
      echo "  Worker cmd:      $WORKER_CMDLINE"
    fi
  else
    echo "  Worker:          $(unknown_with_reason "rw-core worker process not found")"
  fi

  if is_uint "$RUNTIME_THREADS"; then
    echo "  Process threads: $RUNTIME_THREADS"
  else
    echo "  Process threads: $(unknown_with_reason "${RUNTIME_REASON:-cannot read /proc/<worker_pid>/status}")"
  fi

  if is_uint "$RUNTIME_OPEN_FDS"; then
    echo "  Open FDs:        $RUNTIME_OPEN_FDS"
  else
    echo "  Open FDs:        $(unknown_with_reason "${RUNTIME_REASON:-cannot read /proc/<worker_pid>/fd}")"
  fi

  if [ -n "$RUNTIME_TCP_SOURCE" ]; then
    echo "  TCP source:      $RUNTIME_TCP_SOURCE"
  else
    echo "  TCP source:      $(unknown_with_reason "${RUNTIME_REASON:-cannot resolve worker tcp source}")"
  fi

  if is_uint "$RUNTIME_TCP_TOTAL"; then
    echo "  TCP entries:     $RUNTIME_TCP_TOTAL"
  else
    echo "  TCP entries:     $(unknown_with_reason "${RUNTIME_REASON:-cannot read /proc/<worker_pid>/net/tcp + tcp6}")"
  fi

  if is_uint "$RUNTIME_ESTABLISHED"; then
    echo "  Established:     $RUNTIME_ESTABLISHED"
  else
    echo "  Established:     $(unknown_with_reason "${RUNTIME_REASON:-cannot read /proc/<worker_pid>/net/tcp}")"
  fi

  if is_uint "$RUNTIME_TIME_WAIT"; then
    echo "  Time-Wait:       $RUNTIME_TIME_WAIT"
  else
    echo "  Time-Wait:       $(unknown_with_reason "${RUNTIME_REASON:-cannot read /proc/<worker_pid>/net/tcp}")"
  fi

  if is_uint "$RUNTIME_SYN_RECV"; then
    echo "  Syn-Recv:        $RUNTIME_SYN_RECV"
  else
    echo "  Syn-Recv:        $(unknown_with_reason "${RUNTIME_REASON:-cannot read /proc/<worker_pid>/net/tcp}")"
  fi

  if is_uint "$RUNTIME_CLOSE_WAIT"; then
    echo "  Close-Wait:      $RUNTIME_CLOSE_WAIT"
  else
    echo "  Close-Wait:      $(unknown_with_reason "${RUNTIME_REASON:-cannot read /proc/<worker_pid>/net/tcp}")"
  fi

  if is_uint "$RUNTIME_LISTEN"; then
    echo "  Listen:          $RUNTIME_LISTEN"
  else
    echo "  Listen:          $(unknown_with_reason "${RUNTIME_REASON:-cannot read /proc/<worker_pid>/net/tcp}")"
  fi
  echo
}

print_capacity() {
  echo -e "${BOLD}${CYAN}━━━ CAPACITY ESTIMATE (runtime-scoped only) ━━━${NC}"

  local degrade_reasons=()
  local mem_limit_connections=""
  local fd_limit_connections=""
  local port_limit_connections=""
  local mem_method=""

  # Memory-limited capacity from actual runtime data.
  # Use container_usage / tcp_total — includes TCP buffers, kernel structs, slab, conntrack.
  # sockstat TCP mem only covers sk_rmem/sk_wmem (buffer data), not full per-conn cost.
  if is_uint "$CONTAINER_MEM_USAGE_BYTES" && [ "$CONTAINER_MEM_USAGE_BYTES" -gt 0 ] \
     && is_uint "$RUNTIME_TCP_TOTAL" && [ "$RUNTIME_TCP_TOTAL" -gt 0 ] \
     && is_uint "$CONTAINER_MEM_LIMIT_BYTES" && [ "$CONTAINER_MEM_LIMIT_BYTES" -gt 0 ]; then

    local bytes_per_conn
    bytes_per_conn=$((CONTAINER_MEM_USAGE_BYTES / RUNTIME_TCP_TOTAL))

    if [ "$bytes_per_conn" -gt 0 ]; then
      mem_limit_connections=$(awk -v lim="$CONTAINER_MEM_LIMIT_BYTES" -v bpc="$bytes_per_conn" \
        'BEGIN { printf "%d", (lim * 0.85) / bpc }')
      local usage_mb=$((CONTAINER_MEM_USAGE_BYTES / 1048576))
      mem_method="container (${usage_mb}MB / ${RUNTIME_TCP_TOTAL} entries = ${bytes_per_conn} bytes/conn, 85% of limit)"
    fi
  fi

  # Fallback: theoretical estimate
  if [ -z "$mem_limit_connections" ]; then
    if ! is_uint "$CONTAINER_MEM_LIMIT_BYTES" || [ "$CONTAINER_MEM_LIMIT_BYTES" -le 0 ]; then
      degrade_reasons+=("container memory limit unknown")
    else
      mem_limit_connections=$((CONTAINER_MEM_LIMIT_BYTES / 102400))
      mem_method="theoretical (~100KB/conn estimate)"
    fi
  fi

  if ! is_uint "$CONTAINER_NOFILE_SOFT" || [ "$CONTAINER_NOFILE_SOFT" -le 0 ]; then
    degrade_reasons+=("container nofile soft limit unknown")
  else
    fd_limit_connections=$((CONTAINER_NOFILE_SOFT / 2))
  fi

  if ! is_uint "$RUNTIME_PORT_RANGE_LOW" || ! is_uint "$RUNTIME_PORT_RANGE_HIGH" || [ "$RUNTIME_PORT_RANGE_HIGH" -le "$RUNTIME_PORT_RANGE_LOW" ]; then
    degrade_reasons+=("container runtime port range unknown")
  else
    port_limit_connections=$((RUNTIME_PORT_RANGE_HIGH - RUNTIME_PORT_RANGE_LOW))
  fi

  if [ "${#degrade_reasons[@]}" -gt 0 ] && [ -z "$mem_limit_connections" ]; then
    echo "  Estimated concurrent connections: $(unknown_with_reason "missing runtime-scoped inputs")"
    echo "  Degraded capacity reason(s):"
    local r
    for r in "${degrade_reasons[@]}"; do
      echo "    - $r"
    done
    echo
    return
  fi

  local capacity="$mem_limit_connections"
  if is_uint "$fd_limit_connections" && [ "$fd_limit_connections" -lt "$capacity" ]; then
    capacity="$fd_limit_connections"
  fi
  if is_uint "$port_limit_connections" && [ "$port_limit_connections" -lt "$capacity" ]; then
    capacity="$port_limit_connections"
  fi

  echo "  Inputs:"
  echo "    Memory-limited: ${mem_limit_connections} connections (${mem_method})"
  if is_uint "$fd_limit_connections"; then
    echo "    FD-limited:     ${fd_limit_connections} connections (2 FDs per proxied conn)"
  fi
  if is_uint "$port_limit_connections"; then
    echo "    Port-limited:   ${port_limit_connections} connections"
  fi
  echo
  echo -e "  ${BOLD}Estimated concurrent connections: ${GREEN}~${capacity}${NC}"
  echo
}

print_summary() {
  echo -e "${BOLD}${CYAN}━━━ SUMMARY ━━━${NC}"

  if ! is_supported_os; then
    echo -e "  ${YELLOW}Degraded mode:${NC} OS is outside Debian/Ubuntu support boundary."
  fi

  if [ "$CONTAINER_FOUND" -ne 1 ]; then
    echo -e "  ${YELLOW}Degraded mode:${NC} remnanode runtime scope unavailable (${DOCKER_REASON:-unknown reason})."
  else
    echo -e "  ${GREEN}Runtime scope active:${NC} container-scoped diagnostics collected where possible."
    echo "  Host-global stand-ins were intentionally avoided for runtime metrics."
  fi

  echo
  echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
}

read_os_release
get_host_baseline
collect_runtime

print_banner
print_resources
print_container_section
print_runtime_stats
print_capacity
print_summary
