# Gitleaks TOML Configuration

## 1. Should You Use a Custom `.gitleaks.toml`?

**Yes — for any non-trivial repository, a custom `.gitleaks.toml` is strongly recommended.**

Without a config file, Gitleaks runs with all 150+ default rules and no allowlists. In practice this means:

| Problem | Example |
|---------|---------|
| **False positives from lock files** | `package-lock.json` and `go.sum` contain deterministic hashes that trigger entropy-based rules |
| **Duplicate findings** | A GitHub PAT matches both `github-pat` (specific) and `generic-api-key` (broad), producing two findings for the same line |
| **Test fixture noise** | Database connection strings in test files (e.g. `postgres://user:pass@localhost`) fire the same rules as production credentials |
| **Documentation examples** | Example credentials in README files and inline comments block the pipeline |
| **Scan output files** | If `results.sarif` is ever committed, Gitleaks will scan its own output and report findings from the previous scan |

A well-maintained `.gitleaks.toml` eliminates these problems without disabling legitimate secret detection.

---

## 2. Placement and Auto-Detection

Place `.gitleaks.toml` in the **repository root**.

All three CI platforms auto-detect it through the shared scan script, which passes `--config .gitleaks.toml` explicitly:

```bash
gitleaks git . \
  --log-opts="origin/${BASE_BRANCH}..HEAD" \
  --config .gitleaks.toml \           # ← explicit path
  ...
```

| Platform | How the config is found |
|----------|------------------------|
| GitHub Actions | `scripts/gitleaks-scan.sh` passes `--config .gitleaks.toml`; the working directory is the repo root |
| Azure Pipelines | Same — `checkout: self` sets the working directory to the repo root |
| GitLab CI/CD | Same — the runner clones the repo and runs from the root |

No additional configuration is needed on any platform.

---

## 3. The Complete Config File

This is the current `.gitleaks.toml` used in this repository. Each section is explained below.

```toml
title = "Gitleaks configuration"

# =============================================================================
# EXTEND DEFAULT RULESET
# =============================================================================
[extend]
useDefault = true
disabledRules = ["generic-api-key"]

# =============================================================================
# CUSTOM RULES
# =============================================================================

[[rules]]
id          = "company-api-key"
description = "Company internal API key (COMPANY_API_KEY_ prefix)"
regex       = '''COMPANY_API_KEY_[A-Za-z0-9]{15,}'''
keywords    = ["COMPANY_API_KEY"]
tags        = ["custom", "company"]

  [[rules.allowlists]]
  description = "Suppress placeholder and test values"
  stopwords   = ["changeme", "placeholder", "example", "test_key", "dummy"]

[[rules]]
id          = "internal-jwt-secret"
description = "JWT signing secret assigned to a known variable name"
regex       = '''(?i)(jwt[_-]?secret|signing[_-]?key)\s*[=:]\s*["']?[A-Za-z0-9+/=_\-]{20,}'''
keywords    = ["jwt_secret", "jwt-secret", "signing_key", "signingkey"]
tags        = ["custom", "jwt"]

[[rules]]
id          = "database-connection-string"
description = "Database connection string with an embedded password"
regex       = '''(?i)(postgres|mysql|mongodb|mssql):\/\/[^:]+:[^@]{8,}@'''
keywords    = ["postgres://", "mysql://", "mongodb://", "mssql://"]
tags        = ["custom", "database"]

  [[rules.allowlists]]
  description = "Exclude Python test files — assertion strings, not real credentials"
  paths       = ['''(^|\/)tests\/.*\.py$''']

  [[rules.allowlists]]
  description = "Suppress local and test database URLs"
  condition   = "OR"
  regexTarget = "line"
  regexes     = ['localhost', '127\.0\.0\.1', 'test_password', '0\.0\.0\.0']

# =============================================================================
# GLOBAL ALLOWLIST
# =============================================================================
[allowlist]
description = "Global path and value exclusions"

paths = [
  '''(^|\/)results\.(json|sarif)$''',
  '''(^|\/)report\.(json|csv|xml|sarif|junit)$''',
  '''(^|\/)git-report\.json$''',
  '''(^|\/)baseline\.json$''',
  '''(^|\/)new-findings\.json$''',
  '''(^|\/)\.(gitleaks)?ignore$''',
  '''(^|\/)package-lock\.json$''',
  '''(^|\/)yarn\.lock$''',
  '''(^|\/)Gemfile\.lock$''',
  '''(^|\/)poetry\.lock$''',
  '''(^|\/)go\.sum$''',
  '''(^|\/)composer\.lock$''',
  '''(^|\/)\.claude\/''',
]

stopwords = [
  "example",
  "EXAMPLE",
  "placeholder",
  "PLACEHOLDER",
  "changeme",
  "CHANGEME",
  "your-secret-here",
  "insert-secret-here",
  "todo",
  "fixme",
]
```

---

## 4. Section-by-Section Reference

### `[extend]`

```toml
[extend]
useDefault    = true
disabledRules = ["generic-api-key"]
```

- **`useDefault = true`** — inherits all built-in rules. Gitleaks ships with 150+ rules covering AWS, Azure, GCP, GitHub, GitLab, Stripe, Twilio, Slack, HashiCorp Vault, and many others. Setting this to `false` means you are responsible for defining every rule yourself.

- **`disabledRules`** — suppresses specific built-in rules by their ID. `generic-api-key` fires on any high-entropy assignment matching patterns like `KEY=...`, `TOKEN=...`, `SECRET=...`. It produces a second finding on every line already caught by a more specific rule (e.g. `github-pat`). Disabling it removes the duplicate without losing detection — the specific rule still fires.

---

### `[[rules]]`

Each rule must have:

| Field | Required | Description |
|-------|----------|-------------|
| `id` | yes | Unique identifier. Used in reports, fingerprints, and `disabledRules`. |
| `description` | yes | Human-readable explanation shown in findings. |
| `regex` | yes | Go-flavoured regular expression. Use raw string literals (`'''...'``) to avoid double-escaping backslashes. |
| `keywords` | recommended | Pre-filter strings. The regex is only evaluated if at least one keyword appears in the content. Significantly improves scan performance on large repos. |
| `tags` | optional | Free-form labels for filtering (`--include-rules`, reporting). |
| `secretGroup` | optional | Capture group number to extract as the secret value. Affects stopword matching — the stopword is checked against the captured group, not the full match. |

---

### `[[rules.allowlists]]`

Per-rule suppression. Multiple `[[rules.allowlists]]` blocks can be added to a single rule (note the double brackets — this is a TOML array of tables).

**Stopwords:**
```toml
[[rules.allowlists]]
stopwords = ["changeme", "placeholder"]
```
Gitleaks extracts the secret value (the matched substring, or the capture group if `secretGroup` is set) and checks whether any stopword is a case-insensitive substring of it. If a stopword matches, the finding is suppressed.

**Path patterns:**
```toml
[[rules.allowlists]]
paths = ['''(^|\/)tests\/.*\.py$''']
```
If the file path matches any of these Go regexes, the rule is not evaluated for that file. This is more efficient than a stopword because the file is skipped entirely.

**Line regex:**
```toml
[[rules.allowlists]]
condition   = "OR"
regexTarget = "line"
regexes     = ['localhost', '127\.0\.0\.1']
```
`regexTarget = "line"` evaluates the entire source line, not just the matched substring. This allows you to suppress a finding based on surrounding context — for example, a database URL that includes `localhost` is never a production credential. `condition = "OR"` means the finding is suppressed if any regex matches.

---

### `[allowlist]` (global)

Applied to **every rule** across **every file**.

**`paths`** — regex patterns matched against the relative file path. Matching files are excluded entirely from all rule evaluation. Use this for:
- Scan output files (`results.sarif`) — the scanner must not scan its own output
- The `.gitleaksignore` file — it contains fingerprint strings that look like secrets
- Dependency lock files — contain deterministic hashes that trigger entropy rules
- Local tooling directories (`.claude/`) — contain IDE state, not project secrets

**`stopwords`** — applied to the extracted secret value of any finding from any rule. Suppressions here are broad — prefer per-rule stopwords when specificity matters.

---

## 5. Version Note: `[allowlist]` vs `[[allowlists]]`

| Syntax | Available in |
|--------|-------------|
| `[allowlist]` (singular) | v8.24.x and earlier |
| `[[allowlists]]` (plural, array) | v8.25.0 and later |

If you are running v8.24.2, use `[allowlist]`. Using `[[allowlists]]` on v8.24.x is **silently ignored** — global path exclusions will not apply and findings will reappear with no error message. Do not upgrade the syntax until you upgrade the binary.

---

## 6. Adding Rules for Your Organisation

To add a rule matching your organisation's secret format, follow this template:

```toml
[[rules]]
id          = "acme-service-token"
description = "ACME Corp service token (ACME_TOK_ prefix)"
regex       = '''ACME_TOK_[A-Za-z0-9]{20,}'''
keywords    = ["ACME_TOK_"]
tags        = ["custom", "acme"]

  [[rules.allowlists]]
  description = "Suppress test and example values"
  stopwords   = ["example", "test", "placeholder", "changeme"]
```

Guidelines:
- Make the regex specific enough that it does not double-match values already caught by a default rule
- Always include a `keywords` pre-filter using a fixed prefix that must appear in the content
- Always add a stopword allowlist for known test value patterns
- Test the regex locally with `gitleaks detect --source .` before committing

---

## 7. Testing the Configuration

Run a full scan from the repository root to verify the configuration is applied correctly:

```bash
# Full history scan (detects all existing findings, including suppressed ones)
gitleaks git . --config .gitleaks.toml --no-color

# Diff scan only (what CI runs)
BASE_BRANCH=main bash scripts/gitleaks-scan.sh

# Verbose output — shows each rule as it is evaluated
gitleaks git . --config .gitleaks.toml --verbose --no-color 2>&1 | head -50
```

Expected output on a clean repository:

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

5:10PM INF scanning...
5:10PM INF no leaks found
```
