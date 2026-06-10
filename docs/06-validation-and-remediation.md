# Validation and Remediation

## Part 1 — Validating Pipeline Failure (Secrets Detected)

This test confirms that Stage 1 correctly blocks the pipeline when a secret is present.

### Step 1: Create a test branch

```bash
git checkout -b test/should-fail
```

### Step 2: Add an unsuppressed fake secret

Create `tests/fixtures/should-trigger.env` with content that will fire Gitleaks:

```bash
cat > tests/fixtures/should-trigger.env << 'EOF'
# FAKE CREDENTIAL — for pipeline failure testing only
# Do NOT merge this branch to main.

GITHUB_TOKEN=ghp_ABCDEFghijklmn1234567890abcdef1234
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE9
COMPANY_API_KEY_production1234567890abc
EOF
```

**Do not add `#gitleaks:allow`.** The finding must be unsuppressed for this test.

### Step 3: Commit and push

```bash
git add tests/fixtures/should-trigger.env
git commit -m "test: add unsuppressed fake secret to verify Stage 1 failure"
git push origin test/should-fail
```

### Step 4: Open a pull request or merge request

Open a PR (GitHub) / MR (GitLab) or let the push trigger run the pipeline (Azure).

### Step 5: Confirm expected results

| Stage | GitHub Actions | Azure Pipelines | GitLab CI/CD |
|-------|---------------|-----------------|--------------|
| Stage 1 — Gitleaks | Failed (red) | Failed (red) | Failed (red) |
| Stage 2 — Build | Skipped (grey) | Skipped (grey) | Skipped (grey) |
| Stage 3 — Test | Skipped (grey) | Skipped (grey) | Skipped (grey) |
| Stage 4 — Package | Skipped (grey) | Skipped (grey) | Skipped (grey) |
| Stage 5 — Deploy | Skipped (grey) | Skipped (grey) | Skipped (grey) |

**GitHub Actions specific:** a comment is posted on the PR listing the required remediation steps.

### Step 6: Read the CI log output

The scan script logs the following when a secret is found:

```
[gitleaks] version : v8.24.2
[gitleaks] config  : .gitleaks.toml
[gitleaks] report  : results.sarif
[gitleaks] scope   : diff vs origin/main

    ○
    │╲
    │ ○
    ○ ░
    ░    gitleaks

INF scanning ...
10:23AM WRN leaks found: 3
    Finding:     ghp_ABCDEFghijklmn1234567890abcdef1234
    Secret:      ghp_ABCDEFghijklmn1234567890abcdef1234
    RuleID:      github-pat
    Entropy:     3.84
    File:        tests/fixtures/should-trigger.env
    Line:        4
    Commit:      a1b2c3d4...
    Author:      Your Name
    ...

Error: exit status 1
```

Exit code 1 causes the CI platform to mark the job/stage as failed and skip the remainder.

### Step 7: Download the SARIF report

**GitHub Actions:**
Security → Code scanning alerts → filter by "gitleaks" to view all findings.

**Azure Pipelines:**
Pipeline run → Artifacts → `gitleaks-report` → download `results.sarif`.

**GitLab CI/CD:**
Pipeline → `gitleaks` job → Artifacts → Download → `results.sarif`.

---

## Part 2 — Validating a Clean Run (No Secrets)

This test confirms that the pipeline passes end-to-end when no secrets are present.

### Step 1: Create a clean branch

```bash
git checkout -b test/should-pass
```

### Step 2: Make a change with no secrets

```bash
echo "# No secrets here" >> src/app.py
git add src/app.py
git commit -m "test: clean change to verify all 5 stages pass"
git push origin test/should-pass
```

### Step 3: Confirm expected results

| Stage | Expected result |
|-------|----------------|
| Stage 1 — Gitleaks | Passed (green) |
| Stage 2 — Build | Passed (green) |
| Stage 3 — Test | Passed (green) |
| Stage 4 — Package | Passed (green) |
| Stage 5 — Deploy | Passed (green) |

**CI log output on success:**

```
[gitleaks] version : v8.24.2
[gitleaks] config  : .gitleaks.toml
[gitleaks] report  : results.sarif
[gitleaks] scope   : diff vs origin/main

    ○
    │╲
    │ ○
    ○ ░
    ░    gitleaks

INF scanning ...
INF no leaks found
```

Exit code 0. All downstream stages proceed normally.

---

## Part 3 — Remediation: Real Secret Found

If Stage 1 finds a real secret (not a false positive), follow these steps **in order**. Do not skip Step 1.

---

### Step 1: Rotate the exposed credential immediately

Assume the secret has been compromised from the moment it was committed to git — not from when the CI scan ran. Revoke the existing credential and issue a new one before doing anything else.

| Credential type | Where to rotate |
|----------------|----------------|
| GitHub PAT | GitHub → Settings → Developer settings → Personal access tokens → Delete token |
| GitHub Actions secret | Repository → Settings → Secrets and variables → Actions → Update |
| AWS access key | AWS Console → IAM → Users → Security credentials → Deactivate + create new |
| Azure client secret | Azure Portal → Azure Active Directory → App registrations → Certificates & secrets → New secret |
| GCP service account key | GCP Console → IAM & Admin → Service accounts → Keys → Add key |
| Stripe API key | Stripe Dashboard → Developers → API keys → Roll key |
| Twilio auth token | Twilio Console → Account → Auth tokens → Request secondary + promote |
| Generic API key | Consult the issuing service's security documentation |

After rotating, update all pipelines, deployment environments, and team members who use the credential.

---

### Step 2: Remove the secret from git history

The commit containing the secret must be purged from the repository's entire history. Simply deleting the file and committing is not enough — the secret remains visible in `git log`.

**Install `git filter-repo`:**

```bash
pip install git-filter-repo
# or: brew install git-filter-repo (macOS)
# Verify: git filter-repo --version
```

**Option A — Remove the entire file from all history:**

Use this when the entire file contained secrets and should not exist in history.

```bash
# Replace <path-to-file> with the actual file path, e.g. config/secrets.env
git filter-repo --path <path-to-file> --invert-paths
```

**Option B — Replace the secret value in all commits:**

Use this when only part of the file was sensitive and the rest should be preserved.

```bash
# Create a replacements file
echo "ghp_ABCDEFghijklmn1234567890abcdef1234==>REDACTED" > /tmp/replacements.txt

git filter-repo --replace-text /tmp/replacements.txt
```

**Option C — Remove a directory entirely:**

```bash
git filter-repo --path config/secrets/ --invert-paths
```

**Force-push to all remotes and branches:**

```bash
# Coordinate with your team before running this — it rewrites history
git remote add origin <remote-url>    # if filter-repo removed the remote
git push origin --force --all
git push origin --force --tags
```

> **Warning:** `git filter-repo` rewrites commit SHAs across the entire history. All team members must re-clone or run `git fetch --all && git reset --hard origin/<branch>` after the force-push. Any open PRs or MRs against affected branches must be rebased or recreated.

---

### Step 3: Verify the secret is gone from history

Run a full local scan after the rewrite:

```bash
gitleaks git . --config .gitleaks.toml --no-color
```

If it exits 0, the secret is no longer in any commit in the local history.

Also verify on the remote by re-cloning:

```bash
git clone <remote-url> /tmp/verify-clean
gitleaks git /tmp/verify-clean --config /tmp/verify-clean/.gitleaks.toml --no-color
```

---

### Step 4: Update pipeline secrets and environment configuration

After rotating the credential, update every location that referenced the old value:

- GitHub Actions secrets
- Azure Pipelines variable groups / library secrets
- GitLab CI/CD variables
- Kubernetes secrets / config maps
- Terraform / Vault / AWS Secrets Manager entries
- `.env` files on all deployment servers (if applicable)
- Any team documentation that referenced the old key

---

## Part 4 — Handling False Positives

If Gitleaks reports a finding that is a known-safe value (not a real secret), choose the appropriate suppression technique and apply it before re-running the pipeline.

### Decision tree

```
Finding appears in CI
        │
        ▼
Is this a real secret?
  ├── YES → Part 3: Rotate → filter-repo → verify clean
  └── NO (false positive)
        │
        ▼
    Can you edit the source line?
      ├── YES → Technique 1: add #gitleaks:allow to the line
      └── NO (committed history, uneditable line)
            │
            ▼
        Is it a recurring pattern across many files?
          ├── YES (entire directory) ──────────────→ Technique 3: path in [[rules.allowlists]]
          ├── YES (naming convention, e.g. "test_") → Technique 4: stopword in [[rules.allowlists]]
          ├── YES (context on the same line, e.g. localhost) → Technique 5: regexTarget="line"
          └── NO (single finding in history) ──────→ Technique 2: fingerprint in .gitleaksignore
```

---

### Applying Technique 1: Inline `#gitleaks:allow`

Edit the source line and add the comment:

```bash
GITHUB_TOKEN=ghp_example_not_real_value  #gitleaks:allow
```

Commit and push. The pipeline will pass on the next run.

---

### Applying Technique 2: `.gitleaksignore` Fingerprint

Run a full history scan to collect fingerprints:

```bash
gitleaks git . \
  --config .gitleaks.toml \
  --report-format json \
  --report-path /tmp/findings.json \
  --no-color

# Review the findings
jq -r '.[] | "[\(.RuleID)] \(.File):\(.StartLine) — \(.Secret[0:20])..."' /tmp/findings.json
```

Add only the false-positive fingerprints to `.gitleaksignore`:

```bash
# Append a specific fingerprint (copy from the JSON output)
echo "abc123def:tests/fixtures/custom-rules-test.env:internal-jwt-secret:34  # fake JWT demo" \
  >> .gitleaksignore

git add .gitleaksignore
git commit -m "chore: suppress false positive — fake JWT in test fixture"
git push
```

---

### Applying Technique 3: Path Pattern

Edit `.gitleaks.toml` and add a per-rule path allowlist:

```toml
[[rules]]
id = "database-connection-string"
# ... existing rule definition ...

  [[rules.allowlists]]
  description = "Exclude test fixture files"
  paths       = ['''(^|\/)tests\/fixtures\/.*''']
```

```bash
git add .gitleaks.toml
git commit -m "chore: exclude test fixtures from database-connection-string rule"
git push
```

---

### Applying Technique 4: Stopword

Edit `.gitleaks.toml` and add a stopword to the relevant rule:

```toml
  [[rules.allowlists]]
  description = "Suppress test and example values"
  stopwords   = ["changeme", "example", "placeholder", "test_"]
```

```bash
git add .gitleaks.toml
git commit -m "chore: add stopwords to suppress test-value false positives"
git push
```

---

### Applying Technique 5: Line Regex

Edit `.gitleaks.toml` and add a line-regex allowlist:

```toml
  [[rules.allowlists]]
  description = "Suppress URLs with local/test hostnames"
  condition   = "OR"
  regexTarget = "line"
  regexes     = ['localhost', '127\.0\.0\.1', '\.test\.', '\.local$']
```

```bash
git add .gitleaks.toml
git commit -m "chore: suppress local-hostname database URLs"
git push
```

---

## Part 5 — Rollout Checklist

Before rolling out this implementation to additional repositories, confirm all of the following:

### Pipeline failure validation
- [ ] Stage 1 fails and pipeline stops when an unsuppressed secret is pushed
- [ ] Stages 2–5 do not execute when Stage 1 fails
- [ ] Stage 1 passes and all stages execute when the branch is clean
- [ ] SARIF report is saved and accessible on all three platforms

### Configuration validation
- [ ] `.gitleaks.toml` is at the repository root
- [ ] `[allowlist]` paths exclude scan output files (`results.sarif`, etc.)
- [ ] `[allowlist]` paths exclude dependency lock files
- [ ] `disabledRules = ["generic-api-key"]` prevents duplicate findings
- [ ] Custom rules have `keywords` pre-filters for performance
- [ ] Stopword allowlists cover known test-value patterns

### Version and scan scope validation
- [ ] Gitleaks version is pinned (v8.24.2) — not `latest`
- [ ] `fetch-depth: 0` / `fetchDepth: 0` / `GIT_DEPTH: 0` is set on all platforms
- [ ] Diff scan is confirmed: `--log-opts="origin/<base>..HEAD"` appears in CI logs
- [ ] Full history is not re-scanned on every run

### Suppression hygiene
- [ ] All fake secrets in test fixtures are suppressed using one of the five techniques
- [ ] `.gitleaksignore` entries include a comment explaining each suppression
- [ ] No `#gitleaks:allow` on lines containing values that might ever become real
- [ ] Pre-commit hook is documented for developers

### Remediation readiness
- [ ] Team knows the rotation procedure for each credential type used in this repo
- [ ] `git filter-repo` is installed and tested
- [ ] Escalation path is documented (who to notify when a real secret is found)
