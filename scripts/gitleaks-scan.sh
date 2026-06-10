#!/usr/bin/env bash
# =============================================================================
# scripts/gitleaks-scan.sh
#
# Portable Gitleaks scan — identical behaviour on every CI/CD platform
# and locally.  Each platform's pipeline config simply calls:
#
#   bash scripts/gitleaks-scan.sh
#
# Override defaults with environment variables:
#   GITLEAKS_VERSION   — binary version to auto-install (default: 8.24.2)
#   GITLEAKS_CONFIG    — config file path               (default: .gitleaks.toml)
#   GITLEAKS_REPORT    — SARIF output path              (default: results.sarif)
# =============================================================================
set -euo pipefail

GITLEAKS_VERSION="${GITLEAKS_VERSION:-8.24.2}"
CONFIG="${GITLEAKS_CONFIG:-.gitleaks.toml}"
REPORT="${GITLEAKS_REPORT:-results.sarif}"

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

# ── Scan full git history ────────────────────────────────────────────────────
# Exits 0 (clean) or 1 (secrets found).  The CI platform treats exit 1 as a
# build failure and stops downstream jobs automatically.
gitleaks git . \
  --config  "$CONFIG" \
  --report-format sarif \
  --report-path   "$REPORT"
