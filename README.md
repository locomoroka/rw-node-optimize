# RemnaWave Node Optimize

Default bootstrap work directory: **`/opt/remnawave-tools/oneliner`**. Remote installs need **`sudo`** so that path can be created under `/opt`.

**Apply (non-interactive):**

```bash
curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh | sudo bash -s -- --yes
```

**Dry-run (no mutating apply):**

```bash
curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh | sudo bash -s -- --dry-run
```

Pass more arguments after `--` (for example `--speed 50`, `--debug`, `--ipv6`).

### Verified payload (download then run locally)

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
```

With `RW_BOOTSTRAP_WORKDIR` pointing at a writable directory you can run without `sudo`.

### Report

Successful runs print **BEFORE**, **APPLIED**, **AFTER**, **WHAT NEXT** in that order. `--debug` adds a **DEBUG** section after **WHAT NEXT**.

### Network / fetch tuning

| Variable | Purpose |
|---|---|
| `RW_BOOTSTRAP_FETCH_TOOL` | `auto`, `curl`, or `wget` |
| `RW_BOOTSTRAP_FETCH_FORCE_IPV4` | default `1` (IPv4-only curl `-4`) |
| `RW_BOOTSTRAP_FETCH_FORCE_IPV6` | set `1` with `--ipv6` for IPv6-only |
| `RW_BOOTSTRAP_FETCH_CURL_ARGS` | Extra curl arguments |
| `RW_BOOTSTRAP_FETCH_RETRIES` | Retries per file (default `3`) |

Example with DNS pin:

```bash
RW_BOOTSTRAP_FETCH_CURL_ARGS="--resolve raw.githubusercontent.com:443:185.199.108.133 --connect-timeout 10 --retry 3" \
curl -fsSL https://raw.githubusercontent.com/locomoroka/rw-node-optimize/main/scripts/optimize-bootstrap.sh | sudo bash -s -- --dry-run
```

### Publish from Windows

```bat
scripts\publish.bat ..\rw-node-optimize --dry-run
scripts\publish.bat ..\rw-node-optimize --push
```
