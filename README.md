# RemnaWave Node Optimize

## Quick Start

The default bootstrap work directory is `/opt/remnawave-tools/oneliner`. **Remote one-liner** examples below use **`sudo`** so that directory can be created under `/opt`. When running from a **local clone** with `RW_BOOTSTRAP_BASE_URL="$PWD"`, you may omit `sudo` if you set **`RW_BOOTSTRAP_WORKDIR`** to a writable path (or create it beforehand).

### One-liner apply

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --yes
```

### Dry-run (no mutations)

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --dry-run
```

### Apply with CAKE shaping

`--speed` sets the per-user CAKE bandwidth limit and is forwarded to the apply path as `--shaping`.

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --yes --speed 50
```

The value `50` is normalized to `50mbit`. Explicit units are also accepted: `500kbit`, `50mbit`, `1gbit`.

### Explicit payload verification (safe launch)

```bash
mkdir -p scripts
curl -fsSLo scripts/optimize-bootstrap.sh https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh
curl -fsSLo VERSION https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/VERSION
curl -fsSLo manifest.sha256 https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/manifest.sha256
curl -fsSLo scripts/optimize.sh https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize.sh
curl -fsSLo scripts/diag.sh https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/diag.sh
curl -fsSLo scripts/snapshot.sh https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/snapshot.sh
sha256sum -c manifest.sha256
RW_BOOTSTRAP_BASE_URL="$PWD" RW_BOOTSTRAP_VERSION_EXPECTED="$(cat VERSION)" bash scripts/optimize-bootstrap.sh --dry-run
RW_BOOTSTRAP_BASE_URL="$PWD" RW_BOOTSTRAP_VERSION_EXPECTED="$(cat VERSION)" bash scripts/optimize-bootstrap.sh --yes --speed 50
```

Bootstrap uses the payload layout `VERSION`, `manifest.sha256`, `scripts/optimize-bootstrap.sh`, `scripts/optimize.sh`, `scripts/diag.sh`, `scripts/snapshot.sh` and verifies integrity via `manifest.sha256` and optional `RW_BOOTSTRAP_VERSION_EXPECTED` before any mutating steps. Local examples above can run without `sudo` when `RW_BOOTSTRAP_WORKDIR` points to a writable directory.

### Final report

Each successful run prints sections in strict order:

1. `BEFORE`
2. `APPLIED`
3. `AFTER`
4. `WHAT NEXT`

`APPLIED` uses only the statuses `changed`, `already-ok`, `skipped`, `failed`.

`WHAT NEXT` contains hints for reboot/restart, verify, and rollback. If apply created a transaction, the rollback command is printed with the specific `tx-id`.

### Debug diagnostics

`--debug` adds a `=== DEBUG ===` section after `WHAT NEXT`. Can be combined with `--yes` or `--dry-run`.

```bash
# Dry-run with debug report
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --dry-run --debug

# Apply with debug report
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --yes --debug
```

The `DEBUG` section contains machine-readable keys:

| Key | Description |
|---|---|
| `DEBUG_OS` | OS ID and version from `/etc/os-release` |
| `DEBUG_KERNEL` | Kernel version (`uname -r`) |
| `DEBUG_DOCKER_VERSION` | Docker Server version |
| `DEBUG_DOCKER_STATUS` | systemd service status of `docker` |
| `DEBUG_SYSCTL_<key>` | Current value of each managed sysctl parameter |
| `DEBUG_LIMITS_nofile_soft/hard` | Current file descriptor limits |
| `EVIDENCE_APPLY_SUMMARY` | Apply summary by step (`step=status,...`) |

Debug output can be saved and shared for analysis: `... --yes --debug 2>&1 | tee debug-report.txt`

### Network resilience and constrained networks

When GitHub CDN (`raw.githubusercontent.com`) is unreachable, bootstrap supports opt-in network profiles via ENV variables.

#### ENV controls

| Variable | Purpose | Default |
|---|---|---|
| `RW_BOOTSTRAP_FETCH_TOOL` | Fetch tool to use: `auto`, `curl`, or `wget` | `auto` |
| `RW_BOOTSTRAP_FETCH_FORCE_IPV4` | Force IPv4-only fetch (`-4`) | `1` (IPv4 by default) |
| `RW_BOOTSTRAP_FETCH_FORCE_IPV6` | Force IPv6-only fetch (`-6`) | `0` |
| `RW_BOOTSTRAP_FETCH_CURL_ARGS` | Extra curl arguments (e.g. `--resolve`, `--connect-timeout`) | (empty) |
| `RW_BOOTSTRAP_FETCH_WGET_ARGS` | Extra wget arguments (e.g. `--timeout`, `--tries`) | (empty) |
| `RW_BOOTSTRAP_FETCH_RETRIES` | Number of retry attempts per file | `3` |
| `RW_BOOTSTRAP_FETCH_RETRY_DELAY` | Delay between retries (seconds) | `2` |

By default curl uses `-4` (IPv4-only). For IPv6 use `--ipv6` or `RW_BOOTSTRAP_FETCH_FORCE_IPV6=1`.
For dual-stack (no `-4` or `-6`): `RW_BOOTSTRAP_FETCH_FORCE_IPV4=0`.

#### Typical launch profiles

**Normal** (standard launch without overrides):
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --dry-run
```

**Constrained IPv4 + DNS pin** (bypass unstable CDN/dual-stack):
```bash
RW_BOOTSTRAP_FETCH_CURL_ARGS="--resolve raw.githubusercontent.com:443:185.199.108.133 --connect-timeout 10 --retry 3" \
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --dry-run
```

**IPv6-only** (forced IPv6 mode):
```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --dry-run --ipv6
```

**Custom retry budget** (slow/unstable links):
```bash
RW_BOOTSTRAP_FETCH_RETRIES=5 RW_BOOTSTRAP_FETCH_RETRY_DELAY=3 \
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --dry-run
```

**wget-only** (curl blocked by firewall/DPI):
```bash
RW_BOOTSTRAP_FETCH_TOOL=wget RW_BOOTSTRAP_FETCH_WGET_ARGS="--timeout=15 --tries=3" \
sudo bash <(curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh) --dry-run
```

#### Fetch failure indication

On network failures the `BEFORE` report section contains:
- `fetch: status=failed` — explicit indication that payload was not downloaded
- `fetch-evidence: class=...; file=...; url=...; tool=...; tool_exit=...; attempts=...; strategy=...` — machine-readable diagnostics
- `APPLIED` records `apply-started: 0` and `detail=apply was not started because fetch/verify failed`
- `WHAT NEXT` emits deterministic rerun commands with current ENV control values

No server mutations — apply simply does not start.

### Publish on Windows

For Windows you can use the runner wrapper `scripts/publish.bat`, which delegates execution to `scripts/publish.sh` and returns the same exit code.

```bat
:: Dry-run publish
scripts\publish.bat ..\rw-node-optimize --dry-run

:: Publish with push
scripts\publish.bat ..\rw-node-optimize --push
```

### Modes

- `--yes` — non-interactive apply; bootstrap feeds confirmation only into the internal `optimize.sh` apply prompt.
- `--dry-run` — runs snapshot/diagnostics/report without mutating apply; `APPLIED` records `skipped`.
- `--speed <mbit>` — forwards shaping to the CAKE apply path.
- `--debug` — adds an extended `=== DEBUG ===` section at the end of stdout; does not change apply logic.
