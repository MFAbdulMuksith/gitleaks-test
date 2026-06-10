# Test Secrets and Sample Files

## 1. Principles for Safe Test Secrets

When creating files to validate Gitleaks detection, follow these rules:

1. **Never use real credentials** — not even partially. Fake values must be entirely fabricated and structurally recognisable as fake.
2. **Label test files clearly** — use a header comment explaining the file's purpose and that all values are intentionally fake.
3. **Decide suppression before committing** — if the fake secret should not block the pipeline (e.g. it demonstrates a suppression technique), apply the suppression technique in the same or a prior commit.
4. **Use `#gitleaks:allow` for known-safe inline values** — the simplest suppression for one-off lines.
5. **Use `.gitleaksignore` for committed history** — when a fake secret was committed in a previous push and the commit cannot be rewritten.
6. **Delete pipeline-failure test files before merging** — branches used to validate pipeline failure should be closed, not merged into `main`.

---

## 2. The Five Suppression Techniques

Gitleaks provides five distinct suppression mechanisms. Use the right one for each context.

### Technique 1: Inline `#gitleaks:allow`

Append the comment to the line containing the fake secret. Gitleaks skips that exact line.

```bash
GITHUB_TOKEN=ghp_1234567890abcdef1234567890abcdef12345678  #gitleaks:allow
COMPANY_API_KEY_inlineSuppressDemo1234567890  #gitleaks:allow
```

**When to use:** a one-off value on a single line that is checked in and cannot be removed or restructured.

**Scope:** the single annotated line only.

---

### Technique 2: `.gitleaksignore` Fingerprint

Add the finding's unique fingerprint to `.gitleaksignore`. The fingerprint format depends on scan mode:

- `gitleaks git` scan: `<commitSHA>:<file>:<ruleID>:<line>`
- `gitleaks dir` scan: `<file>:<ruleID>:<line>`

**Generate fingerprints from a scan report:**

```bash
# Run a full scan and output JSON
gitleaks git . \
  --config .gitleaks.toml \
  --report-format json \
  --report-path /tmp/findings.json \
  --no-color

# Extract fingerprints in the correct format
jq -r '.[] | "\(.Fingerprint)  # \(.RuleID) — \(.File):\(.StartLine)"' \
  /tmp/findings.json >> .gitleaksignore

# Commit the updated .gitleaksignore
git add .gitleaksignore
git commit -m "chore: suppress false positive fingerprints"
```

**Example `.gitleaksignore` entry:**

```
# commit abc123 — intentional test fixture
abc123def456789012345678901234567890abcd:tests/fixtures/custom-rules-test.env:internal-jwt-secret:34
```

**When to use:** a fake secret committed in git history that cannot be rewritten (e.g. initial repo setup commits).

**Scope:** the exact commit + file + rule + line combination.

---

### Technique 3: Path-Based `[[rules.allowlists]]`

Add a per-rule path pattern to `.gitleaks.toml`. The rule is not evaluated for files whose path matches the pattern.

```toml
[[rules]]
id    = "database-connection-string"
# ... rule definition ...

  [[rules.allowlists]]
  description = "Exclude Python test files — assertion strings, not real credentials"
  paths       = ['''(^|\/)tests\/.*\.py$''']
```

**When to use:** an entire class of files (e.g. all test files in a directory) should be exempt from a specific rule. More efficient than stopwords because the file is skipped entirely.

**Scope:** all files matching the path pattern, for the specific rule only.

---

### Technique 4: Stopword in `[[rules.allowlists]]`

Gitleaks extracts the matched secret value (the full regex match, or the capture group if `secretGroup` is set). If any stopword is a case-insensitive substring of the extracted value, the finding is suppressed.

```toml
[[rules]]
id    = "company-api-key"
regex = '''COMPANY_API_KEY_[A-Za-z0-9]{15,}'''
# ...

  [[rules.allowlists]]
  description = "Suppress placeholder and test values"
  stopwords   = ["changeme", "placeholder", "example", "test_key", "dummy"]
```

For the regex `COMPANY_API_KEY_[A-Za-z0-9]{15,}`, the extracted value is the full match, e.g. `COMPANY_API_KEY_changeme12345678`. Because `changeme` is a substring of the extracted value, the finding is suppressed.

**When to use:** test fixtures follow a naming convention that distinguishes them from real secrets (e.g. a consistent `changeme` or `placeholder` substring).

**Scope:** all files, for the specific rule only, when the value contains a stopword.

---

### Technique 5: Line Regex in `[[rules.allowlists]]`

`regexTarget = "line"` instructs Gitleaks to evaluate the pattern against the entire source line rather than just the matched secret value. This allows suppression based on surrounding context.

```toml
[[rules]]
id    = "database-connection-string"
# ...

  [[rules.allowlists]]
  description = "Suppress local and test database URLs"
  condition   = "OR"
  regexTarget = "line"
  regexes     = ['localhost', '127\.0\.0\.1', 'test_password', '0\.0\.0\.0']
```

For a line like:
```
DATABASE_LOCAL=postgres://user:someSecretPassword123@localhost:5432/testdb
```
The regex `localhost` matches the full line → the finding is suppressed.

**When to use:** context on the same line proves the value is not a real secret (localhost addresses, test hostnames, loopback IPs, or other identifying context).

**Scope:** all files, for the specific rule only, when the full line matches one of the regexes.

---

## 3. File: Triggers Pipeline Failure (Validation Test)

Use this file on a **test-only branch** to validate that Stage 1 correctly fails. Do not merge this branch.

**File:** `tests/fixtures/should-trigger.env`

```bash
# =============================================================================
# should-trigger.env
#
# PURPOSE : triggers Gitleaks Stage 1 failure to validate pipeline gating.
# BRANCH  : use on test/should-fail only — do NOT merge to main.
# VALUES  : entirely fake — not real credentials for any service.
# =============================================================================

# Matches github-pat (built-in rule)
GITHUB_TOKEN=ghp_ABCDEFghijklmn1234567890abcdef1234

# Matches aws-access-token (built-in rule)
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE9
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY9

# Matches company-api-key (custom rule in .gitleaks.toml)
COMPANY_API_KEY_production1234567890abc

# Matches internal-jwt-secret (custom rule in .gitleaks.toml)
jwt_secret=RealLookingJwtSigningKey_ProductionValue_2024
```

**Test procedure:**

```bash
git checkout -b test/should-fail

# Create the file above at tests/fixtures/should-trigger.env
git add tests/fixtures/should-trigger.env
git commit -m "test: add unsuppressed fake secrets to verify Stage 1 failure"
git push origin test/should-fail

# Open a PR/MR → confirm Stage 1 fails, Stages 2–5 do not run
```

**Expected results:**

| Stage | GitHub Actions | Azure Pipelines | GitLab CI/CD |
|-------|---------------|-----------------|--------------|
| Stage 1 — Gitleaks | Failed (red) | Failed (red) | Failed (red) |
| Stage 2 — Build | Skipped (grey) | Skipped (grey) | Skipped (grey) |
| Stage 3 — Test | Skipped (grey) | Skipped (grey) | Skipped (grey) |
| Stage 4 — Package | Skipped (grey) | Skipped (grey) | Skipped (grey) |
| Stage 5 — Deploy | Skipped (grey) | Skipped (grey) | Skipped (grey) |

---

## 4. File: Passes Cleanly — All Suppressions Applied

This file demonstrates all five suppression techniques. All findings are intentionally fake and suppressed. The pipeline must pass when this file is present.

**File:** `tests/fixtures/custom-rules-test.env`

```bash
# =============================================================================
# custom-rules-test.env
#
# PURPOSE : demonstrates all 5 Gitleaks suppression techniques.
# VALUES  : intentionally fake — all suppressed by the technique documented.
# =============================================================================

# ─── TECHNIQUE 1: Inline #gitleaks:allow ─────────────────────────────────────
# The inline comment tells Gitleaks to skip this exact line.
GITHUB_TOKEN=ghp_1234567890abcdef1234567890abcdef12345678  #gitleaks:allow
COMPANY_API_KEY_inlineSuppressDemo1234567890  #gitleaks:allow

# ─── TECHNIQUE 2: .gitleaksignore fingerprint ────────────────────────────────
# The internal-jwt-secret rule fires on the line below.
# The fingerprint is added to .gitleaksignore to suppress it.
# (See .gitleaksignore for the actual fingerprint entry.)
jwt_secret=fingerprint_demo_SigningKey_abc123XYZ_prod_2024

# ─── TECHNIQUE 3: Path-based [[rules.allowlists]] ────────────────────────────
# Demonstrated in tests/fixtures/test_db_false_positive.py.
# The database-connection-string rule has a per-rule path allowlist
# that suppresses all tests/*.py files.
# (See test_db_false_positive.py for the actual example.)

# ─── TECHNIQUE 4: Stopword in [[rules.allowlists]] ───────────────────────────
# "changeme" is a stopword in the company-api-key rule's allowlist.
# The full regex match is "COMPANY_API_KEY_changeme..." → suppressed.
COMPANY_API_KEY_changeme12345678901234

# ─── TECHNIQUE 5: Line regex against full line ───────────────────────────────
# "localhost" appears on this line → database-connection-string rule suppressed.
DATABASE_LOCAL=postgres://user:someSecretPassword123@localhost:5432/testdb
```

---

## 5. File: Path Allowlist Demo (Python Test File)

**File:** `tests/fixtures/test_db_false_positive.py`

Demonstrates Technique 3. The `database-connection-string` rule in `.gitleaks.toml` has a path allowlist that excludes all `tests/*.py` files. The URLs below would trigger the rule in any other file type.

```python
"""
Technique 3 — Path-based [[rules.allowlists]]

The database-connection-string rule in .gitleaks.toml has:

    [[rules.allowlists]]
    description = "Exclude Python test files"
    paths = ['(^|/)tests/.*\\.py$']

This means any postgres:// URL inside tests/*.py is never flagged,
even when the URL contains a password that would fire the rule elsewhere.
"""

import unittest

SUPPRESSED_DB_URL = "postgres://admin:hunter2_supersecret@db.internal:5432/myapp"


class TestDatabaseConnectionString(unittest.TestCase):

    def test_url_format_validation(self):
        url = SUPPRESSED_DB_URL
        self.assertTrue(url.startswith("postgres://"))
        self.assertIn("@db.internal", url)

    def test_mysql_url_also_suppressed(self):
        url = "mysql://user:realPassword_abc123@prod.db.company.com:3306/orders"
        self.assertIn("mysql://", url)


if __name__ == "__main__":
    unittest.main()
```

---

## 6. File: Clean Application Code

**File:** `src/app.py`

Demonstrates the correct pattern for handling credentials in application code — all credentials come from environment variables, never from source code. This file should always pass Gitleaks with zero findings.

```python
import os


def get_db_url() -> str:
    """Build database URL from environment variables only — never hardcode credentials."""
    host = os.environ["DB_HOST"]
    port = os.environ.get("DB_PORT", "5432")
    name = os.environ["DB_NAME"]
    return f"postgres://{host}:{port}/{name}"


def get_api_key() -> str:
    """Read API key from environment — never store in source code."""
    key = os.environ.get("API_KEY")
    if not key:
        raise ValueError("API_KEY environment variable is not set")
    return key


def main():
    print("Application started")
    print(f"DB: {get_db_url()}")


if __name__ == "__main__":
    main()
```

---

## 7. Summary: Which Technique to Use

| Situation | Technique |
|-----------|-----------|
| One-off line, can edit the source | 1 — `#gitleaks:allow` |
| Old commit, cannot rewrite history | 2 — `.gitleaksignore` fingerprint |
| Entire directory of test files | 3 — path pattern in `[[rules.allowlists]]` |
| Test values follow a naming convention | 4 — stopword in `[[rules.allowlists]]` |
| Context on the line proves safety | 5 — line regex in `[[rules.allowlists]]` |
| Real secret — not a false positive | Rotate + `git filter-repo` (see File 6) |
