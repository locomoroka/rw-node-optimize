#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/snapshot.sh before "<label>"
  bash scripts/snapshot.sh after "<label>"
  bash scripts/snapshot.sh result
  bash scripts/snapshot.sh --help

Commands:
  before "<label>"   Capture a pre-change snapshot and keep only the latest 4 before snapshots.
  after  "<label>"   Capture a post-change snapshot and keep only the latest 4 after snapshots.
  result              Print a wide snapshot table plus pairwise before→after comparisons.

Environment:
  RW_BA_STATE_DIR         Snapshot root directory. Default: artifacts/before-after
  RW_BA_SAMPLE_SECONDS    Sampling window for delta metrics. Default: 120

Examples:
  bash scripts/snapshot.sh before "baseline before sysctl"
  bash scripts/snapshot.sh after "30 min after apply"
  bash scripts/snapshot.sh result

What V2 captures:
  - host load and memory
  - CPU busy/user/system/iowait/softirq/irq/steal over a sample window
  - primary-interface throughput (Mbps), PPS, drops, errors over the same window
  - TCP state counts (ss)
  - selected nstat deltas: retransmits, listen overflows/drops, backlog drops, SYN retransmits, TCP timeouts, IP discards
  - conntrack count/max/usage
  - container/runtime data: docker CPU/memory, container PID, proxy threads, open FDs, RSS, context switches
  - key sysctl values changed by the optimizer

Notes:
  - Labels should be quoted when they contain spaces.
  - Snapshots are stored under artifacts/before-after/ by default.
  - Compare snapshots taken under similar traffic conditions.
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

STATE_ROOT="${RW_BA_STATE_DIR:-artifacts/before-after}"
BEFORE_DIR="$STATE_ROOT/before"
AFTER_DIR="$STATE_ROOT/after"
SAMPLE_SECONDS="${RW_BA_SAMPLE_SECONDS:-120}"

mkdir -p "$BEFORE_DIR" "$AFTER_DIR"

# ANSI color codes for terminal output
C_GREEN='\033[0;32m'
C_RED='\033[0;31m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'
C_BOLD='\033[1m'
C_DIM='\033[2m'
C_NC='\033[0m'

safe_filename_component() {
  local raw="${1:-snapshot}"
  raw="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  raw="$(printf '%s' "$raw" | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')"
  [ -n "$raw" ] || raw="snapshot"
  printf '%s' "$raw"
}

write_kv() {
  local key="$1"
  local value="${2-}"
  printf '%s=%q\n' "$key" "$value"
}

is_number() {
  [[ "${1:-}" =~ ^-?[0-9]+([.][0-9]+)?$ ]]
}

first_line() {
  awk 'NF { print; exit }'
}

calc_delta() {
  local before="$1"
  local after="$2"
  # Adaptive precision: use enough decimals to show meaningful difference
  awk -v b="$before" -v a="$after" 'BEGIN {
    d = a - b
    if (d < 0) ad = -d; else ad = d
    if (ad == 0)          fmt = "%+.2f"
    else if (ad < 0.001)  fmt = "%+.6f"
    else if (ad < 0.01)   fmt = "%+.5f"
    else if (ad < 0.1)    fmt = "%+.4f"
    else if (ad < 1)      fmt = "%+.3f"
    else                  fmt = "%+.2f"
    printf fmt, d
  }'
}

compare_note() {
  local before="$1"
  local after="$2"
  local direction="$3"
  local tolerance="${4:-0}"
  awk -v b="$before" -v a="$after" -v d="$direction" -v tol="$tolerance" '
    BEGIN {
      diff=a-b
      eps=0.000001
      if (diff < 0) diff_abs = -diff; else diff_abs = diff
      if (diff_abs < eps) { print "flat"; exit }
      # If tolerance is set, check percentage change against threshold
      if (tol > 0 && b != 0) {
        pct_change = diff_abs / (b < 0 ? -b : b) * 100
        if (pct_change <= tol) { print "flat"; exit }
      }
      if (d == "lower") print (a < b ? "better" : "worse")
      else if (d == "higher") print (a > b ? "better" : "worse")
      else print "n/a"
    }
  '
}

emoji_for_verdict() {
  case "$1" in
    better) printf '🟢' ;;
    worse) printf '🔴' ;;
    flat) printf '🟡' ;;
    n/a) printf '⚪' ;;
    *) printf '⚪' ;;
  esac
}

format_verdict_with_emoji() {
  local verdict="$1"
  case "$verdict" in
    better) printf "${C_GREEN}✔ better${C_NC}" ;;
    worse)  printf "${C_RED}✘ worse${C_NC}" ;;
    flat)   printf "${C_YELLOW}— flat${C_NC}" ;;
    n/a)    printf "${C_DIM}· n/a${C_NC}" ;;
    *)      printf "${C_DIM}· n/a${C_NC}" ;;
  esac
}

calc_pct_change() {
  local before="$1"
  local after="$2"
  awk -v b="$before" -v a="$after" 'BEGIN {
    if (b == 0) { print "n/a"; exit }
    printf "%+.1f%%", ((a-b)/b)*100
  }'
}

format_delta_colored() {
  local delta="$1"
  local verdict="$2"
  case "$verdict" in
    better) printf "${C_GREEN}%s${C_NC}" "$delta" ;;
    worse)  printf "${C_RED}%s${C_NC}" "$delta" ;;
    flat)   printf "${C_YELLOW}%s${C_NC}" "$delta" ;;
    *)      printf '%s' "$delta" ;;
  esac
}

calc_ratio() {
  local numerator="$1"
  local denominator="$2"
  awk -v n="$numerator" -v d="$denominator" 'BEGIN { if (d <= 0) { print "n/a"; exit } printf "%.2f", n/d }'
}

read_sysctl_value() {
  local key="$1"
  if command -v sysctl >/dev/null 2>&1; then
    sysctl -n "$key" 2>/dev/null || printf 'n/a'
  else
    printf 'n/a'
  fi
}

select_container_name() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    return 0
  fi

  local name=""
  name="$(docker ps --format '{{.Names}}' 2>/dev/null | awk 'tolower($0) ~ /(remna|xray|remnanode)/ { print; exit }')"
  if [ -z "$name" ]; then
    name="$(docker ps --format '{{.Names}}' 2>/dev/null | head -n 1 || true)"
  fi
  printf '%s' "$name"
}

select_primary_iface() {
  local iface=""
  if command -v ip >/dev/null 2>&1; then
    iface="$(ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }}')"
    if [ -z "$iface" ]; then
      iface="$(ip route show default 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit }}')"
    fi
  fi
  printf '%s' "$iface"
}

capture_loadavg() {
  if [ -r /proc/loadavg ]; then
    awk '{print $1"\t"$2"\t"$3}' /proc/loadavg
  else
    printf 'n/a\tn/a\tn/a\n'
  fi
}

capture_meminfo() {
  if [ -r /proc/meminfo ]; then
    awk '
      /MemTotal:/ { total=int($2/1024) }
      /MemAvailable:/ { available=int($2/1024) }
      /MemFree:/ { if (available == "") available=int($2/1024) }
      END {
        if (total == "") total="n/a"
        if (available == "") available="n/a"
        used="n/a"
        pct="n/a"
        if (total != "n/a" && available != "n/a") {
          used=total-available
          if (total > 0) pct=sprintf("%.1f", (used/total)*100)
        }
        printf "%s\t%s\t%s\t%s\n", total, used, available, pct
      }
    ' /proc/meminfo
  else
    printf 'n/a\tn/a\tn/a\tn/a\n'
  fi
}

capture_ss_counts() {
  if ! command -v ss >/dev/null 2>&1; then
    printf 'n/a\tn/a\tn/a\tn/a\tn/a\tn/a\n'
    return 0
  fi

  local ss_output
  ss_output="$(ss -tanH 2>/dev/null || true)"
  if [ -z "$ss_output" ]; then
    printf '0\t0\t0\t0\t0\t0\n'
    return 0
  fi

  printf '%s\n' "$ss_output" | awk '
    { total++; state[$1]++ }
    END {
      printf "%d\t%d\t%d\t%d\t%d\t%d\n",
        total,
        state["ESTAB"] + 0,
        state["TIME-WAIT"] + 0,
        state["CLOSE-WAIT"] + 0,
        state["SYN-RECV"] + 0,
        state["LISTEN"] + 0
    }
  '
}

capture_conntrack() {
  local count_file="/proc/sys/net/netfilter/nf_conntrack_count"
  local max_file="/proc/sys/net/netfilter/nf_conntrack_max"

  if [ -r "$count_file" ] && [ -r "$max_file" ]; then
    local count max usage_pct usage_label
    count="$(cat "$count_file" 2>/dev/null || echo n/a)"
    max="$(cat "$max_file" 2>/dev/null || echo n/a)"
    usage_pct="n/a"
    usage_label="n/a"
    if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then
      usage_pct="$(awk -v c="$count" -v m="$max" 'BEGIN { printf "%.1f", (c/m)*100 }')"
      usage_label="$(awk -v c="$count" -v m="$max" 'BEGIN { printf "%.1f%% (%s/%s)", (c/m)*100, c, m }')"
    fi
    printf '%s\t%s\t%s\t%s\n' "$count" "$max" "$usage_pct" "$usage_label"
    return 0
  fi

  printf 'n/a\tn/a\tn/a\tn/a\n'
}

capture_docker_and_process_metrics() {
  local container_name="$1"
  if [ -z "$container_name" ]; then
    printf 'n/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\n'
    return 0
  fi

  local stats_line cpu_pct mem_usage mem_pct pid threads open_fds rss_mb vol_ctx nonvol_ctx
  stats_line="$(docker stats --no-stream --format '{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' "$container_name" 2>/dev/null | first_line || true)"
  cpu_pct="n/a"
  mem_usage="n/a"
  mem_pct="n/a"
  if [ -n "$stats_line" ]; then
    cpu_pct="$(printf '%s' "$stats_line" | awk -F '\t' '{ print $1 }' | sed 's/%$//')"
    mem_usage="$(printf '%s' "$stats_line" | awk -F '\t' '{ print $2 }')"
    mem_pct="$(printf '%s' "$stats_line" | awk -F '\t' '{ print $3 }' | sed 's/%$//')"
  fi

  pid="$(docker inspect -f '{{.State.Pid}}' "$container_name" 2>/dev/null || echo n/a)"
  threads="n/a"
  open_fds="n/a"
  rss_mb="n/a"
  vol_ctx="n/a"
  nonvol_ctx="n/a"

  if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && [ -r "/proc/$pid/status" ]; then
    threads="$(awk '/^Threads:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null || echo n/a)"
    rss_mb="$(awk '/^VmRSS:/ { printf "%.1f", $2/1024; exit }' "/proc/$pid/status" 2>/dev/null || echo n/a)"
    vol_ctx="$(awk '/^voluntary_ctxt_switches:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null || echo n/a)"
    nonvol_ctx="$(awk '/^nonvoluntary_ctxt_switches:/ { print $2; exit }' "/proc/$pid/status" 2>/dev/null || echo n/a)"
    open_fds="$(find "/proc/$pid/fd" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | awk '{print $1}')"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$container_name" "$cpu_pct" "$mem_usage" "$mem_pct" "$pid" "$threads" "$open_fds" "$rss_mb" "$vol_ctx/$nonvol_ctx"
}

read_proc_stat_snapshot() {
  if [ ! -r /proc/stat ]; then
    printf 'n/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\n'
    return 0
  fi
  awk '/^cpu / { print $2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7"\t"$8"\t"$9; exit }' /proc/stat
}

read_iface_snapshot() {
  local iface="$1"
  if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface/statistics" ]; then
    printf 'n/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\n'
    return 0
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo n/a)" \
    "$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo n/a)" \
    "$(cat "/sys/class/net/$iface/statistics/rx_packets" 2>/dev/null || echo n/a)" \
    "$(cat "/sys/class/net/$iface/statistics/tx_packets" 2>/dev/null || echo n/a)" \
    "$(cat "/sys/class/net/$iface/statistics/rx_dropped" 2>/dev/null || echo n/a)" \
    "$(cat "/sys/class/net/$iface/statistics/tx_dropped" 2>/dev/null || echo n/a)" \
    "$(cat "/sys/class/net/$iface/statistics/rx_errors" 2>/dev/null || echo n/a)" \
    "$(cat "/sys/class/net/$iface/statistics/tx_errors" 2>/dev/null || echo n/a)"
}

read_nstat_snapshot() {
  if ! command -v nstat >/dev/null 2>&1; then
    printf 'n/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\tn/a\n'
    return 0
  fi
  nstat -az 2>/dev/null | awk '
    /^[A-Za-z]/ {
      name=$1
      val=$2
      gsub(/[^0-9]/, "", val)
      if (val == "") val=0
      v[name]=val
    }
    END {
      printf "%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n",
        v["TcpRetransSegs"] + 0,
        v["TcpExtListenOverflows"] + 0,
        v["TcpExtListenDrops"] + 0,
        v["TcpExtTCPBacklogDrop"] + 0,
        v["TcpExtTCPSynRetrans"] + 0,
        v["TcpExtTCPTimeouts"] + 0,
        v["IpInDiscards"] + 0,
        v["IpOutDiscards"] + 0
    }
  '
}

capture_window_metrics() {
  local sample_seconds="$1"
  local iface="$2"

  local cpu1 cpu2 iface1 iface2 n1 n2
  cpu1="$(read_proc_stat_snapshot)"
  iface1="$(read_iface_snapshot "$iface")"
  n1="$(read_nstat_snapshot)"

  # Instead of a single sleep, sample point-in-time metrics every 20s
  # Samples are written to SNAPSHOT_SAMPLE_FILE (set by caller) as sample_N_key=value
  local sample_interval=20
  local num_samples=$((sample_seconds / sample_interval))
  [ "$num_samples" -lt 1 ] && num_samples=1

  if [ -n "${SNAPSHOT_SAMPLE_FILE:-}" ] && [ -n "${SNAPSHOT_CONTAINER_NAME:-}" ]; then
    printf 'sample_count=%q\n' "$num_samples" >> "$SNAPSHOT_SAMPLE_FILE"
    local si
    for ((si = 1; si <= num_samples; si++)); do
      sleep "$sample_interval"

      # Memory
      local ml; ml="$(capture_meminfo)"
      local sm_t sm_u sm_a sm_p
      IFS=$'\t' read -r sm_t sm_u sm_a sm_p <<< "$ml"
      printf 'sample_%d_mem_used_mb=%q\n' "$si" "$sm_u" >> "$SNAPSHOT_SAMPLE_FILE"
      printf 'sample_%d_mem_available_mb=%q\n' "$si" "$sm_a" >> "$SNAPSHOT_SAMPLE_FILE"

      # TCP states
      local sl; sl="$(capture_ss_counts)"
      local ss1 ss2 ss3 ss4 ss5 ss6
      IFS=$'\t' read -r ss1 ss2 ss3 ss4 ss5 ss6 <<< "$sl"
      printf 'sample_%d_tcp_total=%q\n' "$si" "$ss1" >> "$SNAPSHOT_SAMPLE_FILE"
      printf 'sample_%d_tcp_estab=%q\n' "$si" "$ss2" >> "$SNAPSHOT_SAMPLE_FILE"
      printf 'sample_%d_tcp_time_wait=%q\n' "$si" "$ss3" >> "$SNAPSHOT_SAMPLE_FILE"
      printf 'sample_%d_tcp_close_wait=%q\n' "$si" "$ss4" >> "$SNAPSHOT_SAMPLE_FILE"

      # Conntrack
      local cl; cl="$(capture_conntrack)"
      local cc1 cc2 cc3 cc4
      IFS=$'\t' read -r cc1 cc2 cc3 cc4 <<< "$cl"
      printf 'sample_%d_conntrack_count=%q\n' "$si" "$cc1" >> "$SNAPSHOT_SAMPLE_FILE"

      # TCP mem pages
      local tmp="0"
      if [ -r /proc/net/sockstat ]; then
        tmp="$(awk '/^TCP:/ { for(i=1;i<=NF;i++) if($i=="mem") {print $(i+1); exit} }' /proc/net/sockstat 2>/dev/null || echo 0)"
      fi
      printf 'sample_%d_tcp_mem_pages=%q\n' "$si" "$tmp" >> "$SNAPSHOT_SAMPLE_FILE"

      # Docker stats
      if [ -n "$SNAPSHOT_CONTAINER_NAME" ]; then
        local dl; dl="$(capture_docker_and_process_metrics "$SNAPSHOT_CONTAINER_NAME")"
        local d_c d_cpu d_mu d_mp d_pid d_th d_fd d_rss d_ctx
        IFS=$'\t' read -r d_c d_cpu d_mu d_mp d_pid d_th d_fd d_rss d_ctx <<< "$dl"
        local dcpu_v; dcpu_v="$(printf '%s' "$d_cpu" | sed 's/%$//')"
        printf 'sample_%d_docker_cpu_pct=%q\n' "$si" "$dcpu_v" >> "$SNAPSHOT_SAMPLE_FILE"

        # Parse docker mem used MB
        local dmb="0"
        if [ -n "$d_mu" ] && [ "$d_mu" != "n/a" ]; then
          local raw_u dval dunit
          raw_u="$(printf '%s' "$d_mu" | awk -F'/' '{gsub(/[[:space:]]/, "", $1); print $1}')"
          dval="$(printf '%s' "$raw_u" | sed 's/[A-Za-z]*$//')"
          dunit="$(printf '%s' "$raw_u" | sed 's/[0-9.]*//')"
          case "$dunit" in
            GiB) dmb="$(awk -v v="$dval" 'BEGIN { printf "%.0f", v * 1024 }')" ;;
            MiB) dmb="$(awk -v v="$dval" 'BEGIN { printf "%.0f", v }')" ;;
            KiB) dmb="$(awk -v v="$dval" 'BEGIN { printf "%.0f", v / 1024 }')" ;;
          esac
        fi
        printf 'sample_%d_docker_mem_used_mb=%q\n' "$si" "$dmb" >> "$SNAPSHOT_SAMPLE_FILE"
      fi
    done
  else
    sleep "$sample_seconds"
  fi

  cpu2="$(read_proc_stat_snapshot)"
  iface2="$(read_iface_snapshot "$iface")"
  n2="$(read_nstat_snapshot)"

  local user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1
  local user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2
  IFS=$'\t' read -r user1 nice1 system1 idle1 iowait1 irq1 softirq1 steal1 <<< "$cpu1"
  IFS=$'\t' read -r user2 nice2 system2 idle2 iowait2 irq2 softirq2 steal2 <<< "$cpu2"

  local cpu_busy_pct cpu_user_pct cpu_system_pct cpu_iowait_pct cpu_softirq_pct cpu_irq_pct cpu_steal_pct
  cpu_busy_pct="n/a"; cpu_user_pct="n/a"; cpu_system_pct="n/a"; cpu_iowait_pct="n/a"; cpu_softirq_pct="n/a"; cpu_irq_pct="n/a"; cpu_steal_pct="n/a"
  if is_number "$user1" && is_number "$user2"; then
    local total1 total2 totald busyd userd systemd iowaitd softirqd irqd steald
    total1=$((user1 + nice1 + system1 + idle1 + iowait1 + irq1 + softirq1 + steal1))
    total2=$((user2 + nice2 + system2 + idle2 + iowait2 + irq2 + softirq2 + steal2))
    totald=$((total2 - total1))
    busyd=$(((user2-user1) + (nice2-nice1) + (system2-system1) + (irq2-irq1) + (softirq2-softirq1) + (steal2-steal1)))
    userd=$(((user2-user1) + (nice2-nice1)))
    systemd=$((system2-system1))
    iowaitd=$((iowait2-iowait1))
    softirqd=$((softirq2-softirq1))
    irqd=$((irq2-irq1))
    steald=$((steal2-steal1))
    if [ "$totald" -gt 0 ]; then
      cpu_busy_pct="$(awk -v v="$busyd" -v t="$totald" 'BEGIN { printf "%.1f", (v/t)*100 }')"
      cpu_user_pct="$(awk -v v="$userd" -v t="$totald" 'BEGIN { printf "%.1f", (v/t)*100 }')"
      cpu_system_pct="$(awk -v v="$systemd" -v t="$totald" 'BEGIN { printf "%.1f", (v/t)*100 }')"
      cpu_iowait_pct="$(awk -v v="$iowaitd" -v t="$totald" 'BEGIN { printf "%.1f", (v/t)*100 }')"
      cpu_softirq_pct="$(awk -v v="$softirqd" -v t="$totald" 'BEGIN { printf "%.1f", (v/t)*100 }')"
      cpu_irq_pct="$(awk -v v="$irqd" -v t="$totald" 'BEGIN { printf "%.1f", (v/t)*100 }')"
      cpu_steal_pct="$(awk -v v="$steald" -v t="$totald" 'BEGIN { printf "%.1f", (v/t)*100 }')"
    fi
  fi

  local rx_bytes1 tx_bytes1 rx_packets1 tx_packets1 rx_drop1 tx_drop1 rx_err1 tx_err1
  local rx_bytes2 tx_bytes2 rx_packets2 tx_packets2 rx_drop2 tx_drop2 rx_err2 tx_err2
  IFS=$'\t' read -r rx_bytes1 tx_bytes1 rx_packets1 tx_packets1 rx_drop1 tx_drop1 rx_err1 tx_err1 <<< "$iface1"
  IFS=$'\t' read -r rx_bytes2 tx_bytes2 rx_packets2 tx_packets2 rx_drop2 tx_drop2 rx_err2 tx_err2 <<< "$iface2"

  local rx_mbps tx_mbps rx_pps tx_pps iface_rx_drop_delta iface_tx_drop_delta iface_rx_err_delta iface_tx_err_delta
  rx_mbps="n/a"; tx_mbps="n/a"; rx_pps="n/a"; tx_pps="n/a"; iface_rx_drop_delta="n/a"; iface_tx_drop_delta="n/a"; iface_rx_err_delta="n/a"; iface_tx_err_delta="n/a"
  if is_number "$rx_bytes1" && is_number "$rx_bytes2"; then
    rx_mbps="$(awk -v a="$rx_bytes1" -v b="$rx_bytes2" -v s="$sample_seconds" 'BEGIN { printf "%.2f", ((b-a)*8)/(s*1000000) }')"
    tx_mbps="$(awk -v a="$tx_bytes1" -v b="$tx_bytes2" -v s="$sample_seconds" 'BEGIN { printf "%.2f", ((b-a)*8)/(s*1000000) }')"
    rx_pps="$(awk -v a="$rx_packets1" -v b="$rx_packets2" -v s="$sample_seconds" 'BEGIN { printf "%.1f", (b-a)/s }')"
    tx_pps="$(awk -v a="$tx_packets1" -v b="$tx_packets2" -v s="$sample_seconds" 'BEGIN { printf "%.1f", (b-a)/s }')"
    iface_rx_drop_delta=$((rx_drop2 - rx_drop1))
    iface_tx_drop_delta=$((tx_drop2 - tx_drop1))
    iface_rx_err_delta=$((rx_err2 - rx_err1))
    iface_tx_err_delta=$((tx_err2 - tx_err1))
  fi

  local retrans1 listen_over1 listen_drop1 backlog_drop1 syn_retrans1 tcp_timeouts1 ip_in_discards1 ip_out_discards1
  local retrans2 listen_over2 listen_drop2 backlog_drop2 syn_retrans2 tcp_timeouts2 ip_in_discards2 ip_out_discards2
  IFS=$'\t' read -r retrans1 listen_over1 listen_drop1 backlog_drop1 syn_retrans1 tcp_timeouts1 ip_in_discards1 ip_out_discards1 <<< "$n1"
  IFS=$'\t' read -r retrans2 listen_over2 listen_drop2 backlog_drop2 syn_retrans2 tcp_timeouts2 ip_in_discards2 ip_out_discards2 <<< "$n2"

  local tcp_retrans_delta listen_overflows_delta listen_drops_delta backlog_drops_delta syn_retrans_delta tcp_timeouts_delta ip_in_discards_delta ip_out_discards_delta
  tcp_retrans_delta="n/a"; listen_overflows_delta="n/a"; listen_drops_delta="n/a"; backlog_drops_delta="n/a"; syn_retrans_delta="n/a"; tcp_timeouts_delta="n/a"; ip_in_discards_delta="n/a"; ip_out_discards_delta="n/a"
  if is_number "$retrans1" && is_number "$retrans2"; then
    tcp_retrans_delta=$((retrans2 - retrans1))
    listen_overflows_delta=$((listen_over2 - listen_over1))
    listen_drops_delta=$((listen_drop2 - listen_drop1))
    backlog_drops_delta=$((backlog_drop2 - backlog_drop1))
    syn_retrans_delta=$((syn_retrans2 - syn_retrans1))
    tcp_timeouts_delta=$((tcp_timeouts2 - tcp_timeouts1))
    ip_in_discards_delta=$((ip_in_discards2 - ip_in_discards1))
    ip_out_discards_delta=$((ip_out_discards2 - ip_out_discards1))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$cpu_busy_pct" "$cpu_user_pct" "$cpu_system_pct" "$cpu_iowait_pct" "$cpu_softirq_pct" "$cpu_irq_pct" "$cpu_steal_pct" \
    "$rx_mbps" "$tx_mbps" "$rx_pps" "$tx_pps" "$iface_rx_drop_delta" "$iface_tx_drop_delta" "$iface_rx_err_delta" "$iface_tx_err_delta" \
    "$tcp_retrans_delta" "$listen_overflows_delta" "$listen_drops_delta" "$backlog_drops_delta" "$syn_retrans_delta" "$tcp_timeouts_delta" "$ip_in_discards_delta" "$ip_out_discards_delta"
}

snapshot_dir_for_kind() {
  case "$1" in
    before) printf '%s' "$BEFORE_DIR" ;;
    after) printf '%s' "$AFTER_DIR" ;;
    *)
      echo "[FAIL] Unknown snapshot kind: $1" >&2
      exit 2
      ;;
  esac
}

prune_snapshot_dir() {
  local dir="$1"
  mapfile -t files < <(find "$dir" -maxdepth 1 -type f -name '*.env' | sort)
  local count="${#files[@]}"
  if [ "$count" -le 4 ]; then
    return 0
  fi
  local remove_count=$((count - 4))
  local i
  for ((i = 0; i < remove_count; i++)); do
    rm -f -- "${files[$i]}"
  done
}

capture_snapshot() {
  local kind="$1"
  local label="$2"
  local dir snapshot_ts file_ts safe_label file_path

  dir="$(snapshot_dir_for_kind "$kind")"
  snapshot_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  file_ts="$(date -u +%Y%m%dT%H%M%SZ)"
  safe_label="$(safe_filename_component "$label")"
  file_path="$dir/${file_ts}__${safe_label}.env"

  local host_name cpu_cores iface_name container_name window_line
  host_name="$(hostname 2>/dev/null || echo unknown)"
  cpu_cores="$(nproc 2>/dev/null || echo n/a)"
  iface_name="$(select_primary_iface)"
  container_name="$(select_container_name)"

  # Pre-capture single-shot metrics (before window — used as fallback if no samples)
  local load_line mem_line ss_line conntrack_line docker_line
  load_line="$(capture_loadavg)"
  mem_line="$(capture_meminfo)"
  ss_line="$(capture_ss_counts)"
  conntrack_line="$(capture_conntrack)"
  local tcp_mem_pages="n/a"
  if [ -r /proc/net/sockstat ]; then
    tcp_mem_pages="$(awk '/^TCP:/ { for(i=1;i<=NF;i++) if($i=="mem") {print $(i+1); exit} }' /proc/net/sockstat 2>/dev/null || echo n/a)"
  fi
  docker_line="$(capture_docker_and_process_metrics "$container_name")"

  # Write the file header first so capture_window_metrics can append samples
  local loadavg_1 loadavg_5 loadavg_15
  IFS=$'\t' read -r loadavg_1 loadavg_5 loadavg_15 <<< "$load_line"
  local mem_total_mb mem_used_mb mem_available_mb mem_used_pct
  IFS=$'\t' read -r mem_total_mb mem_used_mb mem_available_mb mem_used_pct <<< "$mem_line"
  local tcp_total tcp_estab tcp_time_wait tcp_close_wait tcp_syn_recv tcp_listen
  IFS=$'\t' read -r tcp_total tcp_estab tcp_time_wait tcp_close_wait tcp_syn_recv tcp_listen <<< "$ss_line"
  local conntrack_count conntrack_max conntrack_usage_pct conntrack_usage
  IFS=$'\t' read -r conntrack_count conntrack_max conntrack_usage_pct conntrack_usage <<< "$conntrack_line"
  local docker_container docker_cpu_pct docker_mem_usage docker_mem_pct docker_pid proxy_threads proxy_open_fds proxy_rss_mb proxy_ctx_switches
  IFS=$'\t' read -r docker_container docker_cpu_pct docker_mem_usage docker_mem_pct docker_pid proxy_threads proxy_open_fds proxy_rss_mb proxy_ctx_switches <<< "$docker_line"
  local docker_mem_used_mb="n/a"
  if [ -n "$docker_mem_usage" ] && [ "$docker_mem_usage" != "n/a" ]; then
    local raw_used dval dunit
    raw_used="$(printf '%s' "$docker_mem_usage" | awk -F'/' '{gsub(/[[:space:]]/, "", $1); print $1}')"
    dval="$(printf '%s' "$raw_used" | sed 's/[A-Za-z]*$//')"
    dunit="$(printf '%s' "$raw_used" | sed 's/[0-9.]*//')"
    case "$dunit" in
      GiB) docker_mem_used_mb="$(awk -v v="$dval" 'BEGIN { printf "%.0f", v * 1024 }')" ;;
      MiB) docker_mem_used_mb="$(awk -v v="$dval" 'BEGIN { printf "%.0f", v }')" ;;
      KiB) docker_mem_used_mb="$(awk -v v="$dval" 'BEGIN { printf "%.0f", v / 1024 }')" ;;
    esac
  fi

  # Create file and set env vars so capture_window_metrics writes samples into it
  : > "$file_path"
  export SNAPSHOT_SAMPLE_FILE="$file_path"
  export SNAPSHOT_CONTAINER_NAME="$container_name"
  window_line="$(capture_window_metrics "$SAMPLE_SECONDS" "$iface_name")"
  unset SNAPSHOT_SAMPLE_FILE SNAPSHOT_CONTAINER_NAME

  local cpu_busy_pct cpu_user_pct cpu_system_pct cpu_iowait_pct cpu_softirq_pct cpu_irq_pct cpu_steal_pct
  local rx_mbps tx_mbps rx_pps tx_pps iface_rx_drop_delta iface_tx_drop_delta iface_rx_err_delta iface_tx_err_delta
  local tcp_retrans_delta listen_overflows_delta listen_drops_delta backlog_drops_delta syn_retrans_delta tcp_timeouts_delta ip_in_discards_delta ip_out_discards_delta
  IFS=$'\t' read -r \
    cpu_busy_pct cpu_user_pct cpu_system_pct cpu_iowait_pct cpu_softirq_pct cpu_irq_pct cpu_steal_pct \
    rx_mbps tx_mbps rx_pps tx_pps iface_rx_drop_delta iface_tx_drop_delta iface_rx_err_delta iface_tx_err_delta \
    tcp_retrans_delta listen_overflows_delta listen_drops_delta backlog_drops_delta syn_retrans_delta tcp_timeouts_delta ip_in_discards_delta ip_out_discards_delta <<< "$window_line"

  {
    write_kv kind "$kind"
    write_kv label "$label"
    write_kv captured_at "$snapshot_ts"
    write_kv sample_seconds "$SAMPLE_SECONDS"
    write_kv host "$host_name"
    write_kv cpu_cores "$cpu_cores"
    write_kv iface_name "$iface_name"
    write_kv loadavg_1 "$loadavg_1"
    write_kv loadavg_5 "$loadavg_5"
    write_kv loadavg_15 "$loadavg_15"
    write_kv mem_total_mb "$mem_total_mb"
    write_kv mem_used_mb "$mem_used_mb"
    write_kv mem_available_mb "$mem_available_mb"
    write_kv mem_used_pct "$mem_used_pct"
    write_kv cpu_busy_pct "$cpu_busy_pct"
    write_kv cpu_user_pct "$cpu_user_pct"
    write_kv cpu_system_pct "$cpu_system_pct"
    write_kv cpu_iowait_pct "$cpu_iowait_pct"
    write_kv cpu_softirq_pct "$cpu_softirq_pct"
    write_kv cpu_irq_pct "$cpu_irq_pct"
    write_kv cpu_steal_pct "$cpu_steal_pct"
    write_kv docker_container "$docker_container"
    write_kv docker_cpu_pct "$docker_cpu_pct"
    write_kv docker_mem_usage "$docker_mem_usage"
    write_kv docker_mem_pct "$docker_mem_pct"
    write_kv docker_mem_used_mb "$docker_mem_used_mb"
    write_kv docker_pid "$docker_pid"
    write_kv proxy_threads "$proxy_threads"
    write_kv proxy_open_fds "$proxy_open_fds"
    write_kv proxy_rss_mb "$proxy_rss_mb"
    write_kv proxy_ctx_switches "$proxy_ctx_switches"
    write_kv tcp_total "$tcp_total"
    write_kv tcp_estab "$tcp_estab"
    write_kv tcp_time_wait "$tcp_time_wait"
    write_kv tcp_close_wait "$tcp_close_wait"
    write_kv tcp_syn_recv "$tcp_syn_recv"
    write_kv tcp_listen "$tcp_listen"
    write_kv rx_mbps "$rx_mbps"
    write_kv tx_mbps "$tx_mbps"
    write_kv rx_pps "$rx_pps"
    write_kv tx_pps "$tx_pps"
    write_kv iface_rx_drop_delta "$iface_rx_drop_delta"
    write_kv iface_tx_drop_delta "$iface_tx_drop_delta"
    write_kv iface_rx_err_delta "$iface_rx_err_delta"
    write_kv iface_tx_err_delta "$iface_tx_err_delta"
    write_kv tcp_retrans_delta "$tcp_retrans_delta"
    write_kv listen_overflows_delta "$listen_overflows_delta"
    write_kv listen_drops_delta "$listen_drops_delta"
    write_kv backlog_drops_delta "$backlog_drops_delta"
    write_kv syn_retrans_delta "$syn_retrans_delta"
    write_kv tcp_timeouts_delta "$tcp_timeouts_delta"
    write_kv ip_in_discards_delta "$ip_in_discards_delta"
    write_kv ip_out_discards_delta "$ip_out_discards_delta"
    write_kv conntrack_count "$conntrack_count"
    write_kv conntrack_max "$conntrack_max"
    write_kv conntrack_usage_pct "$conntrack_usage_pct"
    write_kv conntrack_usage "$conntrack_usage"
    write_kv tcp_mem_pages "$tcp_mem_pages"
    write_kv sysctl_qdisc "$(read_sysctl_value net.core.default_qdisc)"
    write_kv sysctl_cc "$(read_sysctl_value net.ipv4.tcp_congestion_control)"
    write_kv sysctl_somaxconn "$(read_sysctl_value net.core.somaxconn)"
    write_kv sysctl_syn_backlog "$(read_sysctl_value net.ipv4.tcp_max_syn_backlog)"
    write_kv sysctl_netdev_backlog "$(read_sysctl_value net.core.netdev_max_backlog)"
    write_kv sysctl_tw_reuse "$(read_sysctl_value net.ipv4.tcp_tw_reuse)"
    write_kv sysctl_conntrack_max "$(read_sysctl_value net.netfilter.nf_conntrack_max)"
  } >> "$file_path"

  prune_snapshot_dir "$dir"

  echo "[saved] kind=$kind label=$label"
  echo "[saved] file=$file_path"
}

list_snapshot_files() {
  local dir="$1"
  find "$dir" -maxdepth 1 -type f -name '*.env' | sort | tail -n 4
}

snapshot_header() {
  local file="$1"
  (
    # shellcheck disable=SC1090
    . "$file"
    printf '%s: %s (%s)' "$kind" "$label" "$captured_at"
  )
}

snapshot_value() {
  local file="$1"
  local key="$2"
  (
    # shellcheck disable=SC1090
    . "$file"

    # If samples exist for this key, compute average (rounded to integer)
    local sc="${sample_count:-0}"
    if [ "$sc" -gt 0 ]; then
      local sum=0 count=0 si sv
      for ((si = 1; si <= sc; si++)); do
        local varname="sample_${si}_${key}"
        sv="${!varname:-}"
        if [[ "$sv" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
          sum="$(awk -v s="$sum" -v v="$sv" 'BEGIN { printf "%.2f", s+v }')"
          count=$((count + 1))
        fi
      done
      if [ "$count" -gt 0 ]; then
        awk -v s="$sum" -v c="$count" 'BEGIN { printf "%d", s/c + 0.5 }'
        return 0
      fi
    fi

    # Fallback to direct value
    printf '%s' "${!key:-n/a}"
  )
}

print_separator() {
  local count="$1"
  local i
  for ((i = 1; i <= count; i++)); do
    [ "$i" -gt 1 ] && printf '\t'
    printf '%s' '__SEP__'
  done
  printf '\n'
}

render_tsv_table() {
  awk -F '\t' '
    function repeat(ch, n,    out, i) {
      out=""
      for (i = 0; i < n; i++) out = out ch
      return out
    }
    {
      row_count = NR
      if (NF > col_count) col_count = NF
      for (i = 1; i <= NF; i++) {
        cell[NR, i] = $i
        if (length($i) > width[i]) width[i] = length($i)
      }
    }
    END {
      for (r = 1; r <= row_count; r++) {
        if (cell[r,1] == "__SEP__") {
          for (c = 1; c <= col_count; c++) {
            if (c > 1) printf "  "
            printf "%s", repeat("-", width[c])
          }
          printf "\n"
          continue
        }
        for (c = 1; c <= col_count; c++) {
          if (c > 1) printf "  "
          printf "%-*s", width[c], cell[r, c]
        }
        printf "\n"
      }
    }
  '
}

emit_snapshot_matrix() {
  local files=("$@")
  local headers=("metric")
  local file
  for file in "${files[@]}"; do
    headers+=("$(snapshot_header "$file")")
  done

  {
    local IFS=$'\t'
    printf '%s\n' "${headers[*]}"
    print_separator "${#headers[@]}"

    local metric_labels=(
      captured_at sample_seconds host iface_name cpu_cores
      loadavg_1 loadavg_5 loadavg_15
      mem_total_mb mem_used_mb mem_available_mb mem_used_pct
      cpu_busy_pct cpu_user_pct cpu_system_pct cpu_iowait_pct cpu_softirq_pct cpu_irq_pct cpu_steal_pct
      docker_container docker_cpu_pct docker_mem_usage docker_mem_pct docker_mem_used_mb docker_pid
      proxy_threads proxy_open_fds proxy_rss_mb proxy_ctx_switches
      tcp_total tcp_estab tcp_time_wait tcp_close_wait tcp_syn_recv tcp_listen
      rx_mbps tx_mbps rx_pps tx_pps
      iface_rx_drop_delta iface_tx_drop_delta iface_rx_err_delta iface_tx_err_delta
      tcp_retrans_delta listen_overflows_delta listen_drops_delta backlog_drops_delta syn_retrans_delta tcp_timeouts_delta ip_in_discards_delta ip_out_discards_delta
      conntrack_count conntrack_max conntrack_usage_pct conntrack_usage
      tcp_mem_pages
      sysctl_qdisc sysctl_cc sysctl_somaxconn sysctl_syn_backlog sysctl_netdev_backlog sysctl_tw_reuse sysctl_conntrack_max
    )

    local idx key value
    for ((idx = 0; idx < ${#metric_labels[@]}; idx++)); do
      key="${metric_labels[$idx]}"
      printf '%s' "$key"
      for file in "${files[@]}"; do
        value="$(snapshot_value "$file" "$key")"
        printf '\t%s' "$value"
      done
      printf '\n'
    done
  } | render_tsv_table
}

kpi_overall_verdict() {
  local better="$1"
  local worse="$2"
  local flat="$3"

  if [ "$better" -gt "$worse" ]; then
    printf 'improved'
  elif [ "$worse" -gt "$better" ]; then
    printf 'regressed'
  else
    if [ "$better" -eq 0 ] && [ "$worse" -eq 0 ]; then
      printf 'neutral'
    else
      printf 'mixed'
    fi
  fi
}

kpi_overall_emoji() {
  case "$1" in
    improved) printf '🟢' ;;
    regressed) printf '🔴' ;;
    mixed) printf '🟡' ;;
    neutral) printf '⚪' ;;
    *) printf '⚪' ;;
  esac
}

compute_per_conn_kpis() {
  local file="$1"
  local prefix="$2"

  local estab tcp_total rx tx cpu_busy docker_cpu mem_used docker_mem retrans timeouts conntrack
  estab="$(snapshot_value "$file" tcp_estab)"
  tcp_total="$(snapshot_value "$file" tcp_total)"
  rx="$(snapshot_value "$file" rx_mbps)"
  tx="$(snapshot_value "$file" tx_mbps)"
  cpu_busy="$(snapshot_value "$file" cpu_busy_pct)"
  docker_cpu="$(snapshot_value "$file" docker_cpu_pct)"
  mem_used="$(snapshot_value "$file" mem_used_mb)"
  docker_mem="$(snapshot_value "$file" docker_mem_used_mb)"
  retrans="$(snapshot_value "$file" tcp_retrans_delta)"
  timeouts="$(snapshot_value "$file" tcp_timeouts_delta)"
  conntrack="$(snapshot_value "$file" conntrack_usage_pct)"

  # Prefer docker container memory for per-conn cost (excludes host OS overhead)
  # Fallback to host mem_used for older snapshots without docker_mem_used_mb
  local mem_for_conn="$docker_mem"
  if ! is_number "$mem_for_conn" || [ "$mem_for_conn" -le 0 ]; then
    mem_for_conn="$mem_used"
  fi

  # Use tcp_total for memory-per-conn (all TCP states consume kernel memory)
  local tcp_divisor="$tcp_total"
  if ! is_number "$tcp_divisor" || [ "$tcp_divisor" -le 0 ]; then
    tcp_divisor="$estab"
  fi

  local avg_mbps="n/a"
  if is_number "$rx" && is_number "$tx"; then
    avg_mbps="$(awk -v r="$rx" -v t="$tx" 'BEGIN { printf "%.2f", (r+t)/2 }')"
  fi

  eval "${prefix}_estab=\"$estab\""
  eval "${prefix}_avg_mbps=\"$avg_mbps\""
  eval "${prefix}_conntrack=\"$conntrack\""

  if is_number "$estab" && [ "$estab" -gt 0 ]; then
    eval "${prefix}_throughput_per_conn=\"$(awk -v m="$avg_mbps" -v e="$estab" 'BEGIN { if (e>0) printf "%.4f", m/e; else print "n/a" }')\""
    eval "${prefix}_cpu_per_conn=\"$(awk -v c="$cpu_busy" -v e="$estab" 'BEGIN { if (e>0) printf "%.5f", c/e; else print "n/a" }')\""
    # mem_per_conn: docker container memory / tcp_total (matches diag formula)
    eval "${prefix}_mem_per_conn=\"$(awk -v m="$mem_for_conn" -v e="$tcp_divisor" 'BEGIN { if (e>0) printf "%.3f", m/e; else print "n/a" }')\""
    eval "${prefix}_retrans_per_conn=\"$(awk -v r="$retrans" -v e="$estab" 'BEGIN { if (e>0) printf "%.2f", r/e; else print "n/a" }')\""
    eval "${prefix}_timeouts_per_conn=\"$(awk -v t="$timeouts" -v e="$estab" 'BEGIN { if (e>0) printf "%.2f", t/e; else print "n/a" }')\""
    if is_number "$avg_mbps" && is_number "$cpu_busy"; then
      eval "${prefix}_efficiency=\"$(awk -v m="$avg_mbps" -v c="$cpu_busy" 'BEGIN { if (c>0) printf "%.2f", m/c; else print "n/a" }')\""
    else
      eval "${prefix}_efficiency=\"n/a\""
    fi
  else
    eval "${prefix}_throughput_per_conn=\"n/a\""
    eval "${prefix}_cpu_per_conn=\"n/a\""
    eval "${prefix}_mem_per_conn=\"n/a\""
    eval "${prefix}_retrans_per_conn=\"n/a\""
    eval "${prefix}_timeouts_per_conn=\"n/a\""
    eval "${prefix}_efficiency=\"n/a\""
  fi
}

check_load_comparability() {
  local before_estab="$1"
  local after_estab="$2"

  if ! is_number "$before_estab" || ! is_number "$after_estab"; then
    printf 'unknown'
    return 0
  fi
  if [ "$before_estab" -eq 0 ] || [ "$after_estab" -eq 0 ]; then
    printf 'incomparable'
    return 0
  fi

  local pct_diff
  pct_diff="$(awk -v b="$before_estab" -v a="$after_estab" 'BEGIN {
    diff = (a - b)
    if (diff < 0) diff = -diff
    printf "%.1f", (diff / b) * 100
  }')"

  local threshold=20
  local is_over
  is_over="$(awk -v p="$pct_diff" -v t="$threshold" 'BEGIN { print (p > t) ? 1 : 0 }')"

  if [ "$is_over" -eq 1 ]; then
    printf 'divergent\t%s' "$pct_diff"
  else
    printf 'comparable\t%s' "$pct_diff"
  fi
}

summarize_kpi_pair() {
  local before_file="$1"
  local after_file="$2"

  compute_per_conn_kpis "$before_file" "b"
  compute_per_conn_kpis "$after_file" "a"

  local metrics=(
    throughput_per_conn efficiency
    cpu_per_conn mem_per_conn
    retrans_per_conn timeouts_per_conn
    conntrack
  )
  local directions=(
    higher higher
    lower lower
    lower lower
    lower
  )
  local tolerances=(
    0 0
    0 0
    15 15
    0
  )
  # Scored: 1 = counts toward verdict, 0 = informational only
  # Stable: efficiency, mem_per_conn. Load-dependent: throughput_per_conn, cpu_per_conn
  local scored=(
    0 1
    0 1
    0 0
    0
  )
  local before_values=(
    "$b_throughput_per_conn" "$b_efficiency"
    "$b_cpu_per_conn" "$b_mem_per_conn"
    "$b_retrans_per_conn" "$b_timeouts_per_conn"
    "$b_conntrack"
  )
  local after_values=(
    "$a_throughput_per_conn" "$a_efficiency"
    "$a_cpu_per_conn" "$a_mem_per_conn"
    "$a_retrans_per_conn" "$a_timeouts_per_conn"
    "$a_conntrack"
  )

  local better=0 worse=0 flat=0 na=0
  local idx key direction bv av note tol sc
  for ((idx = 0; idx < ${#metrics[@]}; idx++)); do
    bv="${before_values[$idx]}"
    av="${after_values[$idx]}"
    direction="${directions[$idx]}"
    tol="${tolerances[$idx]}"
    sc="${scored[$idx]}"
    if is_number "$bv" && is_number "$av"; then
      note="$(compare_note "$bv" "$av" "$direction" "$tol")"
      if [ "$sc" = "1" ]; then
        case "$note" in
          better) better=$((better + 1)) ;;
          worse) worse=$((worse + 1)) ;;
          flat) flat=$((flat + 1)) ;;
        esac
      fi
    else
      na=$((na + 1))
    fi
  done

  local verdict
  verdict="$(kpi_overall_verdict "$better" "$worse" "$flat")"
  printf '%s\t%s\t%s\t%s\t%s\n' "$verdict" "$better" "$worse" "$flat" "$na"
}

emit_pairwise_summary() {
  local before_file="$1"
  local after_file="$2"

  compute_per_conn_kpis "$before_file" "b"
  compute_per_conn_kpis "$after_file" "a"

  local metrics=(
    tcp_estab avg_mbps
    throughput_per_conn efficiency
    cpu_per_conn mem_per_conn
    retrans_per_conn timeouts_per_conn
    conntrack
  )
  local labels=(
    "tcp_estab (load)" "avg_mbps (total)"
    "mbps/conn" "mbps/cpu% (efficiency)"
    "cpu%/conn" "mem_mb/conn"
    "retrans/conn" "timeouts/conn"
    "conntrack_usage_%"
  )
  local directions=(
    n/a n/a
    higher higher
    lower lower
    lower lower
    lower
  )
  local tolerances=(
    0 0
    0 0
    0 0
    15 15
    0
  )
  local before_values=(
    "$b_estab" "$b_avg_mbps"
    "$b_throughput_per_conn" "$b_efficiency"
    "$b_cpu_per_conn" "$b_mem_per_conn"
    "$b_retrans_per_conn" "$b_timeouts_per_conn"
    "$b_conntrack"
  )
  local after_values=(
    "$a_estab" "$a_avg_mbps"
    "$a_throughput_per_conn" "$a_efficiency"
    "$a_cpu_per_conn" "$a_mem_per_conn"
    "$a_retrans_per_conn" "$a_timeouts_per_conn"
    "$a_conntrack"
  )

  {
    printf 'kpi\tbefore\tafter\tdelta\tverdict\n'
    print_separator 5

    local idx label direction bv av delta note tol
    for ((idx = 0; idx < ${#metrics[@]}; idx++)); do
      label="${labels[$idx]}"
      direction="${directions[$idx]}"
      tol="${tolerances[$idx]}"
      bv="${before_values[$idx]}"
      av="${after_values[$idx]}"
      if is_number "$bv" && is_number "$av"; then
        delta="$(calc_delta "$bv" "$av")"
        if [ "$direction" = "n/a" ]; then
          note="n/a"
        else
          note="$(compare_note "$bv" "$av" "$direction" "$tol")"
        fi
      else
        delta="n/a"
        note="n/a"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$label" "$bv" "$av" "$delta" "$(format_verdict_with_emoji "$note")"
    done
  } | render_tsv_table
}

emit_capacity_estimate() {
  local file="$1"
  local label="$2"

  local mem_total mem_used mem_avail docker_mem cpu_busy cpu_cores estab tcp_total tcp_mem_pages conntrack_count conntrack_max
  mem_total="$(snapshot_value "$file" mem_total_mb)"
  mem_used="$(snapshot_value "$file" mem_used_mb)"
  mem_avail="$(snapshot_value "$file" mem_available_mb)"
  docker_mem="$(snapshot_value "$file" docker_mem_used_mb)"
  cpu_busy="$(snapshot_value "$file" cpu_busy_pct)"
  cpu_cores="$(snapshot_value "$file" cpu_cores)"
  estab="$(snapshot_value "$file" tcp_estab)"
  tcp_total="$(snapshot_value "$file" tcp_total)"
  tcp_mem_pages="$(snapshot_value "$file" tcp_mem_pages)"
  conntrack_count="$(snapshot_value "$file" conntrack_count)"
  conntrack_max="$(snapshot_value "$file" conntrack_max)"

  # Prefer docker container memory (excludes host OS overhead)
  local mem_for_conn="$docker_mem"
  if ! is_number "$mem_for_conn" || [ "$mem_for_conn" -le 0 ]; then
    mem_for_conn="$mem_used"
  fi

  if ! is_number "$estab" || [ "$estab" -le 0 ]; then
    printf '  %s: insufficient data (no ESTABLISHED connections)\n' "$label"
    return 0
  fi

  # Use tcp_total for per-conn cost — all TCP states consume kernel memory
  local tcp_divisor="$tcp_total"
  if ! is_number "$tcp_divisor" || [ "$tcp_divisor" -le 0 ]; then
    tcp_divisor="$estab"
  fi

  # Memory per connection: docker container memory / tcp_total (matches diag formula)
  # Fallback to host mem_used for older snapshots
  local mem_per_conn="n/a" mem_capacity="n/a"
  if is_number "$mem_for_conn" && is_number "$mem_total" && [ "$mem_for_conn" -gt 0 ] && is_number "$tcp_divisor" && [ "$tcp_divisor" -gt 0 ]; then
    mem_per_conn="$(awk -v m="$mem_for_conn" -v e="$tcp_divisor" 'BEGIN { printf "%.3f", m/e }')"
    # Capacity based on container mem limit (docker_mem / tcp_total extrapolated to limit)
    # Use mem_total as proxy for limit since we don't store container limit in snapshot
    mem_capacity="$(awk -v t="$mem_total" -v pc="$mem_per_conn" 'BEGIN { if (pc>0) printf "%d", (t*0.85)/pc; else print "n/a" }')"
  fi

  # CPU per connection from actual usage
  local cpu_per_conn="n/a" cpu_capacity="n/a"
  if is_number "$cpu_busy" && is_number "$cpu_cores"; then
    cpu_per_conn="$(awk -v c="$cpu_busy" -v e="$estab" 'BEGIN { printf "%.5f", c/e }')"
    # Capacity = 80% of total CPU / per-conn usage (leave 20% headroom)
    local total_cpu_pct
    total_cpu_pct="$(awk -v cores="$cpu_cores" 'BEGIN { printf "%.0f", cores * 100 }')"
    cpu_capacity="$(awk -v t="$total_cpu_pct" -v pc="$cpu_per_conn" 'BEGIN { if (pc>0) printf "%d", (t*0.80)/pc; else print "n/a" }')"
  fi

  # Conntrack capacity
  local conntrack_capacity="n/a"
  if is_number "$conntrack_max" && [ "$conntrack_max" -gt 0 ]; then
    # Each proxied connection ~2 conntrack entries; use 80% of max
    conntrack_capacity="$(awk -v m="$conntrack_max" 'BEGIN { printf "%d", (m*0.80)/2 }')"
  fi

  # Overall = min of all
  local capacity="n/a"
  local bottleneck="n/a"
  if is_number "$mem_capacity" && is_number "$cpu_capacity" && is_number "$conntrack_capacity"; then
    capacity="$mem_capacity"
    bottleneck="memory"
    if [ "$(awk -v a="$cpu_capacity" -v b="$capacity" 'BEGIN { print (a<b) ? 1 : 0 }')" -eq 1 ]; then
      capacity="$cpu_capacity"
      bottleneck="cpu"
    fi
    if [ "$(awk -v a="$conntrack_capacity" -v b="$capacity" 'BEGIN { print (a<b) ? 1 : 0 }')" -eq 1 ]; then
      capacity="$conntrack_capacity"
      bottleneck="conntrack"
    fi
  elif is_number "$mem_capacity" && is_number "$cpu_capacity"; then
    capacity="$mem_capacity"
    bottleneck="memory"
    if [ "$(awk -v a="$cpu_capacity" -v b="$capacity" 'BEGIN { print (a<b) ? 1 : 0 }')" -eq 1 ]; then
      capacity="$cpu_capacity"
      bottleneck="cpu"
    fi
  fi

  printf '  %s (tcp_estab=%s):\n' "$label" "$estab"
  printf '    mem/conn:       %s MB → mem-limited:       ~%s conns\n' "$mem_per_conn" "$mem_capacity"
  printf '    cpu%%/conn:      %s%%  → cpu-limited:       ~%s conns\n' "$cpu_per_conn" "$cpu_capacity"
  printf '    conntrack_max:  %s    → conntrack-limited: ~%s conns\n' "$conntrack_max" "$conntrack_capacity"
  if is_number "$capacity"; then
    printf '    ➜ estimated max capacity: ~%s connections (bottleneck: %s)\n' "$capacity" "$bottleneck"
  fi
}

emit_capacity_comparison() {
  local before_file="$1"
  local after_file="$2"

  echo "📊 Capacity estimate (extrapolated from actual per-connection resource usage)"
  echo
  emit_capacity_estimate "$before_file" "BEFORE"
  echo
  emit_capacity_estimate "$after_file" "AFTER"

  # Delta summary
  local b_estab a_estab b_mem_used a_mem_used b_mem_total a_mem_total
  local b_cpu_busy a_cpu_busy b_cpu_cores b_conntrack_max a_conntrack_max
  b_estab="$(snapshot_value "$before_file" tcp_estab)"
  a_estab="$(snapshot_value "$after_file" tcp_estab)"
  b_mem_used="$(snapshot_value "$before_file" mem_used_mb)"
  a_mem_used="$(snapshot_value "$after_file" mem_used_mb)"
  b_mem_total="$(snapshot_value "$before_file" mem_total_mb)"
  a_mem_total="$(snapshot_value "$after_file" mem_total_mb)"
  b_cpu_busy="$(snapshot_value "$before_file" cpu_busy_pct)"
  a_cpu_busy="$(snapshot_value "$after_file" cpu_busy_pct)"
  b_cpu_cores="$(snapshot_value "$before_file" cpu_cores)"
  b_conntrack_max="$(snapshot_value "$before_file" conntrack_max)"
  a_conntrack_max="$(snapshot_value "$after_file" conntrack_max)"

  if is_number "$b_estab" && [ "$b_estab" -gt 0 ] && is_number "$a_estab" && [ "$a_estab" -gt 0 ] \
     && is_number "$b_mem_used" && is_number "$a_mem_used" \
     && is_number "$b_mem_total" && is_number "$a_mem_total"; then

    local b_mpc a_mpc b_cap a_cap
    b_mpc="$(awk -v m="$b_mem_used" -v e="$b_estab" 'BEGIN { printf "%.3f", m/e }')"
    a_mpc="$(awk -v m="$a_mem_used" -v e="$a_estab" 'BEGIN { printf "%.3f", m/e }')"
    b_cap="$(awk -v t="$b_mem_total" -v pc="$b_mpc" 'BEGIN { if (pc>0) printf "%d", (t*0.85)/pc; else print 0 }')"
    a_cap="$(awk -v t="$a_mem_total" -v pc="$a_mpc" 'BEGIN { if (pc>0) printf "%d", (t*0.85)/pc; else print 0 }')"

    if is_number "$b_cap" && is_number "$a_cap" && [ "$b_cap" -gt 0 ]; then
      local change_pct
      change_pct="$(awk -v b="$b_cap" -v a="$a_cap" 'BEGIN { printf "%+.0f", ((a-b)/b)*100 }')"
      echo
      if [ "$(awk -v a="$a_cap" -v b="$b_cap" 'BEGIN { print (a>b) ? 1 : 0 }')" -eq 1 ]; then
        printf '  🟢 Memory-based capacity: %s → %s (%s%% change) — more headroom without extra cost\n' "$b_cap" "$a_cap" "$change_pct"
      elif [ "$(awk -v a="$a_cap" -v b="$b_cap" 'BEGIN { print (a<b) ? 1 : 0 }')" -eq 1 ]; then
        printf '  🔴 Memory-based capacity: %s → %s (%s%% change)\n' "$b_cap" "$a_cap" "$change_pct"
      else
        printf '  🟡 Memory-based capacity: %s → %s (no change)\n' "$b_cap" "$a_cap"
      fi
    fi
  fi
}

emit_pairwise_comparison() {
  local before_file="$1"
  local after_file="$2"
  local before_label after_label before_time after_time

  before_label="$(snapshot_value "$before_file" label)"
  before_time="$(snapshot_value "$before_file" captured_at)"
  after_label="$(snapshot_value "$after_file" label)"
  after_time="$(snapshot_value "$after_file" captured_at)"

  local before_estab after_estab
  before_estab="$(snapshot_value "$before_file" tcp_estab)"
  after_estab="$(snapshot_value "$after_file" tcp_estab)"

  local overall_stats overall_verdict better_count worse_count flat_count na_count
  overall_stats="$(summarize_kpi_pair "$before_file" "$after_file")"
  IFS=$'\t' read -r overall_verdict better_count worse_count flat_count na_count <<< "$overall_stats"

  echo
  echo "⚖️ Pair comparison: BEFORE '$before_label' ($before_time) -> AFTER '$after_label' ($after_time)"

  # Load comparability check
  local comp_result comp_status comp_pct
  comp_result="$(check_load_comparability "$before_estab" "$after_estab")"
  comp_status="$(printf '%s' "$comp_result" | cut -f1)"
  comp_pct="$(printf '%s' "$comp_result" | cut -f2)"

  case "$comp_status" in
    divergent)
      echo "⚠️  Load divergence: tcp_estab differs by ${comp_pct}% (before=${before_estab}, after=${after_estab})"
      echo "    Absolute metrics (mbps, retrans, timeouts) are NOT directly comparable."
      echo "    Per-connection normalized KPIs below account for this difference."
      echo
      ;;
    incomparable)
      echo "⚠️  Load incomparable: one or both snapshots have zero ESTABLISHED connections."
      echo
      ;;
    comparable)
      echo "✅ Load comparable: tcp_estab differs by only ${comp_pct}% (before=${before_estab}, after=${after_estab})"
      echo
      ;;
  esac

  echo "🏁 Overall verdict (per-connection normalized): $(kpi_overall_emoji "$overall_verdict") $overall_verdict  (🟢 $better_count / 🔴 $worse_count / 🟡 $flat_count / ⚪ $na_count)"
  echo
  echo "📈 Proxy efficiency (normalized per ESTABLISHED connection)"
  emit_pairwise_summary "$before_file" "$after_file"
  echo
  echo "🔎 Raw metrics (absolute values — compare only when load is similar)"

  local metrics=(
    rx_mbps tx_mbps rx_pps tx_pps
    cpu_busy_pct cpu_iowait_pct cpu_softirq_pct cpu_steal_pct docker_cpu_pct
    iface_rx_drop_delta iface_tx_drop_delta iface_rx_err_delta iface_tx_err_delta
    tcp_retrans_delta listen_overflows_delta listen_drops_delta backlog_drops_delta syn_retrans_delta tcp_timeouts_delta ip_in_discards_delta ip_out_discards_delta
    conntrack_usage_pct proxy_rss_mb proxy_open_fds
  )
  local directions=(
    higher higher higher higher
    lower lower lower lower lower
    lower lower lower lower
    lower lower lower lower lower lower lower lower
    lower lower lower
  )
  local raw_tolerances=(
    0 0 0 0
    0 0 0 0 0
    0 0 0 0
    15 0 0 0 15 15 0 0
    0 0 0
  )

  {
    printf 'metric\tbefore\tafter\tdelta\tverdict\n'
    print_separator 5

    local idx key direction before_value after_value delta note tol
    for ((idx = 0; idx < ${#metrics[@]}; idx++)); do
      key="${metrics[$idx]}"
      direction="${directions[$idx]}"
      tol="${raw_tolerances[$idx]}"
      before_value="$(snapshot_value "$before_file" "$key")"
      after_value="$(snapshot_value "$after_file" "$key")"
      if is_number "$before_value" && is_number "$after_value"; then
        delta="$(calc_delta "$before_value" "$after_value")"
        note="$(compare_note "$before_value" "$after_value" "$direction" "$tol")"
      else
        delta="n/a"
        note="n/a"
      fi
      printf '%s\t%s\t%s\t%s\t%s\n' "$key" "$before_value" "$after_value" "$delta" "$(format_verdict_with_emoji "$note")"
    done
  } | render_tsv_table

  echo
  emit_capacity_comparison "$before_file" "$after_file"
}

metric_explanation() {
  local key="$1"
  local verdict="$2"
  case "$key" in
    "tcp_estab (load)")
      printf '  %b%s%b\n' "${C_DIM}" "Number of active proxy connections. Context metric — not scored." "${C_NC}" ;;
    "mbps/conn")
      case "$verdict" in
        better) printf '  %b✦ Each connection gets more throughput — network stack is more efficient.%b\n' "${C_GREEN}" "${C_NC}" ;;
        worse)  printf '  %b⚑ Less throughput per connection. May indicate congestion or suboptimal buffering.%b\n' "${C_RED}" "${C_NC}" ;;
        flat)   printf '  %b— Throughput per connection unchanged.%b\n' "${C_DIM}" "${C_NC}" ;;
      esac ;;
    "mbps/cpu% (efficiency)")
      case "$verdict" in
        better) printf '  %b✦ More traffic processed per CPU cycle — kernel tuning (BBR, fq) is working.%b\n' "${C_GREEN}" "${C_NC}" ;;
        worse)  printf '  %b⚑ CPU doing more work per Mbps. Check softirq overhead.%b\n' "${C_RED}" "${C_NC}" ;;
        flat)   printf '  %b— CPU efficiency unchanged.%b\n' "${C_DIM}" "${C_NC}" ;;
      esac ;;
    "cpu%/conn")
      case "$verdict" in
        better) printf '  %b✦ Less CPU per connection — system handles load more efficiently.%b\n' "${C_GREEN}" "${C_NC}" ;;
        worse)  printf '  %b⚑ More CPU per connection. Often temporary after restart (reconnect storm).%b\n' "${C_RED}" "${C_NC}" ;;
        flat)   printf '  %b— CPU per connection unchanged.%b\n' "${C_DIM}" "${C_NC}" ;;
      esac ;;
    "mem_mb/conn")
      case "$verdict" in
        better) printf '  %b✦ Less memory per connection — biggest capacity win. Directly increases max connections.%b\n' "${C_GREEN}" "${C_NC}" ;;
        worse)  printf '  %b⚑ More memory per connection. Normal as buffers warm up under sustained load.%b\n' "${C_RED}" "${C_NC}" ;;
        flat)   printf '  %b— Memory per connection unchanged.%b\n' "${C_DIM}" "${C_NC}" ;;
      esac ;;
    "retrans/conn")
      case "$verdict" in
        better) printf '  %b✦ Fewer retransmissions per connection — cleaner network path.%b\n' "${C_GREEN}" "${C_NC}" ;;
        worse)  printf '  %b⚑ More retransmissions (>15%% above baseline). Check transit path quality.%b\n' "${C_RED}" "${C_NC}" ;;
        flat)   printf '  %b— Retransmissions within tolerance (±15%%). Normal transit-level noise.%b\n' "${C_DIM}" "${C_NC}" ;;
      esac ;;
    "timeouts/conn")
      case "$verdict" in
        better) printf '  %b✦ Fewer timeouts per connection — connections are healthier.%b\n' "${C_GREEN}" "${C_NC}" ;;
        worse)  printf '  %b⚑ More timeouts (>15%% above baseline). Check transit path quality.%b\n' "${C_RED}" "${C_NC}" ;;
        flat)   printf '  %b— Timeouts within tolerance (±15%%). Normal transit-level noise.%b\n' "${C_DIM}" "${C_NC}" ;;
      esac ;;
    "conntrack_%")
      case "$verdict" in
        better) printf '  %b✦ More conntrack headroom — less risk of "table full, dropping packet".%b\n' "${C_GREEN}" "${C_NC}" ;;
        worse)  printf '  %b⚑ Conntrack table more full. Consider increasing nf_conntrack_max.%b\n' "${C_RED}" "${C_NC}" ;;
        flat)   printf '  %b— Conntrack usage unchanged.%b\n' "${C_DIM}" "${C_NC}" ;;
      esac ;;
    "capacity (mem)")
      case "$verdict" in
        better) printf '  %b✦ Server can handle more concurrent connections on the same hardware — no extra cost.%b\n' "${C_GREEN}" "${C_NC}" ;;
        worse)  printf '  %b⚑ Estimated capacity decreased. Normal as memory usage stabilizes under sustained load.%b\n' "${C_RED}" "${C_NC}" ;;
        flat)   printf '  %b— Capacity unchanged.%b\n' "${C_DIM}" "${C_NC}" ;;
      esac ;;
  esac
}

emit_timeline() {
  local baseline="$1"
  shift
  local after_files=("$@")

  local baseline_label baseline_time
  baseline_label="$(snapshot_value "$baseline" label)"
  baseline_time="$(snapshot_value "$baseline" captured_at)"

  echo
  echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_NC}"
  echo -e "${C_BOLD}║  📉 Performance Timeline                                ║${C_NC}"
  echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_NC}"
  echo -e "  Baseline: ${C_CYAN}${baseline_label}${C_NC} (${baseline_time})"
  echo -e "  ${C_DIM}All values normalized per ESTABLISHED connection${C_NC}"
  echo

  compute_per_conn_kpis "$baseline" "base"

  local timeline_metrics=(
    "tcp_estab (load)"
    "mbps/conn"
    "mbps/cpu% (efficiency)"
    "cpu%/conn"
    "mem_mb/conn"
    "retrans/conn"
    "timeouts/conn"
    "conntrack_%"
    "capacity (mem)"
  )
  local timeline_directions=(
    n/a higher higher lower lower lower lower lower higher
  )
  # Tolerance thresholds (% change within tolerance = "flat" instead of "worse")
  # retrans/conn and timeouts/conn get 15% tolerance due to transit-level noise
  local timeline_tolerances=(
    0 0 0 0 0 15 15 0 0
  )
  # Scored: 1 = counts toward verdict, 0 = displayed but not scored
  # Stable metrics: mbps/cpu% (efficiency), mem_mb/conn, capacity
  # Informational: tcp_estab, mbps/conn (load-dependent), cpu%/conn, retrans, timeouts, conntrack
  local timeline_scored=(
    0 0 1 0 1 0 0 0 1
  )

  # Compute baseline capacity
  local base_capacity="n/a"
  if is_number "$base_estab" && [ "$base_estab" -gt 0 ] && is_number "$base_mem_per_conn"; then
    local base_mem_total
    base_mem_total="$(snapshot_value "$baseline" mem_total_mb)"
    if is_number "$base_mem_total" && is_number "$base_mem_per_conn"; then
      base_capacity="$(awk -v t="$base_mem_total" -v pc="$base_mem_per_conn" 'BEGIN { if (pc>0) printf "%d", (t*0.85)/pc; else print "n/a" }')"
    fi
  fi

  local base_values=(
    "$base_estab"
    "$base_throughput_per_conn"
    "$base_efficiency"
    "$base_cpu_per_conn"
    "$base_mem_per_conn"
    "$base_retrans_per_conn"
    "$base_timeouts_per_conn"
    "$base_conntrack"
    "$base_capacity"
  )

  # Compute all after values
  local -a all_after_values=()
  local -a all_after_capacities=()
  local -a all_after_labels=()
  local fi_idx
  for ((fi_idx = 0; fi_idx < ${#after_files[@]}; fi_idx++)); do
    compute_per_conn_kpis "${after_files[$fi_idx]}" "af"

    local af_capacity="n/a"
    if is_number "$af_estab" && [ "$af_estab" -gt 0 ] && is_number "$af_mem_per_conn"; then
      local af_mem_total
      af_mem_total="$(snapshot_value "${after_files[$fi_idx]}" mem_total_mb)"
      if is_number "$af_mem_total" && is_number "$af_mem_per_conn"; then
        af_capacity="$(awk -v t="$af_mem_total" -v pc="$af_mem_per_conn" 'BEGIN { if (pc>0) printf "%d", (t*0.85)/pc; else print "n/a" }')"
      fi
    fi

    all_after_values+=("$af_estab" "$af_throughput_per_conn" "$af_efficiency" "$af_cpu_per_conn" "$af_mem_per_conn" "$af_retrans_per_conn" "$af_timeouts_per_conn" "$af_conntrack" "$af_capacity")
    all_after_capacities+=("$af_capacity")
    all_after_labels+=("$(snapshot_value "${after_files[$fi_idx]}" label)")
  done

  local num_metrics="${#timeline_metrics[@]}"

  # Print each metric as a visual block
  local mi
  for ((mi = 0; mi < num_metrics; mi++)); do
    local metric_name="${timeline_metrics[$mi]}"
    local direction="${timeline_directions[$mi]}"
    local scored="${timeline_scored[$mi]}"
    local bv="${base_values[$mi]}"

    if [ "$scored" = "1" ]; then
      echo -e "  ${C_BOLD}${metric_name}${C_NC}"
    else
      echo -e "  ${C_DIM}${metric_name} (informational — not scored)${C_NC}"
    fi
    printf '    %-12s %s' "baseline:" "$bv"

    local last_verdict="flat"
    for ((fi_idx = 0; fi_idx < ${#after_files[@]}; fi_idx++)); do
      local av_idx=$(( fi_idx * num_metrics + mi ))
      local av="${all_after_values[$av_idx]}"
      local af_label="${all_after_labels[$fi_idx]}"

      if is_number "$bv" && is_number "$av" && [ "$direction" != "n/a" ]; then
        local delta pct note tol
        tol="${timeline_tolerances[$mi]}"
        delta="$(calc_delta "$bv" "$av")"
        pct="$(calc_pct_change "$bv" "$av")"
        note="$(compare_note "$bv" "$av" "$direction" "$tol")"
        last_verdict="$note"
        printf '\n    %-12s %s  ' "${af_label}:" "$av"
        format_delta_colored "${delta} (${pct})" "$note"
        printf '  '
        format_verdict_with_emoji "$note"
      elif is_number "$bv" && is_number "$av"; then
        local delta pct
        delta="$(calc_delta "$bv" "$av")"
        pct="$(calc_pct_change "$bv" "$av")"
        printf '\n    %-12s %s  %b%s%b' "${af_label}:" "$av" "${C_DIM}" "${delta} (${pct})" "${C_NC}"
      else
        printf '\n    %-12s %s' "${af_label}:" "$av"
      fi
    done
    printf '\n'

    # Print explanation for the last verdict
    metric_explanation "$metric_name" "$last_verdict"
    echo
  done

  # ── Capacity Summary ──
  echo -e "${C_BOLD}╔══════════════════════════════════════════════════════════╗${C_NC}"
  echo -e "${C_BOLD}║  📊 Capacity Summary                                    ║${C_NC}"
  echo -e "${C_BOLD}╚══════════════════════════════════════════════════════════╝${C_NC}"
  echo
  printf '  Baseline: ~%s connections\n' "$base_capacity"
  for ((fi_idx = 0; fi_idx < ${#after_files[@]}; fi_idx++)); do
    local ac="${all_after_capacities[$fi_idx]}"
    local af_label="${all_after_labels[$fi_idx]}"
    if is_number "$base_capacity" && is_number "$ac" && [ "$base_capacity" -gt 0 ]; then
      local pct_change
      pct_change="$(awk -v b="$base_capacity" -v a="$ac" 'BEGIN { printf "%+.0f%%", ((a-b)/b)*100 }')"
      if [ "$(awk -v a="$ac" -v b="$base_capacity" 'BEGIN { print (a>b) ? 1 : 0 }')" -eq 1 ]; then
        printf '       %-20s %b~%s connections  (%s)%b\n' "→ ${af_label}:" "${C_GREEN}" "$ac" "$pct_change" "${C_NC}"
      elif [ "$(awk -v a="$ac" -v b="$base_capacity" 'BEGIN { print (a<b) ? 1 : 0 }')" -eq 1 ]; then
        printf '       %-20s %b~%s connections  (%s)%b\n' "→ ${af_label}:" "${C_RED}" "$ac" "$pct_change" "${C_NC}"
      else
        printf '       %-20s ~%s connections  (%s)\n' "→ ${af_label}:" "$ac" "$pct_change"
      fi
    else
      printf '       %-20s ~%s connections\n' "→ ${af_label}:" "$ac"
    fi
  done
  echo -e "  ${C_DIM}Estimate based on actual memory-per-connection usage, 85% RAM headroom${C_NC}"
  echo

  # ── Overall Verdict (only scored metrics) ──
  local total_better=0 total_worse=0 total_flat=0
  local last_after_idx=$(( ${#after_files[@]} - 1 ))

  # Check if load is comparable (tcp_estab within 30%)
  local load_divergent=0
  local base_estab_val="${base_values[0]}"
  local last_estab_idx=$(( last_after_idx * num_metrics ))
  local last_estab_val="${all_after_values[$last_estab_idx]}"
  if is_number "$base_estab_val" && is_number "$last_estab_val" && [ "$base_estab_val" -gt 0 ]; then
    local load_pct_diff
    load_pct_diff="$(awk -v b="$base_estab_val" -v a="$last_estab_val" 'BEGIN { d=(a-b)/b*100; if(d<0)d=-d; printf "%.0f", d }')"
    if [ "$load_pct_diff" -gt 30 ]; then
      load_divergent=1
    fi
  fi

  for ((mi = 0; mi < num_metrics; mi++)); do
    local direction="${timeline_directions[$mi]}"
    local scored="${timeline_scored[$mi]}"
    [ "$direction" = "n/a" ] && continue
    [ "$scored" != "1" ] && continue
    # Skip efficiency (index 2) when load diverges >30% — not comparable
    if [ "$mi" -eq 2 ] && [ "$load_divergent" -eq 1 ]; then
      continue
    fi
    local bv="${base_values[$mi]}"
    local av_idx=$(( last_after_idx * num_metrics + mi ))
    local av="${all_after_values[$av_idx]}"
    if is_number "$bv" && is_number "$av"; then
      local note tol
      tol="${timeline_tolerances[$mi]}"
      note="$(compare_note "$bv" "$av" "$direction" "$tol")"
      case "$note" in
        better) total_better=$((total_better + 1)) ;;
        worse) total_worse=$((total_worse + 1)) ;;
        flat) total_flat=$((total_flat + 1)) ;;
      esac
    fi
  done

  local overall
  overall="$(kpi_overall_verdict "$total_better" "$total_worse" "$total_flat")"
  echo -e "${C_BOLD}━━━ Verdict (scored metrics: efficiency, memory, capacity) ━━━${C_NC}"
  if [ "$load_divergent" -eq 1 ]; then
    echo -e "  ${C_YELLOW}⚠ Load differs >30% (baseline=${base_estab_val}, latest=${last_estab_val}) — efficiency excluded from verdict${C_NC}"
  fi
  case "$overall" in
    improved)  printf '  %b✔ IMPROVED%b   ' "${C_GREEN}" "${C_NC}" ;;
    regressed) printf '  %b✘ REGRESSED%b  ' "${C_RED}" "${C_NC}" ;;
    mixed)     printf '  %b~ MIXED%b      ' "${C_YELLOW}" "${C_NC}" ;;
    neutral)   printf '  %b— NEUTRAL%b    ' "${C_DIM}" "${C_NC}" ;;
  esac
  printf '%b%s better%b  %b%s worse%b  %s flat\n' \
    "${C_GREEN}" "$total_better" "${C_NC}" \
    "${C_RED}" "$total_worse" "${C_NC}" \
    "$total_flat"
  echo
}

show_result() {
  local before_files=() after_files=() all_files=()
  while IFS= read -r file; do [ -n "$file" ] && before_files+=("$file"); done < <(list_snapshot_files "$BEFORE_DIR")
  while IFS= read -r file; do [ -n "$file" ] && after_files+=("$file"); done < <(list_snapshot_files "$AFTER_DIR")

  all_files=("${before_files[@]}" "${after_files[@]}")

  if [ "${#all_files[@]}" -eq 0 ]; then
    echo "[INFO] No snapshots found yet."
    echo "Run: bash scripts/snapshot.sh before \"baseline\""
    echo "Then: bash scripts/snapshot.sh after \"after apply\""
    return 0
  fi

  emit_snapshot_matrix "${all_files[@]}"

  if [ "${#before_files[@]}" -eq 0 ] || [ "${#after_files[@]}" -eq 0 ]; then
    return 0
  fi

  local baseline="${before_files[0]}"

  if [ "${#after_files[@]}" -ge 1 ]; then
    emit_timeline "$baseline" "${after_files[@]}"
  fi
}

main() {
  case "${1:-}" in
    before)
      if [ "$#" -lt 2 ]; then
        echo "[FAIL] before requires a quoted label." >&2
        usage
        exit 2
      fi
      capture_snapshot before "$2"
      ;;
    after)
      if [ "$#" -lt 2 ]; then
        echo "[FAIL] after requires a quoted label." >&2
        usage
        exit 2
      fi
      capture_snapshot after "$2"
      ;;
    result)
      show_result
      ;;
    --help|-h|help)
      usage
      ;;
    "")
      usage
      ;;
    *)
      echo "[FAIL] Unknown command: $1" >&2
      usage
      exit 2
      ;;
  esac
}

main "$@"
