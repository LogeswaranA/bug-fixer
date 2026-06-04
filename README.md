# morpheus-fix-bug-using-gitnexus

A Claude Code skill set that fixes bugs using **GitNexus** (code knowledge graph) + **Superpowers** (debugging, TDD, verification, review) + **GStack** (UI and security QA).

---

## Skill map

The workflow is split into four focused skills plus a reference document:

| Skill | Invoked by | Responsibility |
|---|---|---|
| `morpheus-fix-bug-using-gitnexus` | User — entry point | Mode detection and routing |
| `morpheus-worker` | Router (auto) | Core single-bug fix workflow |
| `morpheus-orchestrator` | Router (auto) | Multi-bug batch — worktrees, slot pool, PRs, report |
| `morpheus-integration-gate` | Worker (auto, GSD path only) | Mandatory security & QA gate after all phases integrate |
| `REFERENCE.md` | — (not a skill) | Tool map, failure modes, MCP config, install, changelog |

---

## Quick setup

Clone this repo into a machine that has Claude Code, then run:

**Linux / macOS / WSL:**
```bash
./setup.sh
```

**Windows (PowerShell):**
```powershell
.\setup.ps1
```

The script installs GitNexus, indexes the repo, and copies all four skills. It will tell you if Superpowers or GStack still need to be installed manually inside Claude Code.

---

## Manual setup (step by step)

### Step 1 — Install GitNexus (once per machine)

```bash
npm install -g gitnexus
# or use npx (no install needed):
npx gitnexus@latest setup
```

### Step 2 — Index your target repository

Run this inside the repo you want to fix bugs in:

```bash
cd /path/to/your-repo
npx gitnexus analyze          # index the repo
npx gitnexus setup            # write .mcp.json and detect editors
```

Verify indexing worked — you should see non-zero repos:

```bash
npx gitnexus status
```

### Step 3 — Install Superpowers and GStack (once per machine)

Follow the install instructions for:
- [Superpowers](https://superpowers.so) — provides `/systematic-debugging`, `/test-driven-development`, `/verification-before-completion`, `/requesting-code-review`
- [GStack](https://gstack.so) — provides `/qa` (UI) and `/cso` (security)

### Step 4 — Copy all four skills into your repository

Run from the **git root** of your target repo:

```bash
SKILL_SRC=/path/to/bug-fixer/.claude/skills

mkdir -p .claude/skills/morpheus-fix-bug-using-gitnexus
cp "$SKILL_SRC/morpheus-fix-bug-using-gitnexus/SKILL.md" .claude/skills/morpheus-fix-bug-using-gitnexus/
cp "$SKILL_SRC/morpheus-fix-bug-using-gitnexus/REFERENCE.md" .claude/skills/morpheus-fix-bug-using-gitnexus/

mkdir -p .claude/skills/morpheus-worker
cp "$SKILL_SRC/morpheus-worker/SKILL.md" .claude/skills/morpheus-worker/

mkdir -p .claude/skills/morpheus-orchestrator
cp "$SKILL_SRC/morpheus-orchestrator/SKILL.md" .claude/skills/morpheus-orchestrator/

mkdir -p .claude/skills/morpheus-integration-gate
cp "$SKILL_SRC/morpheus-integration-gate/SKILL.md" .claude/skills/morpheus-integration-gate/
```

### Step 5 — Add the Stop hook

Copy the gate script and register it:

```bash
mkdir -p .claude/hooks
cp /path/to/bug-fixer/.claude/hooks/morpheus-stop-gate.py .claude/hooks/
chmod +x .claude/hooks/morpheus-stop-gate.py
```

Add to `.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "python3 -c \"import subprocess,sys,os; r=subprocess.check_output(['git','rev-parse','--show-toplevel']).decode().strip(); exec(open(os.path.join(r,'.claude','hooks','morpheus-stop-gate.py')).read())\"",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

### Step 6 — Approve the GitNexus MCP server

Open Claude Code inside the repo:

```bash
/mcp
```

Approve `gitnexus` in the project MCP servers list. Then confirm all skills loaded:

```bash
/skills
```

You should see all four morpheus skills in the list.

---

## Usage

### Single bug (worker mode)

```bash
/morpheus-fix-bug-using-gitnexus KAN-229
/morpheus-fix-bug-using-gitnexus "500 on POST /auth/login when MFA is enabled"
/morpheus-fix-bug-using-gitnexus "failing test: spec/requests/reset_password_spec.rb:42"
/morpheus-fix-bug-using-gitnexus "stack trace: NullPointerException in PaymentRetryJob after deploy"
```

### Multi-bug batch (orchestrator mode)

```bash
# Pass multiple IDs directly
/morpheus-fix-bug-using-gitnexus JIRA-101 JIRA-102 JIRA-103

# Fetch a list from Jira via JQL
/morpheus-fix-bug-using-gitnexus --jql "project=KAN AND sprint='Sprint 42' AND type=Bug AND priority=High"

# Control parallelism (default: 5, max: 30)
/morpheus-fix-bug-using-gitnexus --jql "project=KAN AND type=Bug" --parallel 10
```

### Headless / CI

```bash
# Single bug
claude -p '/morpheus-fix-bug-using-gitnexus KAN-229'

# Multi-bug
claude -p '/morpheus-fix-bug-using-gitnexus JIRA-101 JIRA-102 JIRA-103'
```

Do **not** use `--bare` — it skips skill loading, hook registration, and `.mcp.json`.

---

## What the skill does

### Worker mode (single bug)

| Stage | Tool used |
|---|---|
| Pre-flight | Verify `.mcp.json` has `gitnexus` entry |
| Branch | Create `fix/<issue-id>` from default branch — never works on `main` |
| Orient | `gitnexus_list_repos`, `gitnexus_query` |
| Reproduce | Superpowers `/systematic-debugging` |
| Localise | `gitnexus_query`, `gitnexus_context` (callers + callees + processes) |
| Prepare edit | `gitnexus_context` on target symbol |
| Lock regression | Superpowers `/test-driven-development` — failing test before any fix |
| Fix | Narrowest code change consistent with the graph and failing test |
| Post-fix diagnostics | `gitnexus_detect_changes`, `gitnexus_impact` upstream + downstream, `gitnexus_api_impact`, `gitnexus_group_contracts` |
| Verify | Superpowers `/verification-before-completion` |
| Review | Superpowers `/requesting-code-review` |
| UI QA (optional) | GStack `/qa` — only if UI/frontend changed |
| Security QA (optional) | GStack `/cso` — only if auth/security surface changed |
| **PR — human gate** | **Claude asks: Auto PR or Manual PR — waits for your answer** |
| Emit summaries | MORPHEUS TELEMETRY SUMMARY + QA ARTIFACT SUMMARY printed to session |

### Orchestrator mode (multi-bug batch)

1. Resolves bug list from IDs or JQL
2. Creates an isolated `git worktree` + `fix/<issue-id>` branch per bug
3. Runs worker sessions in a slot-based pool (default: 5 concurrent, max: 30)
4. Opens PRs automatically for all fixed bugs (headless — no human gate per worker)
5. Prints a summary table: Issue | Status | Tests | Fail→0? | Duration | Tokens | PR URL

### Integration gate (GSD multi-phase path only)

When a bug is too complex for a single session and escalates to GSD:

1. Each GSD phase runs its own Morpheus worker session (with its own per-session security check)
2. After **all phases integrate**, `morpheus-integration-gate` runs **once** on the full combined diff
3. Checks for cross-phase vulnerabilities that no individual session could see
4. Writes `.morpheus-integration-qa.json` — the comprehensive PR is blocked until `result: "pass"`

---

## Branch and PR workflow

Every fix follows this branch discipline regardless of mode:

```
main (or master / default branch)
  └── fix/<issue-id>          ← all changes land here
        └── PR → main         ← PR is the only merge path
```

- **Branch created**: Step 0.5 of every worker session, before any code change
- **Branch naming**: `fix/JIRA-101` for known IDs; `fix/mfa-login-500-post-auth` for plain summaries
- **Default branch detected dynamically**: `git symbolic-ref refs/remotes/origin/HEAD` — never hardcoded
- **PR creation**: human chooses Auto (Claude runs `gh pr create`) or Manual (Claude prints instructions)
- **Direct push to main**: blocked by non-negotiable rules and the Stop hook

---

## Artifacts produced per fix

| File | Contains |
|---|---|
| `.morpheus-qa.json` | Regression test metadata, suite before/after, coverage delta, UI QA and security QA results |
| `.morpheus-telemetry.json` | Per-stage wall-clock timing, token counts, OTEL trace ID, PR URL |
| `.morpheus-integration-qa.json` | Integration-level security and verification results (GSD path only) |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `/skills` does not show the morpheus skills | Check all four `SKILL.md` files exist under `.claude/skills/` and reload Claude Code |
| GitNexus not connected in `/mcp` | Run `/mcp` → Approve project MCP servers, or restart Claude Code |
| `gitnexus_list_repos` returns empty | Run `npx gitnexus analyze` in the repo root and re-check |
| `.mcp.json` missing or no `gitnexus` key | Add the `gitnexus` entry (see `REFERENCE.md`) and re-run `npx gitnexus analyze` |
| Superpowers skill not found | Install Superpowers globally and confirm with `/skills` |
| GStack skill not found | Install GStack globally and confirm with `/skills` |
| `gh pr create` fails | Check `gh auth status`; skill falls back to Manual PR path automatically |
| Worker started on main/master | Stop — run `git checkout -b fix/<issue-id>` before touching any file |
| Stop hook blocking unexpectedly | Check `.morpheus-qa.json` — `suite_before_fix` and `suite_after_fix` must both be non-null with `failed` reduced |
| Complex bug / context loss | Escalate with `/gsd-debug` — skill guides you through multi-phase flow and invokes the integration gate at the end |

---

## Parallel workers — resource guidance

| Bugs | `--parallel` | RAM needed |
|---|---|---|
| ≤ 10 | 5 (default) | ~2 GB |
| 11–20 | 8 | ~4 GB |
| 21–30 | 10 | ~5 GB |
| > 30 | 10–15 | ~6–8 GB |

`--parallel` is a resource budget, not a thread count. Hard limit is 30 — the skill refuses values above this.

---

## Files in this repo

```
.
├── README.md                          ← this file
├── MORPHEUS-FLOWCHART-ONLY.md        ← visual decision flowcharts (Mermaid)
├── setup.sh                          ← quick setup script (Linux/macOS/WSL)
├── setup.ps1                         ← quick setup script (Windows PowerShell)
└── .claude/
    ├── hooks/
    │   └── morpheus-stop-gate.py     ← Stop hook gate script
    └── skills/
        ├── morpheus-fix-bug-using-gitnexus/
        │   ├── SKILL.md              ← entry point router
        │   └── REFERENCE.md         ← tool map, failure modes, config, changelog
        ├── morpheus-worker/
        │   └── SKILL.md             ← core single-bug fix workflow
        ├── morpheus-orchestrator/
        │   └── SKILL.md             ← multi-bug batch orchestrator
        └── morpheus-integration-gate/
            └── SKILL.md             ← GSD multi-phase security & QA gate
```


claude --output-format stream-json --verbose -p '/morpheus-fix-bug-using-gitnexus unable to save api_key' | tee session.log