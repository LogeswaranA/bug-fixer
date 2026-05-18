---
name: morpheus-fix-bug-using-gitnexus
description: Reproduce, localise, fix, verify, and review a bug by using GitNexus as the code knowledge base and Superpowers as the bug-fix engine.
when_to_use: Use for regressions, failing tests, stack traces, incident follow-up, flaky behaviour, or unexpected runtime errors in an indexed repository. Accepts an issue ID, failing command, failing test, stack trace, log excerpt, or plain-language bug summary.
argument-hint: "[issue-id...] | --jql \"<JQL query>\" | [issue-id|bug-summary|failing-test|stack-trace]"
arguments:
  - bug
  - bugs
  - jql
disable-model-invocation: true
user-invocable: true
---

## Mode detection

Inspect the arguments immediately on invocation:

| Arguments | Mode |
|---|---|
| Single ID, summary, stack trace, or test | **Worker mode** — run the fix workflow for that one bug |
| Two or more space-separated IDs | **Orchestrator mode** — spawn one worker session per bug |
| `--jql "<query>"` | **Orchestrator mode** — fetch bug list from Jira first, then spawn workers |

---

## Orchestrator mode

When orchestrator mode is detected:

### Step 1 — Resolve bug list

- If IDs were provided directly, use them as-is.
- If `--jql` was provided, call the Jira MCP tool (or `curl` the Jira REST API) with the JQL to retrieve the list of issue keys. Abort with a clear error if the query returns zero results or the API is unreachable.

### Step 2 — Prepare worktrees

For each bug ID, create an isolated git worktree and branch:

```bash
git worktree add .worktrees/<issue-id> -b fix/<issue-id>
```

- Branch name convention: `fix/<issue-id>` (e.g. `fix/JIRA-101`)
- Worktree path: `.worktrees/<issue-id>`
- If `.worktreeinclude` exists, apply it to each worktree so gitignored local files (`.env`, secrets) are available.

### Step 3 — Spawn worker sessions in parallel

Launch one headless Claude session per bug, each scoped to its worktree:

```bash
cd .worktrees/<issue-id> && claude -p '/morpheus-fix-bug-using-gitnexus <issue-id>'
```

- Workers run in parallel (background processes).
- Each worker runs the full fix workflow independently.
- Each worker's Stop hook gates it — the orchestrator does not bypass it.
- Workers must not touch each other's worktrees or the main worktree.

### Step 4 — Monitor workers

Poll or stream each worker's exit status. Record for each:

- `status`: `fixed` | `failed` | `blocked` (Stop hook rejected) | `skipped`
- `branch`: `fix/<issue-id>`
- `test_result`: pass / fail / not-run
- `pr_url`: filled in step 5

### Step 5 — Open PRs for successful workers

For each worker that completed with `status: fixed`:

```bash
gh pr create \
  --title "fix: <issue-id> — <one-line bug summary>" \
  --body "$(cat <<'EOF'
## Bug
<issue-id>: <summary from Jira>

## Fix summary
<what was changed>

## Verification
- Regression test: added/tightened
- gitnexus_detect_changes: run
- gitnexus_impact upstream: run
- gitnexus_impact downstream: run
- gitnexus_group_contracts: run (if multi-repo)
- verification-before-completion: run

Fixed by morpheus-fix-bug-using-gitnexus
EOF
)" \
  --base main \
  --head fix/<issue-id>
```

### Step 6 — Summary report

Print a table when all workers finish:

```
┌──────────┬─────────┬──────────────┬──────────────────────────────────┐
│ Issue    │ Status  │ Test result  │ PR                               │
├──────────┼─────────┼──────────────┼──────────────────────────────────┤
│ JIRA-101 │ fixed   │ pass         │ https://github.com/.../pull/42   │
│ JIRA-102 │ fixed   │ pass         │ https://github.com/.../pull/43   │
│ JIRA-103 │ failed  │ fail         │ —                                │
│ JIRA-104 │ blocked │ not-run      │ —  (Stop hook: missing repro)    │
│ JIRA-105 │ fixed   │ pass         │ https://github.com/.../pull/44   │
└──────────┴─────────┴──────────────┴──────────────────────────────────┘
```

For `failed` or `blocked` workers, include the failure reason beneath the table.

### Step 7 — Cleanup

Remove worktrees for completed workers only (leave failed/blocked ones for inspection):

```bash
git worktree remove .worktrees/<issue-id>
```

### Orchestrator non-negotiable rules

- Do **not** merge worktree branches automatically — PRs are the merge gate.
- Do **not** skip PR creation for successful workers — the report PR URL must be filled.
- Do **not** delete failed or blocked worktrees — leave them for human inspection.
- Do **not** spawn more than 5 workers in parallel by default — cap at 5 unless the user raises it explicitly.
- If Jira MCP is unavailable for `--jql` mode, abort and tell the user to provide issue IDs directly.

### Orchestrator mode diagram

```mermaid
flowchart TD
    A[/morpheus-fix-bug-using-gitnexus args/] --> B{Mode detection}
    B -- single bug --> C[Worker mode: fix workflow]
    B -- multiple IDs --> D[Orchestrator mode]
    B -- --jql query --> E[Fetch from Jira]
    E --> D
    D --> F[git worktree add per bug]
    F --> G[Spawn parallel worker sessions]
    G --> H1[Worker: JIRA-101]
    G --> H2[Worker: JIRA-102]
    G --> H3[Worker: JIRA-N]
    H1 & H2 & H3 --> I[Monitor exit status]
    I --> J[gh pr create for fixed bugs]
    J --> K[Summary report]
    K --> L[git worktree remove fixed ones]
```

---

## Summary

This skill fixes bugs with a strict order of operations:

1. Use **GitNexus first** to orient in the repo, route the investigation, and narrow the blast radius.
2. Use **Superpowers `/systematic-debugging`** to reproduce and identify root cause before changing code.
3. Use **Superpowers `/test-driven-development`** to add or tighten a failing regression test.
4. Implement the **narrowest fix** consistent with the GitNexus graph and the failing test.
5. Run **GitNexus post-fix diagnostics**:
   - `gitnexus_detect_changes`
   - `gitnexus_impact` upstream (who called the changed symbol)
   - `gitnexus_impact` downstream (who will feel the fix)
   - `gitnexus_api_impact` (if HTTP routes or API surfaces changed)
   - `gitnexus_group_contracts` (if multi-repo groups are configured)
6. Use **Superpowers `/verification-before-completion`** for fresh verification.
7. Use **Superpowers `/requesting-code-review`** for review.
8. Use **GStack** only when a UI/browser review, security review, or tie-break decision is needed.
9. Use **GSD** only if the bug becomes large, multi-session, or context-heavy.

Non-negotiable rules:

- Do **not** begin with blind `Read`, `Grep`, or `Glob` across indexed source files.
- Do **not** patch before reproducing the bug or creating the smallest failing case.
- Do **not** edit a source file before calling `gitnexus_context` for the target symbol.
- Do **not** declare success before running the post-fix GitNexus diagnostic sequence.
- Do **not** skip Superpowers skills — invoke them with the `Skill` tool explicitly, never emulate inline and move on.
- Do **not** rename symbols with find-and-replace — use `gitnexus_rename`.
- If running inside a headless worker or git worktree, stay inside the assigned worktree and obey worker-specific hand-off rules.

**Mandatory Superpowers invocations (use `Skill` tool — not inline emulation):**

| When | Skill to invoke |
|---|---|
| Before any code change | `Skill("superpowers-systematic-debugging")` |
| Before writing the fix | `Skill("superpowers-test-driven-development")` |
| After fix + diagnostics | `Skill("superpowers-verification-before-completion")` |
| Before declaring done | `Skill("superpowers-requesting-code-review")` |

If a Superpowers skill is not installed, **stop and report** — do not proceed with the fix until the skill is available or the user explicitly opts out.

## Usage

Interactive examples:

```bash
/morpheus-fix-bug-using-gitnexus KAN-229
/morpheus-fix-bug-using-gitnexus "500 on POST /auth/login when MFA is enabled"
/morpheus-fix-bug-using-gitnexus "failing test: spec/requests/reset_password_spec.rb:42"
/morpheus-fix-bug-using-gitnexus "stack trace: NullPointerException in PaymentRetryJob after deploy"
```

Orchestrator examples (multi-bug):

```bash
/morpheus-fix-bug-using-gitnexus JIRA-101 JIRA-102 JIRA-103 JIRA-104 JIRA-105
/morpheus-fix-bug-using-gitnexus --jql "project=KAN AND sprint='Sprint 42' AND type=Bug AND priority=High"
```

Headless examples:

```bash
# Single bug (worker mode)
claude -p '/morpheus-fix-bug-using-gitnexus KAN-229'
claude -p '/morpheus-fix-bug-using-gitnexus "500 on POST /auth/login when MFA is enabled"'

# Multi-bug (orchestrator mode)
claude -p '/morpheus-fix-bug-using-gitnexus JIRA-101 JIRA-102 JIRA-103'
claude -p '/morpheus-fix-bug-using-gitnexus --jql "project=KAN AND type=Bug AND sprint=active"'
```

## Commands

### Primary tools and skills

Use these in this order whenever they are available:

- **GitNexus MCP tools**
  - `gitnexus_list_repos` — orient: verify index is non-empty
  - `gitnexus_query` — hybrid BM25 + semantic search; replaces `search_symbols` and `get_repo_outline`
  - `gitnexus_context` — 360-degree symbol view (callers + callees + process participation); replaces `smart_context`, `get_editing_context`, `find_usages`, `get_call_chain`
  - `gitnexus_impact` with `direction: "upstream"` — who depends on this symbol; replaces `get_dependents`, `explain_change_impact`
  - `gitnexus_impact` with `direction: "downstream"` — what this symbol depends on; replaces `get_dependencies`
  - `gitnexus_detect_changes` — git-diff impact; maps changed lines to affected processes; replaces `detect_changes`
  - `gitnexus_api_impact` — blast radius for HTTP route or API surface changes (no Gortex equivalent)
  - `gitnexus_rename` — coordinated multi-file rename; replaces `rename_symbol`
  - `gitnexus_group_contracts` — cross-repo contract check; replaces `contracts action=check`
  - `gitnexus_cypher` — raw Cypher graph query for complex multi-hop traces

- **Superpowers**
  - `/systematic-debugging`
  - `/test-driven-development`
  - `/verification-before-completion`
  - `/requesting-code-review`

### GitNexus ↔ Gortex tool map

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

### Optional tools and skills

- **GStack**: `/qa` for browser/UI validation, `/cso` for security-sensitive fixes
- **GSD**: `/gsd-debug` only for context-heavy or multi-session debugging
- **RalphLoop / Build Loop**: outer orchestrator — this skill runs inside worker sessions

### Fallback rule

If a **GitNexus MCP tool** is not available:

- continue in degraded mode using `Read` / `Grep` / `Glob`,
- state explicitly that GitNexus is unavailable.

If a **Superpowers skill** is not available:

- **stop** — do not emulate inline,
- tell the user which skill is missing and ask them to install it or explicitly opt out.

## Workflow

### Worker preamble contract

Before any source reading, code editing, or test-writing, enforce this contract:

1. Call `gitnexus_list_repos()` — verify the index is non-empty.
2. Call `gitnexus_query({query: "<bug summary>"})` — broad orientation, find candidate symbols.
3. Call `gitnexus_context({name: "<top candidate>"})` — assemble relevant context bundle.
4. Use GitNexus tools to localise the likely root-cause area.
5. Before editing each target file, call `gitnexus_context` on the target symbol.
6. Prefer `gitnexus_query` + `gitnexus_context` over whole-file reads.
7. Only fall back to `Read`, `Grep`, or `Glob` when GitNexus is unavailable, the file is not indexed, or the graph response is insufficient.

### Main fix loop

| Stage | Required action | Output needed before continuing |
|---|---|---|
| Orient | `gitnexus_list_repos()` | non-empty index confirmed |
| Assemble context | `gitnexus_query({query: "<bug area>"})` | candidate symbols |
| Reproduce | `/systematic-debugging` | exact bug reproduction or smallest failing case |
| Localise | `gitnexus_query`, `gitnexus_context` (incoming + outgoing refs), `gitnexus_impact(upstream)` | root-cause candidate with evidence |
| Prepare edit | `gitnexus_context({name: "<target symbol>"})` | callers, deps, process participation |
| Lock regression | `/test-driven-development` | failing regression test |
| Fix | narrow code change only | test now passes locally |
| Diagnose change | `gitnexus_detect_changes({scope: "staged"})` | changed symbols + affected processes |
| Verify impact | `gitnexus_impact(upstream)` + `gitnexus_impact(downstream)` | blast radius confirmed |
| API check | `gitnexus_api_impact` (if routes changed) | route consumers identified |
| Contract check | `gitnexus_group_contracts` (if multi-repo) | cross-repo breakage ruled out |
| Verify | `/verification-before-completion` | fresh green evidence |
| Review | `/requesting-code-review` | review findings and follow-up actions |

### Workflow diagram

```mermaid
flowchart TD
    A[/morpheus-fix-bug-using-gitnexus ARGUMENTS/] --> B[gitnexus_list_repos]
    B --> C[gitnexus_query — orient]
    C --> D[gitnexus_context — assemble context]
    D --> E[/systematic-debugging]
    E --> F[gitnexus_query + gitnexus_context incoming + outgoing refs]
    F --> G[gitnexus_impact upstream — localise dependents]
    G --> H[gitnexus_context on target symbol — prepare edit]
    H --> I[/test-driven-development]
    I --> J[Narrow code fix]
    J --> K[gitnexus_detect_changes]
    K --> L[gitnexus_impact upstream + downstream]
    L --> M[gitnexus_api_impact if routes changed]
    M --> N[gitnexus_group_contracts if multi-repo]
    N --> O[/verification-before-completion]
    O --> P[/requesting-code-review]
    P --> Q[Optional GStack QA or CSO]
```

### RalphLoop and headless worktree notes

- Work only inside the assigned git worktree.
- Do not modify the main worktree directly.
- Do not rewrite orchestrator files unless the worker prompt explicitly assigns them.
- If a HUMAN GATE or equivalent stop condition triggers, halt and report instead of guessing.
- If the repo needs `.env` or other gitignored local files in worktrees, use `.worktreeinclude`.

## Hooks

Assume the preferred state is that `npx gitnexus analyze` has already registered repo-local hooks for:

- `PreToolUse` (denies raw `Read`/`Grep`/`Glob` on indexed source)
- `PreCompact`
- `Stop`

Required behaviour even if the hooks are missing:

- self-enforce the read/grep rule;
- self-enforce post-fix diagnostics;
- self-enforce stop gating before claiming completion.

Do **not** run this skill in `claude -p --bare` mode if you expect project skills, project hooks, `.mcp.json`, or `CLAUDE.md` to load.

Optional stop-gate policy — refuse to stop if:

- there is no reproduction,
- there is no failing or formerly failing test,
- post-fix GitNexus diagnostics (`detect_changes`, impact checks) have not run,
- verification has not been run fresh,
- review has not been requested,
- or a required worktree hand-off is missing.

## Failure modes

| Failure | Response |
|---|---|
| `gitnexus_list_repos` returns empty | run `npx gitnexus analyze`, then re-check |
| GitNexus server unavailable | continue in degraded mode only if necessary, and say so explicitly |
| `.mcp.json` server not approved | approve from `/mcp` or use team-approved settings |
| **Orchestrator: JQL returns zero results** | abort — report the empty query result, ask user to verify the JQL |
| **Orchestrator: Jira API unreachable** | abort — ask user to provide issue IDs directly instead |
| **Orchestrator: worktree already exists** | skip creation, reuse existing worktree; warn the user |
| **Orchestrator: worker exceeds parallel cap (5)** | queue remaining bugs; start next worker as a slot frees |
| **Orchestrator: worker Stop hook blocks** | mark as `blocked`, leave worktree intact, include reason in summary |
| **Orchestrator: PR creation fails** | log the failure per bug; do not skip the summary report |
| **Orchestrator: merge conflict between worker branches** | do not merge — PRs are the resolution gate; flag in summary |
| Relative path in `.mcp.json` breaks startup | replace with absolute path or use `npx gitnexus` from `PATH` |
| No reproduction exists yet | create the smallest failing test or script before patching |
| Worktree lacks secrets or local config | use `.worktreeinclude` or a worktree hook |
| Merge conflict or orchestrator gate | stop and hand off for human resolution |
| Repeated compaction / sprawling investigation | escalate to GSD |

## Escalation

### GSD

Do **not** use GSD by default. Escalate only when:

- the bug spans multiple services or repositories,
- the investigation repeatedly loses context,
- the investigation requires several independent debug phases,
- a single session is no longer keeping a coherent root-cause thread,
- or the worker prompt explicitly requests `/gsd-debug`.

When escalating: preserve the current bug brief, evidence, root-cause hypothesis, and changed symbols. Start each new phase with the same GitNexus context contract. Return to this skill's post-fix diagnostic sequence before completing.

## Examples

### Example interactive transcript

```text
User: /morpheus-fix-bug-using-gitnexus "500 on POST /auth/login when MFA is enabled"
Assistant:
- Call gitnexus_list_repos to verify index
- Call gitnexus_query with "auth login MFA 500"
- Call gitnexus_context on the top candidate symbol
- Invoke /systematic-debugging
- Reproduce failure locally
- Call gitnexus_context on target files/symbols
- Invoke /test-driven-development
- Add failing regression test
- Fix the smallest set of symbols needed
- Call gitnexus_detect_changes
- Call gitnexus_impact upstream + downstream
- Call gitnexus_api_impact (route changed)
- Invoke /verification-before-completion
- Invoke /requesting-code-review
- If UI flow changed, invoke /qa
```

### Example headless orchestration flow

```mermaid
flowchart LR
    O[Build Loop or RalphLoop orchestrator] --> W1[worker session in git worktree]
    W1 --> S1[/morpheus-fix-bug-using-gitnexus issue-id]
    S1 --> G1[GitNexus context contract]
    G1 --> SP1[Superpowers debugging and TDD]
    SP1 --> GD1[GitNexus post-fix diagnostics]
    GD1 --> RV1[Review and optional GStack QA or CSO]
    RV1 --> C1[worker-specific hand-off or done commit]
    C1 --> M1[orchestrator merge or reconcile]
```

### Example orchestrator run — multiple IDs

```text
User: /morpheus-fix-bug-using-gitnexus JIRA-101 JIRA-102 JIRA-103 JIRA-104 JIRA-105

Assistant (orchestrator mode):
- Detect 5 IDs — switch to orchestrator mode
- git worktree add .worktrees/JIRA-101 -b fix/JIRA-101
- git worktree add .worktrees/JIRA-102 -b fix/JIRA-102
- git worktree add .worktrees/JIRA-103 -b fix/JIRA-103
- git worktree add .worktrees/JIRA-104 -b fix/JIRA-104
- git worktree add .worktrees/JIRA-105 -b fix/JIRA-105
- Spawn 5 parallel headless workers (one per worktree)
- Monitor exit status of all 5 workers
- gh pr create for each successful worker
- Print summary report
- git worktree remove for fixed/succeeded worktrees
```

### Example orchestrator run — JQL mode

```text
User: /morpheus-fix-bug-using-gitnexus --jql "project=KAN AND sprint='Sprint 42' AND type=Bug AND priority=High"

Assistant (orchestrator mode):
- Detect --jql flag — fetch bug list from Jira
- Jira returns: JIRA-101, JIRA-102, JIRA-103 (3 bugs)
- Proceed with worktree + worker creation for each
- ... (same flow as multiple IDs above)
```

### Sample slash commands

```bash
/morpheus-fix-bug-using-gitnexus BUG-1421
/morpheus-fix-bug-using-gitnexus "failing test: packages/api/src/auth/reset_password.test.ts::handles expired token"
/morpheus-fix-bug-using-gitnexus "stack trace: KeyError in invoice_sync when customer has no external_id"
```

## MCP config

### Project MCP server example

Create `.mcp.json` at the repository root:

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

### Local settings example

Use `.claude/settings.local.json` for machine-specific approval and optional permissions:

```json
{
  "enableAllProjectMcpServers": true,
  "skillOverrides": {
    "morpheus-fix-bug-using-gitnexus": "on"
  },
  "permissions": {
    "allow": [
      "Skill(morpheus-fix-bug-using-gitnexus *)",
      "Bash(git status *)",
      "Bash(git diff *)",
      "Bash(git worktree list *)",
      "Bash(pwd)",
      "Bash(ls *)"
    ]
  }
}
```

### Stop hook (copy this into the repo's `.claude/settings.json`)

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "You receive session context as JSON. Check whether the '/morpheus-fix-bug-using-gitnexus' skill was actually invoked and executed in this session (not just discussed or mentioned). If it was NOT invoked, respond ONLY with {\"decision\": \"allow\"} — no explanation, no other text.\n\nOnly if '/morpheus-fix-bug-using-gitnexus' was genuinely invoked, verify ALL of the following steps were completed:\n1. Bug was reproduced (smallest failing case exists)\n2. Skill(superpowers-systematic-debugging) was invoked\n3. Skill(superpowers-test-driven-development) was invoked and a failing test was written\n4. The fix was applied and the test now passes\n5. gitnexus_detect_changes was called\n6. gitnexus_impact with direction upstream was called\n7. gitnexus_impact with direction downstream was called\n8. gitnexus_api_impact was called OR explicitly skipped because no routes changed\n9. gitnexus_group_contracts was called OR explicitly skipped because repo is not multi-repo\n10. Skill(superpowers-verification-before-completion) was invoked\n11. Skill(superpowers-requesting-code-review) was invoked\n\nIf all steps are complete, respond ONLY with {\"decision\": \"allow\"}.\nIf any step is missing, respond ONLY with {\"decision\": \"block\", \"reason\": \"Missing required step: <step name>\"}.\nRespond with JSON only — no explanation, no other text.",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

## Install

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

### Install this skill into the repo

```bash
mkdir -p .claude/skills/morpheus-fix-bug-using-gitnexus
# Copy this file to:
# .claude/skills/morpheus-fix-bug-using-gitnexus/SKILL.md
```

### Trust and approve project configuration

1. Start `claude` in the repo once so the workspace can be trusted.
2. Open `/mcp` and confirm the `gitnexus` project server is approved.
3. Open `/skills` and confirm `morpheus-fix-bug-using-gitnexus` appears.

## Testing

### Functional validation

- `/skills` shows `morpheus-fix-bug-using-gitnexus`
- `/mcp` shows `gitnexus` connected
- `gitnexus_list_repos()` reports non-zero repos
- invoking `/morpheus-fix-bug-using-gitnexus ...` starts with GitNexus orientation, not blind `Read`
- the skill reproduces the bug before patching
- the skill calls `gitnexus_context` before editing target symbols
- the skill creates or tightens a failing regression test
- the skill runs `gitnexus_detect_changes`, `gitnexus_impact` (both directions)
- the skill invokes `/verification-before-completion`
- the skill invokes `/requesting-code-review`
- headless `claude -p '/morpheus-fix-bug-using-gitnexus ...'` works without `--bare`

### Minimal CI checklist

- use a deterministic fixture repo with a known failing bug
- ensure the repo already trusts the project MCP server or pre-approves it via settings
- do not use `--bare`
- run a headless invocation
- assert that the regression test exists and passes after the fix
- assert that verification commands are green
- fail the job if:
  - the server is not approved,
  - GitNexus has zero repos indexed,
  - the bug was patched without a failing reproduction,
  - post-fix diagnostics were skipped,
  - or the worktree/orchestrator hand-off contract was not met

## Changelog

- **2026-05-18** — initial port of morpheus-fix-my-bug from Gortex to GitNexus
