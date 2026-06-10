# Prerequisites and Setup

## 1. System Requirements

| Requirement | Minimum version | Check command |
|-------------|----------------|---------------|
| OS | Linux, macOS, or Windows WSL2 | `uname -a` |
| Git | 2.20 | `git --version` |
| Bash | 4.0 | `bash --version` |
| curl | any | `curl --version` |
| Python | 3.8 (for `src/` and `tests/`) | `python3 --version` |

**Windows users:** use WSL2. The scan script and all commands in this guide assume a Linux shell.

---

## 2. Accounts and Access

| Platform | Required access |
|----------|----------------|
| GitHub | Repository with Actions enabled; write access to push branches |
| Azure DevOps | Organisation with Pipelines enabled; Build service account with read access |
| GitLab | Project with CI/CD enabled; Developer role or above |

You do not need accounts on all three platforms to start. Implement GitHub Actions first, then adapt for the others.

---

## 3. Repository Location

All examples in this guide use:

```
/home/abdul/gitleaks-test
```

### Initialize from scratch

```bash
mkdir -p /home/abdul/gitleaks-test
cd /home/abdul/gitleaks-test
git init
git remote add origin <your-remote-url>
```

### Clone an existing remote

```bash
git clone <your-remote-url> /home/abdul/gitleaks-test
cd /home/abdul/gitleaks-test
```

---

## 4. Git Identity Configuration

```bash
git config user.name  "Your Name"
git config user.email "you@example.com"
```

Verify:

```bash
git config --list | grep user
```

---

## 5. Required Directory Structure

After setup, the repository must contain the following files. Create any that are missing.

```
gitleaks-test/
├── .github/
│   └── workflows/
│       └── pipeline.yml          # GitHub Actions — 5-stage pipeline
├── .gitlab-ci.yml                # GitLab CI/CD — 5-stage pipeline
├── .gitleaks.toml                # Gitleaks config: custom rules + allowlists
├── .gitleaksignore               # Fingerprint-based false-positive suppressions
├── .gitignore                    # Excludes scan output files, __pycache__, etc.
├── .pre-commit-config.yaml       # Optional: runs Gitleaks on git commit locally
├── azure-pipelines.yml           # Azure Pipelines — 5-stage pipeline
├── scripts/
│   └── gitleaks-scan.sh         # Shared scan script used by all three platforms
├── src/
│   └── app.py                   # Sample app — credentials from env vars only
├── tests/
│   ├── fixtures/
│   │   ├── custom-rules-test.env # Phase 2 suppression technique demos
│   │   └── test_db_false_positive.py  # Path-allowlist demo
│   └── test_app.py
├── docs/                         # This guide
├── LICENSE
└── README.md
```

---

## 6. .gitignore Entries

Gitleaks writes scan reports to disk during every run. These files must be gitignored — they may contain partial secret values extracted from findings and must never be committed.

Create or update `.gitignore` at the repository root:

```gitignore
# ── Gitleaks scan output ─────────────────────────────────────────────────────
# These are written at runtime. Commit them and Gitleaks will scan its own
# output, producing self-referential findings.
report.json
report.sarif
report.csv
report.xml
report.junit
git-report.json
results.json
results.sarif
*.sarif
baseline.json
new-findings.json

# ── Python ────────────────────────────────────────────────────────────────────
__pycache__/
*.py[cod]
*.pyo
.pytest_cache/
.mypy_cache/
htmlcov/
.coverage

# ── OS / editor ───────────────────────────────────────────────────────────────
.DS_Store
Thumbs.db
*.swp
*.swo
.idea/
.vscode/
```

Verify the entries are active:

```bash
git check-ignore -v results.sarif
# → .gitignore:7:results.sarif    results.sarif
```

---

## 7. Create the scripts/ Directory

```bash
mkdir -p scripts
touch scripts/gitleaks-scan.sh
chmod +x scripts/gitleaks-scan.sh
```

The full content of `scripts/gitleaks-scan.sh` is in `02-installing-and-configuring-gitleaks.md`.

---

## 8. Create the .github/workflows/ Directory

```bash
mkdir -p .github/workflows
```

The full content of `.github/workflows/pipeline.yml` is in `05-pipeline-configuration.md`.

---

## 9. Initial Commit

```bash
git add .gitignore .gitleaks.toml .gitleaksignore .pre-commit-config.yaml \
        scripts/gitleaks-scan.sh \
        .github/workflows/pipeline.yml \
        azure-pipelines.yml \
        .gitlab-ci.yml \
        src/app.py \
        tests/

git commit -m "feat: initial Gitleaks CI/CD implementation"
git push -u origin main
```

---

## 10. Verify the Repository is Clean Before Adding Pipelines

Run a local full-history scan before pushing any pipeline configuration:

```bash
bash scripts/gitleaks-scan.sh
```

If it exits 0, the repository is clean and you are ready to proceed.
If it exits 1, review the findings before continuing — see `06-validation-and-remediation.md`.
