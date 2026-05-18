---
name: morpheus-fix-my-bug
description: Reproduce, localise, fix, verify, and review a bug by using Gortex as the code knowledge base and Superpowers as the bug-fix engine.
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
| Single ID, summary, stack trace, or test | **Worker mode** — run the 12-step fix workflow for that one bug |
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
cd .worktrees/<issue-id> && claude -p '/morpheus-fix-my-bug <issue-id>'
```

- Workers run in parallel (background processes).
- Each worker runs the full 12-step morpheus workflow independently.
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
- detect_changes: run
- get_test_targets: run
- check_guards: run
- analyze dead_code: run
- contracts check: run
- verification-before-completion: run

🤖 Fixed by morpheus-fix-my-bug
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
    A[/morpheus-fix-my-bug args/] --> B{Mode detection}
    B -- single bug --> C[Worker mode: 12-step fix]
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

1. Use **Gortex first** to understand the repo, route the investigation, and narrow the blast radius.
2. Use **Superpowers `/systematic-debugging`** to reproduce and identify root cause before changing code.
3. Use **Superpowers `/test-driven-development`** to add or tighten a failing regression test.
4. Implement the **narrowest fix** consistent with the Gortex graph and the failing test.
5. Run **Gortex post-fix diagnostics**:
   - `detect_changes`
   - `get_test_targets`
   - `check_guards`
   - `analyze` with `kind: "dead_code"`
   - `contracts` with `action: "check"`
6. Use **Superpowers `/verification-before-completion`** for fresh verification.
7. Use **Superpowers `/requesting-code-review`** for review.
8. Use **GStack** only when a UI/browser review, security review, or tie-break decision is needed.
9. Use **GSD** only if the bug becomes large, multi-session, or context-heavy.

Non-negotiable rules:

- Do **not** begin with blind `Read`, `Grep`, or `Glob` across indexed source files.
- Do **not** patch before reproducing the bug or creating the smallest failing case.
- Do **not** edit a source file before calling `get_editing_context` for that file.
- Do **not** declare success before running the post-fix Gortex diagnostic sequence.
- Do **not** skip Superpowers skills — invoke them with the `Skill` tool explicitly, never emulate inline and move on.
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
/morpheus-fix-my-bug KAN-229
/morpheus-fix-my-bug "500 on POST /auth/login when MFA is enabled"
/morpheus-fix-my-bug "failing test: spec/requests/reset_password_spec.rb:42"
/morpheus-fix-my-bug "stack trace: NullPointerException in PaymentRetryJob after deploy"
```

Orchestrator examples (multi-bug):

```bash
/morpheus-fix-my-bug JIRA-101 JIRA-102 JIRA-103 JIRA-104 JIRA-105
/morpheus-fix-my-bug --jql "project=KAN AND sprint='Sprint 42' AND type=Bug AND priority=High"
```

Headless examples:

```bash
# Single bug (worker mode)
claude -p '/morpheus-fix-my-bug KAN-229'
claude -p '/morpheus-fix-my-bug "500 on POST /auth/login when MFA is enabled"'

# Multi-bug (orchestrator mode)
claude -p '/morpheus-fix-my-bug JIRA-101 JIRA-102 JIRA-103'
claude -p '/morpheus-fix-my-bug --jql "project=KAN AND type=Bug AND sprint=active"'
```

If the prompt provides multiple inputs for a single bug, treat them all as evidence: issue ID, stack trace, log excerpt, failing command, screenshots, or error text.

If the prompt provides multiple space-separated Jira IDs, switch to orchestrator mode automatically.

## Commands

### Primary tools and skills

Use these in this order whenever they are available:

- **Gortex MCP tools**
  - `get_repo_outline`
  - `graph_stats`
  - `plan_turn`
  - `smart_context`
  - `get_editing_context`
  - `search_symbols`
  - `find_usages`
  - `get_call_chain`
  - `get_dependencies`
  - `get_dependents`
  - `get_symbol_source`
  - `detect_changes`
  - `get_test_targets`
  - `check_guards`
  - `analyze` with `kind: "dead_code"`
  - `contracts` with `action: "check"`
  - `feedback` with `action: "record"`

- **Superpowers**
  - `/systematic-debugging`
  - `/test-driven-development`
  - `/verification-before-completion`
  - `/requesting-code-review`

### Optional tools and skills

Use these only when relevant:

- **GStack**
  - `/qa` for browser, UI, or workflow validation
  - `/cso` for security-sensitive fixes
  - local role-review or voting skills if the worker prompt requires an explicit decision protocol

- **GSD**
  - `/gsd-debug` only for context-heavy or multi-session debugging

- **RalphLoop / Build Loop**
  - `/build-loop` is the outer orchestrator, not the bug-fix engine
  - this skill should run inside a worker session when the worker prompt says to use it

### Fallback rule

If a **Gortex MCP tool** is not available:

- continue in degraded mode using `Read` / `Grep` / `Glob`,
- state explicitly that Gortex is unavailable.

If a **Superpowers skill** is not available:

- **stop** — do not emulate inline,
- tell the user which skill is missing and ask them to install it or explicitly opt out,
- do **not** proceed with the fix until they respond.

## Workflow

### Worker preamble contract

Before any source reading, code editing, or test-writing, enforce this contract:

1. Call `get_repo_outline` or `graph_stats`.
2. Call `plan_turn` with the bug summary and available evidence.
3. Call `smart_context` with the task.
4. Use graph tools to localise the likely root-cause area.
5. Before editing each target file, call `get_editing_context`.
6. Prefer `get_symbol_source` and symbol-level traversal over whole-file reads.
7. Only fall back to `Read`, `Grep`, or `Glob` when:
   - Gortex is unavailable,
   - the file is not indexed,
   - or the graph response is insufficient.

### Main fix loop

| Stage | Required action | Output needed before continuing |
|---|---|---|
| Orient | `get_repo_outline` or `graph_stats` | high-level repo map |
| Route | `plan_turn` | recommended next calls |
| Assemble context | `smart_context` | relevant symbols, files, tests, entry points |
| Reproduce | `/systematic-debugging` | exact bug reproduction or smallest failing case |
| Localise | `search_symbols`, `find_usages`, `get_call_chain`, `get_dependencies`, `get_dependents`, `get_symbol_source` | root-cause candidate with evidence |
| Prepare edit | `get_editing_context` | symbol signatures, callers, direct deps |
| Lock regression | `/test-driven-development` | failing regression test |
| Fix | narrow code change only | test now passes locally |
| Diagnose change | `detect_changes` | changed symbols/files identified |
| Verify impact | `get_test_targets`, `check_guards`, `analyze(kind="dead_code")`, `contracts(action="check")` | tests/guards/contracts ready |
| Verify | `/verification-before-completion` | fresh green evidence |
| Review | `/requesting-code-review` | review findings and follow-up actions |
| Learn | `feedback(action="record")` | useful/missing symbols recorded |

### Workflow diagram

```mermaid
flowchart TD
    A[/morpheus-fix-my-bug $ARGUMENTS/] --> B[get_repo_outline or graph_stats]
    B --> C[plan_turn]
    C --> D[smart_context]
    D --> E[/systematic-debugging]
    E --> F[search_symbols + find_usages + get_call_chain]
    F --> G[get_dependencies + get_dependents + get_symbol_source]
    G --> H[get_editing_context]
    H --> I[/test-driven-development]
    I --> J[Narrow code fix]
    J --> K[detect_changes]
    K --> L[get_test_targets + check_guards]
    L --> M[analyze dead_code + contracts check]
    M --> N[/verification-before-completion]
    N --> O[/requesting-code-review]
    O --> P[Optional GStack QA or CSO]
    P --> Q[feedback action: record]
```

### RalphLoop and headless worktree notes

If this skill is running inside a RalphLoop or Build Loop worker:

- work only inside the assigned git worktree;
- do not modify the main worktree directly;
- do not rewrite orchestrator files unless the worker prompt explicitly assigns them;
- if the worker prompt requires a specific completion commit or hand-off format, use it exactly;
- if the worker prompt specifies a decision policy, follow it exactly;
- if a HUMAN GATE or equivalent stop condition triggers, halt and report instead of guessing.

If the repo needs `.env` or other gitignored local files in worktrees, use `.worktreeinclude` or an equivalent worktree creation hook.

## Hooks

Assume the preferred state is that `gortex init` has already installed repo-local hooks for:

- `PreToolUse`
- `PreCompact`
- `Stop`

Required behaviour even if the hooks are missing:

- self-enforce the read/grep rule;
- self-enforce post-fix diagnostics;
- self-enforce stop gating before claiming completion.

Important operational note:

- do **not** run this skill in `claude -p --bare` mode if you expect project skills, project hooks, `.mcp.json`, or `CLAUDE.md` to load.

Optional stop-gate policy:

- refuse to stop if:
  - there is no reproduction,
  - there is no failing or formerly failing test,
  - post-fix Gortex diagnostics have not run,
  - verification has not been run fresh,
  - review has not been requested,
  - or a required worktree hand-off is missing.

## Failure modes

| Failure | Response |
|---|---|
| `repo_not_tracked` or equivalent Gortex error | run `gortex track .`, then re-check status |
| `graph_stats` / `gortex status` shows zero nodes | stop and repair indexing before bug-fixing |
| Gortex server unavailable | continue in degraded mode only if necessary, and say so explicitly |
| `.mcp.json` server not approved | approve it from `/mcp` or use team-approved settings |
| **Orchestrator: JQL returns zero results** | abort — report the empty query result, ask user to verify the JQL |
| **Orchestrator: Jira API unreachable** | abort — ask user to provide issue IDs directly instead |
| **Orchestrator: worktree already exists** | skip creation, reuse existing worktree; warn the user |
| **Orchestrator: worker exceeds parallel cap (5)** | queue remaining bugs; start next worker as a slot frees |
| **Orchestrator: worker Stop hook blocks** | mark as `blocked`, leave worktree intact, include reason in summary |
| **Orchestrator: PR creation fails** | log the failure per bug; do not skip the summary report |
| **Orchestrator: merge conflict between worker branches** | do not merge — PRs are the resolution gate; flag in summary |
| Relative path in `.mcp.json` breaks startup | replace with absolute path or use `gortex` from `PATH` |
| No reproduction exists yet | create the smallest failing test or script before patching |
| Worktree lacks secrets or local config | use `.worktreeinclude` or a worktree hook |
| Merge conflict or orchestrator gate | stop and hand off for human resolution |
| Repeated compaction / sprawling investigation | escalate to GSD |

## Escalation

### GSD

Do **not** use GSD by default.

Escalate to GSD only when one or more of these are true:

- the bug spans multiple services or repositories,
- the investigation repeatedly loses context,
- the investigation requires several independent debug phases,
- a single session is no longer keeping a coherent root-cause thread,
- or the worker prompt explicitly requests `/gsd-debug`.

When escalating:

1. preserve the current bug brief and evidence,
2. preserve the current best root-cause hypothesis,
3. preserve changed symbols and key test targets,
4. start each new phase with the same Gortex context contract,
5. return to this skill's post-fix diagnostic sequence before completing.

## Examples

### Example interactive transcript

```text
User: /morpheus-fix-my-bug "500 on POST /auth/login when MFA is enabled"

Assistant:
- Call get_repo_outline
- Call plan_turn with the bug summary
- Call smart_context with auth/login + MFA + 500
- Call search_symbols for login/auth/MFA handlers
- Call get_call_chain on the selected handler
- Invoke /systematic-debugging
- Reproduce failure locally
- Call get_editing_context on target files
- Invoke /test-driven-development
- Add failing regression test
- Fix the smallest set of symbols needed
- Call detect_changes
- Call get_test_targets
- Call check_guards
- Call analyze kind=dead_code
- Call contracts action=check
- Invoke /verification-before-completion
- Invoke /requesting-code-review
- If UI flow changed, invoke /qa
- Record feedback action=record
```

### Example headless orchestration flow

```mermaid
flowchart LR
    O[Build Loop or RalphLoop orchestrator] --> W1[worker session in git worktree]
    W1 --> S1[/morpheus-fix-my-bug issue-id]
    S1 --> G1[Gortex context contract]
    G1 --> SP1[Superpowers debugging and TDD]
    SP1 --> GD1[Gortex post-fix diagnostics]
    GD1 --> RV1[Review and optional GStack QA or CSO]
    RV1 --> C1[worker-specific hand-off or done commit]
    C1 --> M1[orchestrator merge or reconcile]
```

### Example orchestrator run — multiple IDs

```text
User: /morpheus-fix-my-bug JIRA-101 JIRA-102 JIRA-103 JIRA-104 JIRA-105

Assistant (orchestrator mode):
- Detect 5 IDs → switch to orchestrator mode
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
User: /morpheus-fix-my-bug --jql "project=KAN AND sprint='Sprint 42' AND type=Bug AND priority=High"

Assistant (orchestrator mode):
- Detect --jql flag → fetch bug list from Jira
- Jira returns: JIRA-101, JIRA-102, JIRA-103 (3 bugs)
- Proceed with worktree + worker creation for each
- ... (same flow as multiple IDs above)
```

### Sample slash commands

```bash
/morpheus-fix-my-bug BUG-1421
/morpheus-fix-my-bug "failing test: packages/api/src/auth/reset_password.test.ts::handles expired token"
/morpheus-fix-my-bug "stack trace: KeyError in invoice_sync when customer has no external_id"
/build-loop docs/BUILD-PROMPTS.md
```

## MCP config

### Project MCP server example

Create `.mcp.json` at the repository root:

```json
{
  "mcpServers": {
    "gortex": {
      "command": "gortex",
      "args": ["mcp", "--index", ".", "--watch"],
      "env": {
        "GORTEX_LOG": "info"
      }
    }
  }
}
```

If you prefer daemon mode, keep the same `gortex mcp` entry. It will proxy through the daemon automatically when the daemon is running.

### Local settings example

Use `.claude/settings.local.json` for machine-specific approval and optional permissions:

```json
{
  "enableAllProjectMcpServers": true,
  "skillOverrides": {
    "morpheus-fix-my-bug": "on"
  },
  "permissions": {
    "allow": [
      "Skill(morpheus-fix-my-bug *)",
      "Bash(git status *)",
      "Bash(git diff *)",
      "Bash(git worktree list *)",
      "Bash(pwd)",
      "Bash(ls *)"
    ]
  }
}
```

If you want to share this with the team, move the relevant parts into `.claude/settings.json` after review.

### Placeholder Gortex hook example

Prefer the exact hooks generated by `gortex init`. If you need a placeholder shape for discussion or bootstrapping, this is the right Claude Code schema shape:

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Read|Grep|Glob|Task",
        "hooks": [
          {
            "type": "command",
            "command": "gortex hook <pretooluse-placeholder>",
            "timeout": 30
          }
        ]
      }
    ],
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "gortex hook <precompact-placeholder>",
            "timeout": 30
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "gortex hook <stop-placeholder>",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

### Optional prompt hook to enforce stop quality

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "prompt",
            "prompt": "Allow stopping only if the run has reproduced the bug, created or tightened a regression test, executed detect_changes, get_test_targets, check_guards, analyze dead_code, contracts action=check, verification-before-completion, requesting-code-review, and feedback action=record. If any are missing return {\"ok\": false, \"reason\": \"<missing step>\"}. $ARGUMENTS",
            "timeout": 30
          }
        ]
      }
    ]
  }
}
```

### Routing example

This YAML is a project convention example, not a required Claude file:

```yaml
bug_fix_routing:
  default_skill: /morpheus-fix-my-bug
  use_when:
    - regression
    - failing test
    - stack trace
    - runtime exception
    - intermittent production bug
  require_gortex: true
  optional_review:
    ui: /qa
    security: /cso
  escalate_to_gsd_when:
    - repeated_context_compaction
    - multi_service_debug
    - multi_session_investigation
```

### Worker prompt routing example

```md
Skills: morpheus-fix-my-bug, superpowers:systematic-debugging, superpowers:test-driven-development, superpowers:verification-before-completion, superpowers:requesting-code-review

Run /morpheus-fix-my-bug on the assigned issue. Stay inside the current worktree. Use GStack only when a decision point, browser QA, or security review is needed.
```

## Install

### Install Gortex once per machine

```bash
curl -fsSL https://get.gortex.dev | sh
gortex install --start --track
```

### Initialise this repo for Gortex

```bash
cd /path/to/repo
gortex init --analyze --skills
gortex status --index .
```

### Install this skill into the repo

```bash
mkdir -p .claude/skills/morpheus-fix-my-bug
# Copy this file to:
# .claude/skills/morpheus-fix-my-bug/SKILL.md
```

### Trust and approve project configuration

1. Start `claude` in the repo once so the workspace can be trusted.
2. Open `/mcp` and confirm the `gortex` project server is approved if needed.
3. Open `/skills` and confirm `morpheus-fix-my-bug` appears.

### Optional daemon lifecycle

```bash
gortex daemon start --detach
gortex daemon status
gortex track .
```

### Optional standalone repo server

```bash
gortex mcp --index . --watch
```

## Testing

Run these validation checks after installation.

### Functional validation

- `/skills` shows `morpheus-fix-my-bug`
- `/mcp` shows `gortex` connected
- `gortex status --index .` reports non-zero nodes
- invoking `/morpheus-fix-my-bug ...` starts with Gortex orientation, not blind `Read`
- the skill reproduces the bug before patching
- the skill calls `get_editing_context` before editing target files
- the skill creates or tightens a failing regression test
- the skill runs:
  - `detect_changes`
  - `get_test_targets`
  - `check_guards`
  - `analyze kind=dead_code`
  - `contracts action=check`
  - `feedback action=record`
- the skill invokes `/verification-before-completion`
- the skill invokes `/requesting-code-review`
- the skill optionally invokes `/qa` or `/cso` only when relevant
- headless `claude -p '/morpheus-fix-my-bug ...'` works without `--bare`

### Minimal CI checklist

- use a deterministic fixture repo with a known failing bug
- ensure the repo already trusts the project MCP server or pre-approves it via settings
- do not use `--bare`
- run a headless `/morpheus-fix-my-bug` invocation
- assert that the regression test exists and passes after the fix
- assert that verification commands are green
- archive:
  - bug reproduction output
  - changed-symbol diagnostics
  - test target list
  - guard results
  - dead-code analysis output
  - contract-check output
- fail the job if:
  - the server is not approved,
  - Gortex has zero nodes,
  - the bug was patched without a failing reproduction,
  - post-fix diagnostics were skipped,
  - or the worktree/orchestrator hand-off contract was not met

## Changelog

- **2026-05-14** — initial community draft of the Gortex-informed bug-fix skill for Claude Code
