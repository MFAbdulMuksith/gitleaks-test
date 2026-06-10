# Installing and Configuring Gitleaks

## 1. Version Policy

**Always pin Gitleaks to a specific version. Never use `latest`.**

Pinning to a specific version ensures:
- Identical behaviour across local machines, CI runners, and Docker containers
- Reproducible rule evaluation — new Gitleaks versions may add, remove, or change rules, which can introduce unexpected failures or silently miss secrets
- Controlled upgrades — you decide when to adopt new rules and can test them before rolling out

This guide pins to **v8.24.2**. To change the version, update the single constant in `scripts/gitleaks-scan.sh`:

```bash
GITLEAKS_VERSION="8.24.2"
```

---

## 2. Installing Gitleaks Manually (Linux / WSL2)

Download the pre-compiled binary from the GitHub releases page:

```bash
GITLEAKS_VERSION="8.24.2"

curl -sSL \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
  | tar -xz -C /usr/local/bin gitleaks

# Confirm the binary is on PATH
gitleaks version
# → v8.24.2
```

If you do not have write access to `/usr/local/bin`, install to `~/.local/bin`:

```bash
mkdir -p ~/.local/bin
curl -sSL \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
  | tar -xz -C ~/.local/bin gitleaks

# Add to PATH if not already present
export PATH="$HOME/.local/bin:$PATH"
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
```

---

## 3. Installing on macOS

```bash
GITLEAKS_VERSION="8.24.2"

curl -sSL \
  "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_darwin_arm64.tar.gz" \
  | tar -xz -C /usr/local/bin gitleaks

gitleaks version
```

Use `darwin_x64` instead of `darwin_arm64` on Intel Macs.

---

## 4. The Shared Scan Script

All three CI platforms (and local developer machines) use a single script: `scripts/gitleaks-scan.sh`.

This script:
1. Auto-installs Gitleaks v8.24.2 if the binary is not already on `PATH`
2. Reads `BASE_BRANCH` to determine the diff scan range
3. Strips the `refs/heads/` prefix that Azure Pipelines injects
4. Falls back to `main` when `BASE_BRANCH` is unset
5. Fetches the tip of the base branch so the git range resolves
6. Runs a diff scan: only commits on the current branch, not full history
7. Writes `results.sarif`
8. Exits 0 (no secrets) or 1 (secrets found)

```bash
#!/usr/bin/env bash
# =============================================================================
# scripts/gitleaks-scan.sh
#
# Portable Gitleaks diff scan — identical behaviour on every CI/CD platform
# and locally. Each platform's pipeline config calls:
#
#   BASE_BRANCH=<target> bash scripts/gitleaks-scan.sh
#
# Environment variables:
#   BASE_BRANCH        — branch to diff against (required for diff scan)
#                        Azure Pipelines may pass "refs/heads/main"; the
#                        "refs/heads/" prefix is stripped automatically.
#                        Falls back to "main" when unset (local runs).
#   GITLEAKS_VERSION   — binary version to auto-install (default: 8.24.2)
#   GITLEAKS_CONFIG    — config file path               (default: .gitleaks.toml)
#   GITLEAKS_REPORT    — SARIF output path              (default: results.sarif)
# =============================================================================
set -euo pipefail

GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.24.2}"
CONFIG="${GITLEAKS_CONFIG:-.gitleaks.toml}"
REPORT="${GITLEAKS_REPORT:-results.sarif}"
BASE_BRANCH="${BASE_BRANCH:-}"

# ── Install gitleaks if not already on PATH ──────────────────────────────────
if ! command -v gitleaks &>/dev/null; then
  echo "[gitleaks] not found — installing v${GITLEAKS_VERSION} ..."
  _tmp=$(mktemp -d)
  curl -sSL \
    "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" \
    | tar -xz -C "$_tmp" gitleaks
  export PATH="$_tmp:$PATH"
fi

# ── Print context so CI logs are easy to read ───────────────────────────────
echo "[gitleaks] version : $(gitleaks version)"
echo "[gitleaks] config  : $CONFIG"
echo "[gitleaks] report  : $REPORT"
echo

# ── Resolve base branch ──────────────────────────────────────────────────────
# Azure Pipelines passes $(System.PullRequest.TargetBranch) as "refs/heads/main".
# Strip the prefix so git range syntax works: origin/main..HEAD.
BASE_BRANCH="${BASE_BRANCH#refs/heads/}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# Ensure the base branch ref exists locally before building the range.
# --depth=1 is sufficient; we only need the tip commit for the diff boundary.
git fetch origin "${BASE_BRANCH}" --depth=1 2>/dev/null || true

echo "[gitleaks] scope   : diff vs origin/${BASE_BRANCH}"
echo

# ── Diff scan ────────────────────────────────────────────────────────────────
# --log-opts restricts the scan to commits reachable from HEAD but not from
# origin/<base>. Only secrets introduced on this branch are reported.
# --exit-code 1 fails the pipeline when secrets are found.
gitleaks git . \
  --log-opts="origin/${BASE_BRANCH}..HEAD" \
  --config        "$CONFIG" \
  --report-format sarif \
  --report-path   "$REPORT" \
  --exit-code 1
```

Save this as `scripts/gitleaks-scan.sh` and make it executable:

```bash
chmod +x scripts/gitleaks-scan.sh
```

---

## 5. Running the Script Locally

From the repository root:

```bash
# Diff scan vs main (default)
bash scripts/gitleaks-scan.sh

# Diff scan vs a specific branch
BASE_BRANCH=develop bash scripts/gitleaks-scan.sh

# Use a different Gitleaks version
GITLEAKS_VERSION="8.24.2" bash scripts/gitleaks-scan.sh

# Write the report to a custom path
GITLEAKS_REPORT=/tmp/my-scan.sarif bash scripts/gitleaks-scan.sh
```

---

## 6. Key Gitleaks Commands

| Command | Purpose |
|---------|---------|
| `gitleaks version` | Print installed version |
| `gitleaks git .` | Scan full git history of the current repository |
| `gitleaks git . --log-opts="origin/main..HEAD"` | Scan diff only (current branch vs `main`) |
| `gitleaks detect --source .` | Scan working directory files (not git history) |
| `gitleaks git . --no-color` | Suppress ANSI colour codes (useful in CI) |
| `gitleaks git . --verbose` | Show each rule as it is evaluated |

---

## 7. Key Flags Reference

| Flag | Default | Description |
|------|---------|-------------|
| `--config` | auto-detect | Path to `.gitleaks.toml` config file |
| `--report-format` | none | Output format: `sarif`, `json`, `csv`, `junit` |
| `--report-path` | none | Where to write the report file |
| `--exit-code` | `1` | Exit code when leaks are found |
| `--log-opts` | none | Git log options; used to restrict commit range |
| `--baseline-path` | none | JSON file of known findings to suppress |
| `--no-color` | false | Disable colour output |
| `--verbose` | false | Log each rule evaluation |
| `--redact` | false | Replace secret values with `REDACTED` in output |

---

## 8. Installing the Pre-Commit Hook (Optional, for Developers)

The repository includes `.pre-commit-config.yaml`, which runs Gitleaks on every `git commit`. This catches secrets before they are committed — earlier than the CI pipeline.

```yaml
repos:
  - repo: https://github.com/gitleaks/gitleaks
    rev: v8.24.2
    hooks:
      - id: gitleaks
        pass_filenames: false
```

Install:

```bash
pip install pre-commit
pre-commit install
```

The hook uses the same pinned version (v8.24.2). When a commit contains a secret, `git commit` fails with:

```
[ERROR] (gitleaks) secret detected: <rule-id> in <file>:<line>
```

To bypass the hook for a known-safe value, either add `#gitleaks:allow` to the line, or use `SKIP=gitleaks git commit`.

---

## 9. Verifying the Installation

Run a quick self-test from the repository root:

```bash
gitleaks version
# Expected: v8.24.2

gitleaks git . --config .gitleaks.toml --no-color
# Expected on a clean repo: exit code 0, "No leaks found"
# Expected on a repo with fake test secrets: exit code 1 with findings listed
```

If the binary is not on `PATH`, run the install step from Section 2 above.
