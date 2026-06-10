# Pipeline Configuration

## 1. Stage Order

All three platforms implement the same five-stage pipeline. Stage 1 is a hard security gate: if Gitleaks detects any secret, the pipeline fails immediately and Stages 2–5 do not execute.

```
┌─────────────────────────────────────────────────────────┐
│  Stage 1 → Gitleaks secret scan   ← hard gate           │
│  Stage 2 → Build                  ← skipped if 1 fails  │
│  Stage 3 → Test                   ← skipped if 2 fails  │
│  Stage 4 → Package                ← skipped if 3 fails  │
│  Stage 5 → Deploy                 ← skipped if 4 fails  │
└─────────────────────────────────────────────────────────┘
```

---

## 2. Shared Scan Script

All three platforms call a single shared script: `scripts/gitleaks-scan.sh`.

**Why a shared script?**
- One version pin (`GITLEAKS_VERSION="8.24.2"`) to maintain
- Identical diff-scan logic on every platform
- Local developers use the same command as CI
- Platform-specific logic is limited to passing the correct `BASE_BRANCH` variable

**How the diff scan works:**

```
git log --log-opts="origin/<base>..HEAD"
              │
              └── commits reachable from HEAD
                  that are NOT reachable from origin/<base>
                  = commits introduced on this branch only
```

Only secrets introduced on the current branch are reported. Secrets in `main`'s history that were already present before this branch was created are not re-reported on every run.

**Complete script (`scripts/gitleaks-scan.sh`):**

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

---

## 3. GitHub Actions — `.github/workflows/pipeline.yml`

**Gating mechanism:**

```
gitleaks ──needs──▶ build ──needs──▶ test ──needs──▶ package ──needs──▶ deploy
```

When `gitleaks` fails, GitHub marks it as a failed job. Every downstream job declares `needs:` pointing back through the chain. GitHub automatically skips any job whose `needs:` dependency failed or was skipped — no explicit `if:` conditions are required.

`BASE_BRANCH` is set to `github.event.repository.default_branch`, which is available on both `push` and `pull_request` events.

**Complete YAML:**

```yaml
name: CI/CD Pipeline

# ── TRIGGERS ──────────────────────────────────────────────────────────────────
# push     — every branch push triggers a full pipeline run.
# pull_request — PRs targeting main/master run the security gate before merge.
# workflow_dispatch — manual trigger for on-demand scans or re-runs.
on:
  push:
    branches: ['**']
  pull_request:
    branches: [main, master]
  workflow_dispatch:

jobs:

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 1 — GITLEAKS SECRET SCAN
  #
  # Runs first on every trigger. Has no `needs:` so it is never skipped.
  # All downstream jobs declare `needs: [gitleaks]` (directly or transitively).
  # ════════════════════════════════════════════════════════════════════════════
  gitleaks:
    name: 'Stage 1 — Gitleaks secret scan'
    runs-on: ubuntu-latest
    permissions:
      contents: read         # required to checkout the repository
      security-events: write # required to upload SARIF to the Security tab

    steps:
      # fetch-depth: 0 gives gitleaks the full commit history.
      # A shallow clone (the default) would prevent the diff range from resolving.
      - name: Checkout full history
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      # BASE_BRANCH scopes the scan to commits on this branch that are not yet
      # on the default branch — only new secrets are reported, not history.
      - name: Run Gitleaks
        env:
          BASE_BRANCH: ${{ github.event.repository.default_branch }}
        run: bash scripts/gitleaks-scan.sh

      # if: always() ensures the report is uploaded even when the scan failed.
      # Without this, a failed scan produces no findings in the Security tab.
      - name: Upload SARIF to Security tab
        if: always()
        uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: results.sarif
          category: gitleaks

      # Post a descriptive comment on the PR when secrets are detected.
      # failure() is true only when the Run Gitleaks step failed.
      - name: Comment on PR when secrets found
        if: failure() && github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner:        context.repo.owner,
              repo:         context.repo.repo,
              body: [
                '## Gitleaks detected secrets in this PR',
                '',
                'The security scan failed. Stages 2–5 will not run.',
                '',
                '**Required actions before this PR can merge:**',
                '1. Rotate the exposed credential immediately.',
                '2. Remove it from Git history using `git filter-repo`.',
                '3. If this is a false positive, add the fingerprint to `.gitleaksignore`.',
                '',
                'See the **Security → Code scanning alerts** tab for full details.'
              ].join('\n')
            })

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 2 — BUILD
  # needs: [gitleaks] — only starts when Stage 1 exits 0 (no secrets found).
  # ════════════════════════════════════════════════════════════════════════════
  build:
    name: 'Stage 2 — Build'
    runs-on: ubuntu-latest
    needs: [gitleaks]
    steps:
      - uses: actions/checkout@v4
      - name: Build
        run: echo "Replace with real build commands"

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 3 — TEST
  # ════════════════════════════════════════════════════════════════════════════
  test:
    name: 'Stage 3 — Test'
    runs-on: ubuntu-latest
    needs: [build]
    steps:
      - uses: actions/checkout@v4
      - name: Test
        run: echo "Replace with real test commands"

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 4 — PACKAGE
  # ════════════════════════════════════════════════════════════════════════════
  package:
    name: 'Stage 4 — Package'
    runs-on: ubuntu-latest
    needs: [test]
    steps:
      - uses: actions/checkout@v4
      - name: Package
        run: echo "Replace with real package commands"

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 5 — DEPLOY
  # ════════════════════════════════════════════════════════════════════════════
  deploy:
    name: 'Stage 5 — Deploy'
    runs-on: ubuntu-latest
    needs: [package]
    steps:
      - uses: actions/checkout@v4
      - name: Deploy
        run: echo "Replace with real deploy commands"
```

---

## 4. Azure Pipelines — `azure-pipelines.yml`

**Gating mechanism:**

```
Security ──dependsOn──▶ Build ──dependsOn──▶ Test ──dependsOn──▶ Package ──dependsOn──▶ Deploy
condition:              condition:            condition:           condition:
succeeded()             succeeded()           succeeded()          succeeded()
```

When Security fails, Azure evaluates `condition: succeeded()` on Build → `false` → Build is **Skipped**. Skipped counts as a non-success for the next `succeeded()` check, so the entire chain collapses automatically.

**`$(System.PullRequest.TargetBranch)` behaviour:**
- PR build → value is `refs/heads/main` → script strips prefix → scans `origin/main..HEAD`
- Push build → value is empty → script falls back to `main` → scans `origin/main..HEAD`

**Complete YAML:**

```yaml
# ── TRIGGERS ─────────────────────────────────────────────────────────────────
# trigger — runs the pipeline on every branch push.
# pr      — runs the pipeline for every pull request.
trigger:
  branches:
    include:
      - '*'
pr:
  branches:
    include:
      - '*'

stages:

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 1 — GITLEAKS SECRET SCAN
  #
  # No dependsOn — this stage runs unconditionally on every trigger.
  # scripts/gitleaks-scan.sh auto-installs gitleaks v8.24.2, fetches the
  # base branch, and scans only the diff (origin/<base>..HEAD).
  # Exit 0 → clean. Exit 1 → secrets found → Azure marks stage Failed.
  # ════════════════════════════════════════════════════════════════════════════
  - stage: Security
    displayName: 'Stage 1 — Gitleaks secret scan'
    jobs:
      - job: Gitleaks
        displayName: Gitleaks
        pool:
          vmImage: ubuntu-latest
        steps:
          # fetchDepth: 0 provides the full commit history so the diff range
          # origin/<base>..HEAD resolves correctly against all branch commits.
          - checkout: self
            fetchDepth: 0

          # BASE_BRANCH is set to the PR target branch for pull request builds.
          # On push (non-PR) builds, $(System.PullRequest.TargetBranch) is empty;
          # gitleaks-scan.sh falls back to "main" automatically.
          - script: bash scripts/gitleaks-scan.sh
            displayName: Run Gitleaks
            env:
              BASE_BRANCH: $(System.PullRequest.TargetBranch)

          # condition: always() ensures the SARIF report is saved even when
          # the scan step above failed (i.e., secrets were found).
          - task: PublishBuildArtifacts@1
            displayName: Save SARIF report
            inputs:
              pathToPublish: results.sarif
              artifactName:  gitleaks-report
            condition: always()

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 2 — BUILD
  # dependsOn: Security + condition: succeeded() — only runs when Stage 1 passed.
  # ════════════════════════════════════════════════════════════════════════════
  - stage: Build
    displayName: 'Stage 2 — Build'
    dependsOn: Security
    condition: succeeded()
    jobs:
      - job: Build
        pool:
          vmImage: ubuntu-latest
        steps:
          - checkout: self
          - script: echo "Replace with real build commands"
            displayName: Build

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 3 — TEST
  # ════════════════════════════════════════════════════════════════════════════
  - stage: Test
    displayName: 'Stage 3 — Test'
    dependsOn: Build
    condition: succeeded()
    jobs:
      - job: Test
        pool:
          vmImage: ubuntu-latest
        steps:
          - checkout: self
          - script: echo "Replace with real test commands"
            displayName: Test

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 4 — PACKAGE
  # ════════════════════════════════════════════════════════════════════════════
  - stage: Package
    displayName: 'Stage 4 — Package'
    dependsOn: Test
    condition: succeeded()
    jobs:
      - job: Package
        pool:
          vmImage: ubuntu-latest
        steps:
          - checkout: self
          - script: echo "Replace with real package commands"
            displayName: Package

  # ════════════════════════════════════════════════════════════════════════════
  # STAGE 5 — DEPLOY
  # ════════════════════════════════════════════════════════════════════════════
  - stage: Deploy
    displayName: 'Stage 5 — Deploy'
    dependsOn: Package
    condition: succeeded()
    jobs:
      - job: Deploy
        pool:
          vmImage: ubuntu-latest
        steps:
          - checkout: self
          - script: echo "Replace with real deploy commands"
            displayName: Deploy
```

---

## 5. GitLab CI/CD — `.gitlab-ci.yml`

**Gating mechanism:**

The `stages:` list defines execution order. GitLab runs each stage only when all jobs in the previous stage have passed (default `when: on_success`). No explicit `needs:` or `condition:` is required. If `gitleaks` fails, GitLab marks the pipeline as **Failed** and all subsequent stages are skipped automatically.

`BASE_BRANCH` is set to `$CI_DEFAULT_BRANCH`, which GitLab provides on both push and merge request pipelines.

**Complete YAML:**

```yaml
# ── STAGE ORDER ───────────────────────────────────────────────────────────────
# GitLab processes this list top-to-bottom. Each stage is a hard gate for the
# next. Adding a stage here is all that is needed to place it in the chain.
stages:
  - security   # Stage 1 — always runs first; gates everything below
  - build      # Stage 2 — skipped if security fails
  - test       # Stage 3 — skipped if build fails
  - package    # Stage 4 — skipped if test fails
  - deploy     # Stage 5 — skipped if package fails

# ════════════════════════════════════════════════════════════════════════════
# STAGE 1 — GITLEAKS SECRET SCAN
#
# GIT_DEPTH: 0 provides gitleaks with the full commit history so the diff
# range origin/<base>..HEAD resolves correctly against all branch commits.
#
# BASE_BRANCH passes $CI_DEFAULT_BRANCH to gitleaks-scan.sh, which scans
# only the commits introduced on this branch (diff scan, not full history).
#
# before_script installs curl, required by gitleaks-scan.sh on a clean
# ubuntu:22.04 runner. Omit if your runner image already has curl.
#
# Exit 0 → clean. Exit 1 → secrets found → GitLab marks the job Failed.
# ════════════════════════════════════════════════════════════════════════════
gitleaks:
  stage: security
  image: ubuntu:22.04
  variables:
    GIT_DEPTH: 0
    BASE_BRANCH: $CI_DEFAULT_BRANCH
  before_script:
    - apt-get update -qq && apt-get install -y -qq curl
  script:
    - bash scripts/gitleaks-scan.sh
  artifacts:
    # when: always — save results.sarif even when the scan fails.
    # Without this, a failing job would produce no downloadable report.
    when: always
    paths:
      - results.sarif
    expire_in: 30 days

# ════════════════════════════════════════════════════════════════════════════
# STAGE 2 — BUILD
# ════════════════════════════════════════════════════════════════════════════
build:
  stage: build
  image: ubuntu:22.04
  script:
    - echo "Replace with real build commands"

# ════════════════════════════════════════════════════════════════════════════
# STAGE 3 — TEST
# ════════════════════════════════════════════════════════════════════════════
test:
  stage: test
  image: ubuntu:22.04
  script:
    - echo "Replace with real test commands"

# ════════════════════════════════════════════════════════════════════════════
# STAGE 4 — PACKAGE
# ════════════════════════════════════════════════════════════════════════════
package:
  stage: package
  image: ubuntu:22.04
  script:
    - echo "Replace with real package commands"

# ════════════════════════════════════════════════════════════════════════════
# STAGE 5 — DEPLOY
# ════════════════════════════════════════════════════════════════════════════
deploy:
  stage: deploy
  image: ubuntu:22.04
  script:
    - echo "Replace with real deploy commands"
```

---

## 6. Consistency Table

| Behaviour | GitHub Actions | Azure Pipelines | GitLab CI/CD |
|---|---|---|---|
| Trigger — push | all branches (`'**'`) | all branches (`'*'`) | all branches (default) |
| Trigger — PR/MR | `pull_request` on `main`, `master` | `pr` on all branches | merge request (default) |
| Manual trigger | `workflow_dispatch` | not configured | not configured |
| Full history fetch | `fetch-depth: 0` | `fetchDepth: 0` | `GIT_DEPTH: 0` |
| Base branch variable | `github.event.repository.default_branch` | `System.PullRequest.TargetBranch` | `CI_DEFAULT_BRANCH` |
| Variable on push build | always set (repo property) | empty → falls back to `main` | always set |
| Azure `refs/heads/` prefix | not applicable | stripped by script | not applicable |
| Scan scope | `origin/<default>..HEAD` | `origin/<target or main>..HEAD` | `origin/<default>..HEAD` |
| Exit code on leaks | `1` (explicit `--exit-code 1`) | `1` (explicit `--exit-code 1`) | `1` (explicit `--exit-code 1`) |
| Pipeline failure mechanism | `gitleaks` job fails → downstream `needs:` skipped | Security stage fails → `condition: succeeded()` = false | `gitleaks` job fails → subsequent stages skipped |
| Stage 1 runs unconditionally | yes — no `needs:` declared | yes — no `dependsOn` declared | yes — first in `stages:` list |
| Report saved on failure | yes — `if: always()` | yes — `condition: always()` | yes — `when: always` |
| Report format | SARIF → Security tab | SARIF → build artifact | SARIF → job artifact (30 days) |
| PR comment on failure | yes — via `actions/github-script` | not configured | not configured |
| Gitleaks version | 8.24.2 (pinned) | 8.24.2 (pinned) | 8.24.2 (pinned) |
| Config file | `.gitleaks.toml` (auto-detected) | `.gitleaks.toml` (auto-detected) | `.gitleaks.toml` (auto-detected) |
