---
name: security-review
description: Security vulnerability scanner for code changes. Checks for OWASP Top 10 vulnerabilities, insecure patterns, auth bypasses, injection risks, and cryptographic weaknesses. Returns structured findings with severity ratings.
when_to_use: After any code change that may introduce security risks. Mandatory in morpheus-worker after Fix stage and in morpheus-integration-gate for multi-phase GSD fixes.
argument-hint: "[--scope staged|branch|all] [--output json|text]"
user-invocable: true
---

## Purpose

Scans code changes for security vulnerabilities before they reach production. Uses GitNexus AST search for pattern-based detection, combined with manual code review of high-risk areas.

## Security Check Categories

### OWASP Top 10 (2021)

1. **A01:2021 – Broken Access Control**
   - Missing authorization checks
   - Path traversal vulnerabilities
   - Insecure direct object references (IDOR)
   - Elevation of privilege

2. **A02:2021 – Cryptographic Failures**
   - Weak encryption algorithms (MD5, SHA1, DES, RC4)
   - Hardcoded secrets/keys
   - Insecure random number generation
   - Missing encryption for sensitive data

3. **A03:2021 – Injection**
   - SQL injection (string concatenation in queries)
   - Command injection (shell execution with user input)
   - NoSQL injection
   - LDAP injection
   - XSS (Cross-Site Scripting)

4. **A04:2021 – Insecure Design**
   - Missing rate limiting
   - Insufficient logging for security events
   - Trust boundary violations

5. **A05:2021 – Security Misconfiguration**
   - Default credentials
   - Unnecessary features enabled
   - Verbose error messages exposing internals
   - Missing security headers

6. **A06:2021 – Vulnerable and Outdated Components**
   - Dependencies with known CVEs
   - Unmaintained libraries

7. **A07:2021 – Identification and Authentication Failures**
   - Weak password requirements
   - Session fixation vulnerabilities
   - Missing MFA support
   - Insecure session token generation

8. **A08:2021 – Software and Data Integrity Failures**
   - Insecure deserialization
   - Missing integrity checks
   - Auto-update without verification

9. **A09:2021 – Security Logging and Monitoring Failures**
   - No audit trail for security-critical actions
   - Missing alerting on suspicious activity

10. **A10:2021 – Server-Side Request Forgery (SSRF)**
    - Unvalidated URL parameters
    - Missing allowlist for external requests

## Required steps

**Step 1 — Determine scan scope**

```bash
# Default: staged changes
SCOPE=${1:-staged}

case "$SCOPE" in
  staged)
    DIFF_BASE="HEAD"
    ;;
  branch)
    DEFAULT_BRANCH=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||' || echo "main")
    DIFF_BASE="origin/$DEFAULT_BRANCH"
    ;;
  all)
    DIFF_BASE=""  # full repo scan
    ;;
esac
```

**Step 2 — Use GitNexus to detect changed symbols**

If GitNexus is available:

```bash
gitnexus_detect_changes({scope: "$SCOPE"})
```

Extract the list of changed files and symbols from the result. Otherwise fall back to:

```bash
git diff --name-only "$DIFF_BASE"
```

**Step 3 — Run AST-based pattern detection**

If GitNexus/Gortex `search_ast` is available, use bundled detectors:

```bash
# SQL injection
search_ast({detector: "sql-string-concat", min_fan_in_of_enclosing_func: 2})

# Hardcoded secrets
search_ast({detector: "hardcoded-secret"})

# Weak crypto
search_ast({detector: "weak-crypto"})

# Command injection (shell with string concat)
search_ast({pattern: "(call_expression function: [...] arguments: [...] @match)", language: "python|javascript|go"})

# Empty catch blocks (swallows exceptions)
search_ast({detector: "empty-catch"})

# Missing error wrapping
search_ast({detector: "error-not-wrapped"})

# Panics in library code
search_ast({detector: "panic-in-library"})

# HTTP client without timeout
search_ast({detector: "http-client-no-timeout"})

# Goroutines without recover
search_ast({detector: "goroutine-without-recover"})
```

Each detector returns matches with:
- `file_path`, `line_number`, `snippet`
- `enclosing_function_id` and `enclosing_function_name`
- `fan_in` (caller count) to prioritize high-traffic code

**Step 4 — Manual code review for high-risk areas**

For each changed file, check manually if AST patterns miss context-dependent issues:

### Auth & Authorization
- [ ] Are authentication checks present before sensitive operations?
- [ ] Are role/permission checks enforced?
- [ ] Can users access resources they shouldn't own?
- [ ] Are session tokens validated correctly?

### Input Validation
- [ ] Is user input validated against an allowlist (not just sanitized)?
- [ ] Are file uploads restricted by type, size, and content?
- [ ] Are URLs validated before making external requests (SSRF)?
- [ ] Is input length-checked to prevent buffer overflows or DoS?

### Data Exposure
- [ ] Are error messages generic (not exposing stack traces or DB schema)?
- [ ] Are secrets/keys stored in environment variables or secret managers (not hardcoded)?
- [ ] Is sensitive data (PII, passwords) encrypted at rest and in transit?
- [ ] Are logs free of sensitive data?

### Cryptography
- [ ] Are modern algorithms used (AES-256, RSA-2048+, SHA-256+)?
- [ ] Is random data generated with cryptographically secure RNGs?
- [ ] Are keys rotated and stored securely?

### Dependencies
- [ ] Are dependencies up-to-date?
- [ ] Are there known CVEs in `package.json`, `requirements.txt`, `go.mod`, etc.?

**Step 5 — Classify findings by severity**

| Severity | Criteria | Action required |
|---|---|---|
| **CRITICAL** | Remote code execution, authentication bypass, hardcoded credentials | Block PR immediately; fix before proceeding |
| **HIGH** | SQL injection, XSS, SSRF, privilege escalation, weak crypto | Block PR; fix required |
| **MEDIUM** | Missing input validation, verbose errors, missing rate limiting | Flag in PR; fix recommended before merge |
| **LOW** | Missing logging, outdated dependencies (no known CVE), code smells | Flag in PR; can merge with tracking issue |
| **INFO** | Best-practice suggestions, refactoring opportunities | Informational only |

**Step 6 — Write findings to structured JSON**

```json
{
  "schema_version": "1",
  "scan_timestamp": "<ISO 8601>",
  "scope": "staged | branch | all",
  "files_scanned": 12,
  "symbols_changed": 8,
  "findings": [
    {
      "id": "SEC-001",
      "severity": "HIGH",
      "category": "A03:2021 – Injection",
      "title": "SQL injection via string concatenation",
      "file": "src/auth/login.py",
      "line": 42,
      "snippet": "query = f\"SELECT * FROM users WHERE username='{username}'\"",
      "description": "User input `username` is directly interpolated into SQL query without parameterization.",
      "recommendation": "Use parameterized queries: `cursor.execute('SELECT * FROM users WHERE username=%s', (username,))`",
      "cwe": "CWE-89",
      "owasp": "A03:2021"
    },
    {
      "id": "SEC-002",
      "severity": "CRITICAL",
      "category": "A02:2021 – Cryptographic Failures",
      "title": "Hardcoded API key",
      "file": "config/settings.py",
      "line": 17,
      "snippet": "API_KEY = 'sk-abc123def456'",
      "description": "API key is hardcoded in source. If repo is public or key leaks, attacker gains full API access.",
      "recommendation": "Move to environment variable: `API_KEY = os.getenv('API_KEY')`",
      "cwe": "CWE-798",
      "owasp": "A02:2021"
    }
  ],
  "summary": {
    "critical": 1,
    "high": 1,
    "medium": 0,
    "low": 0,
    "info": 0
  },
  "result": "fail"
}
```

Write to `.security-review-findings.json` at repo root.

**Step 7 — Print summary and return result**

Print a concise summary block:

```
╔══════════════════════════════════════════════════════════════════╗
║                   SECURITY REVIEW SUMMARY                        ║
╠══════════════════════════════════════════════════════════════════╣
║ Scope:          staged changes (8 symbols, 12 files)             ║
║ Scan completed: 2026-05-23 14:32:18 UTC                          ║
╠══════════════════════════════════════════════════════════════════╣
║ Findings by severity:                                            ║
║   🔴 CRITICAL:  1  — BLOCKS PR                                   ║
║   🟠 HIGH:      1  — BLOCKS PR                                   ║
║   🟡 MEDIUM:    0                                                ║
║   🟢 LOW:       0                                                ║
║   ℹ️  INFO:      0                                                ║
╠══════════════════════════════════════════════════════════════════╣
║ Result: ❌ FAIL — 2 blocking findings must be fixed             ║
╠══════════════════════════════════════════════════════════════════╣
║ Top findings:                                                    ║
║  SEC-001 [HIGH]     SQL injection in src/auth/login.py:42       ║
║  SEC-002 [CRITICAL] Hardcoded API key in config/settings.py:17  ║
╠══════════════════════════════════════════════════════════════════╣
║ Full report: .security-review-findings.json                     ║
╚══════════════════════════════════════════════════════════════════╝
```

Return result code:
- **PASS**: Zero CRITICAL or HIGH findings
- **FAIL**: One or more CRITICAL or HIGH findings
- **WARN**: Only MEDIUM/LOW/INFO findings

## Integration with Morpheus

### In morpheus-worker

After the "Fix" stage and before "Diagnose change", insert:

```
| Security scan | `Skill("security-review", scope="staged")` | PASS (zero CRITICAL/HIGH findings) |
```

If result is FAIL, the worker must:
1. Present findings to the user
2. Fix the security issues
3. Re-run `security-review` until PASS
4. Only then proceed to "Diagnose change"

### In morpheus-integration-gate

At Step 3, replace the placeholder with:

```bash
Skill("security-review", scope="branch")
```

Write the result to `.morpheus-integration-qa.json`:

```json
{
  "integration_security_qa": {
    "invoked": true,
    "tool": "security-review",
    "scope": "branch",
    "result": "pass | fail",
    "findings_file": ".security-review-findings.json",
    "critical_count": 0,
    "high_count": 0
  }
}
```

## Non-negotiable rules

- Do **not** skip security checks even if the diff looks safe — silent vulnerabilities exist.
- Do **not** downgrade CRITICAL or HIGH severity to unblock a PR — fix the issue.
- Do **not** proceed to PR creation if `result: "fail"`.
- Do **not** skip AST pattern checks if GitNexus is available — they catch 80% of common issues.
- If a finding is a false positive, document why in `.security-review-findings.json` under `false_positive_justification` and re-classify to INFO.

## Output formats

### JSON (default)
Writes `.security-review-findings.json` with structured findings array.

### Text
Prints findings as a bulleted list to stdout (for CI integration):

```
CRITICAL: Hardcoded API key in config/settings.py:17
HIGH: SQL injection via string concatenation in src/auth/login.py:42
```

## Dependencies

- GitNexus MCP (`search_ast`, `detect_changes`) — optional but strongly recommended
- Git (required)
- Python/Node/Go/Java AST parsers (via GitNexus) — optional

## Usage

```bash
# Scan staged changes (default)
/security-review

# Scan current branch vs main
/security-review --scope branch

# Full repo scan
/security-review --scope all

# JSON output (default)
/security-review --output json

# Text output (for CI)
/security-review --output text
```

## Headless mode

```bash
claude -p '/security-review --scope staged --output json' > security-report.json
EXIT_CODE=$?
if [ "$EXIT_CODE" -ne 0 ]; then
  echo "Security review failed — blocking PR"
  exit 1
fi
```

## Testing

Verify the skill works on a known-vulnerable test file:

```python
# test-vuln.py
import os
import sqlite3

def login(username, password):
    conn = sqlite3.connect('users.db')
    cursor = conn.cursor()
    # SQL injection vulnerability
    query = f"SELECT * FROM users WHERE username='{username}' AND password='{password}'"
    cursor.execute(query)
    return cursor.fetchone()

# Hardcoded secret
API_KEY = "sk-1234567890abcdef"

# Weak crypto
import hashlib
password_hash = hashlib.md5(password.encode()).hexdigest()
```

Expected findings:
- CRITICAL: Hardcoded API key at line 13
- HIGH: SQL injection at line 9
- HIGH: Weak crypto (MD5) at line 16

---

## Changelog

- 2026-05-23: Initial version — OWASP Top 10, AST detectors, JSON output
