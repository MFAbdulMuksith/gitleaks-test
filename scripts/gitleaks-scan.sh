#!/usr/bin/env bash
# =============================================================================
# scripts/gitleaks-scan.sh
#
# Portable Gitleaks diff scan — identical behaviour on every CI/CD platform
# and locally.  Each platform's pipeline config calls:
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
