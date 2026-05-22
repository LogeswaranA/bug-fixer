# Morpheus Reference

Companion reference for `morpheus-fix-bug-using-gitnexus`. Not a skill file — not invocable. Contains lookup tables, config templates, and install instructions.

---

## GitNexus ↔ Gortex tool map

| Gortex tool | GitNexus equivalent | Notes |
|---|---|---|
| `get_repo_outline` / `graph_stats` | `gitnexus_list_repos()` | Orient and verify index |
| `plan_turn` | *(no equivalent — skip)* | Go straight to `gitnexus_query` |
| `smart_context` | `gitnexus_context({name})` | Same semantics |
| `get_editing_context` | `gitnexus_context({name})` | Same — callers + callees |
| `search_symbols` | `gitnexus_query({query})` | BM25 + semantic |
| `find_usages` | `gitnexus_context` → incoming refs | |
| `get_call_chain` | `gitnexus_context` → outgoing refs | |
| `get_dependents` | `gitnexus_impact(direction: "upstream")` | |
| `get_dependencies` | `gitnexus_impact(direction: "downstream")` | |
| `get_symbol_source` | `Read` file (fallback only) | GitNexus does not expose raw source via MCP |
| `detect_changes` | `gitnexus_detect_changes({scope})` | Direct equivalent |
| `get_test_targets` | Test files in `gitnexus_impact` output | Look for test paths in impact result |
| `check_guards` | *(no equivalent — skip)* | Handle manually if project has linting gates |
| `analyze kind=dead_code` | `gitnexus_cypher("<Cypher>")` | Write a zero-in-degree query |
| `contracts action=check` | `gitnexus_group_contracts({group})` | Requires group config |
| `feedback action=record` | *(no equivalent — skip)* | |
| `rename_symbol` | `gitnexus_rename({symbol_name, new_name, dry_run})` | Direct equivalent |
| `explain_change_impact` | `gitnexus_impact({target, direction: "upstream"})` | |

---

## Failure modes

| Failure | Response |
|---|---|
| **`.mcp.json` missing or has no `gitnexus` entry** | **STOP** — print the exact config block to add; do not proceed or degrade silently |
| `.mcp.json` present but server not yet approved | approve from `/mcp` → Approve project MCP servers, then re-invoke |
| `.mcp.json` correct but server transiently unavailable (crash, network) | proceed in degraded mode with `Read`/`Grep`/`Glob`; state explicitly that GitNexus is unavailable |
| `gitnexus_list_repos` returns empty index | run `npx gitnexus analyze` in the repo root, then re-check; do not proceed until index is non-empty |
| **Orchestrator: JQL returns zero results** | abort — report the empty query result, ask user to verify the JQL |
| **Orchestrator: Jira API unreachable** | abort — ask user to provide issue IDs directly instead |
| **Orchestrator: worktree already exists** | skip creation, reuse existing worktree; warn the user |
| **Orchestrator: worker exceeds parallel cap** | queue remaining bugs; start next worker as a slot frees |
| **Orchestrator: worker Stop hook blocks** | mark as `blocked`, leave worktree intact, include reason in summary |
| **Orchestrator: PR creation fails** | log the failure per bug; do not skip the summary report |
| **Orchestrator: merge conflict between worker branches** | do not merge — PRs are the resolution gate; flag in summary |
| **GSD escalation: Integration Security Gate skipped** | block PR creation — `.morpheus-integration-qa.json` must exist with `result: "pass"` |
| **GSD escalation: Integration verification failed** | block PR creation — fix failures and re-run `superpowers-verification-before-completion` on the integrated branch |
| Relative path in `.mcp.json` breaks startup | replace with absolute path or use `npx gitnexus` from `PATH` |
| No reproduction exists yet | create the smallest failing test or script before patching |
| Worktree lacks secrets or local config | use `.worktreeinclude` or a worktree hook |
| Merge conflict or orchestrator gate | stop and hand off for human resolution |
| Repeated compaction / sprawling investigation | escalate to GSD |

---

## MCP config

### Project MCP server — REQUIRED

`.mcp.json` at the repository root is required. Without it, Claude Code cannot connect to the GitNexus MCP server and the skill will refuse to run.

If your repo already has a `.mcp.json` with other servers (e.g. Jira), merge the `gitnexus` entry in:

```json
{
  "mcpServers": {
    "gitnexus": {
      "command": "npx",
      "args": ["-y", "gitnexus@latest", "mcp"]
    }
  }
}
```

After creating or editing `.mcp.json`:

1. Run `npx gitnexus analyze` to index the repo.
2. Restart Claude Code (or run `/mcp` → Approve project MCP servers).
3. Confirm `gitnexus` shows as connected in `/mcp` before invoking the skill.

### Local settings example

`.claude/settings.local.json` for machine-specific approval and permissions:

```json
{
  "enableAllProjectMcpServers": true,
  "permissions": {
    "allow": [
      "mcp__gitnexus__*",
      "mcp__jira__*",
      "Read(*)",
      "Edit(*)",
      "Write(*)",
      "Bash(git *)",
      "Bash(npm *)",
      "Bash(npx *)",
      "Bash(dotnet *)",
      "Bash(python3 *)",
      "Bash(pytest *)",
      "Bash(go test*)"
    ]
  }
}
```

`Edit(*)`, `Write(*)`, `Read(*)` are required for headless mode — any tool not pre-approved causes `claude -p` to stop and wait forever with no user watching.

### Stop hook

Use a **command hook** rather than a prompt hook. Prompt hooks use a language model and always add prose; a command hook calls the API with `max_tokens=50`, making prose physically impossible.

**Step 1** — copy the gate script:

```bash
mkdir -p .claude/hooks
# Copy .claude/hooks/morpheus-stop-gate.py from this skill's repo
chmod +x .claude/hooks/morpheus-stop-gate.py
```

The script:
- Reads the session context from stdin
- Calls `claude-haiku-4-5-20251001` with `max_tokens=50`
- Loads `ANTHROPIC_API_KEY` from env or `.env` file
- Truncates session to ~20k chars to stay within token limits
- Falls back to `{"decision":"approve"}` on any error (fail-open)
- Coerces `"allow"` → `"approve"` (Claude Code Stop hooks require `"approve"`)

**Step 2** — add to `.claude/settings.json`:

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

**Monorepo note**: keep `.claude/` and `.mcp.json` at the git root. The hook uses `git rev-parse --show-toplevel` so it resolves correctly regardless of which subdirectory Claude is working in.

---

## Install

### Install otel-cli for OpenTelemetry tracing (optional)

```bash
# macOS
brew install otel-cli

# Linux / Go
go install github.com/equinix-labs/otel-cli@latest

# Verify
otel-cli version
```

Add to `.env` or shell profile:

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
export OTEL_SERVICE_NAME="morpheus-bug-fixer"
```

### Install GitNexus once per machine

```bash
npm install -g gitnexus
# or use npx (no install needed):
npx gitnexus@latest setup
```

### Initialise this repo for GitNexus

```bash
cd /path/to/repo
npx gitnexus analyze          # index the repo
npx gitnexus setup            # auto-detect editors and write MCP config
```

### Install the skills into the repo

Run from the **git root**:

```bash
# Main router
mkdir -p .claude/skills/morpheus-fix-bug-using-gitnexus
# Copy SKILL.md and REFERENCE.md

# Sub-skills
mkdir -p .claude/skills/morpheus-worker
mkdir -p .claude/skills/morpheus-orchestrator
mkdir -p .claude/skills/morpheus-integration-gate
# Copy each SKILL.md

# Stop-gate hook
mkdir -p .claude/hooks
# Copy morpheus-stop-gate.py
chmod +x .claude/hooks/morpheus-stop-gate.py
```

### Trust and approve project configuration

1. Start `claude` in the repo once so the workspace can be trusted.
2. Open `/mcp` and confirm the `gitnexus` project server is approved.
3. Open `/skills` and confirm all four morpheus skills appear.

---

## Testing

### Functional validation checklist

- `/skills` shows all four morpheus skills
- `/mcp` shows `gitnexus` connected
- `gitnexus_list_repos()` reports non-zero repos
- invoking `/morpheus-fix-bug-using-gitnexus ...` starts with GitNexus orientation, not blind `Read`
- the skill reproduces the bug before patching
- the skill calls `gitnexus_context` before editing target symbols
- the skill creates or tightens a failing regression test
- `.morpheus-qa.json` is created with `regression_test`, `tests_added`, `suite_before_fix`, `suite_after_fix` all non-null
- `suite_after_fix.failed` is strictly less than `suite_before_fix.failed`
- the QA ARTIFACT SUMMARY block is printed before the Stop hook
- the MORPHEUS TELEMETRY SUMMARY block is printed with per-stage timing and tokens
- GSD path: `.morpheus-integration-qa.json` exists with both results `"pass"` before the comprehensive PR
- headless `claude -p '/morpheus-fix-bug-using-gitnexus ...'` works without `--bare`

### Minimal CI checklist

- use a deterministic fixture repo with a known failing bug
- ensure the repo already trusts the project MCP server or pre-approves it via settings
- do not use `--bare`
- run a headless invocation
- assert that the regression test exists and passes after the fix
- assert that verification commands are green
- fail the job if:
  - the server is not approved
  - GitNexus has zero repos indexed
  - the bug was patched without a failing reproduction
  - post-fix diagnostics were skipped
  - or the worktree/orchestrator hand-off contract was not met

---

## Changelog

- **2026-05-22** — split monolithic SKILL.md into four skill files (`morpheus-fix-bug-using-gitnexus` router, `morpheus-worker`, `morpheus-orchestrator`, `morpheus-integration-gate`) plus this REFERENCE.md; no behaviour changes
- **2026-05-22** — added Integration Security & QA Gate as mandatory step in GSD multi-phase path; added `.morpheus-integration-qa.json` schema; updated flowchart with gate node
- **2026-05-18** — added QA artifacts: `.morpheus-qa.json` state file, QA summary block, Stop hook QA gates, orchestrator summary columns
- **2026-05-18** — added telemetry: per-stage wall-clock timing, token tracking, OpenTelemetry span emission via `otel-cli`, telemetry summary block
- **2026-05-18** — initial port of morpheus-fix-my-bug from Gortex to GitNexus
