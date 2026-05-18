---
name: morpheus-fix-bug-using-gitnexus
description: Reproduce, localise, fix, verify, and review a bug by using GitNexus as the code knowledge base and Superpowers as the bug-fix engine.
when_to_use: Use for regressions, failing tests, stack traces, incident follow-up, flaky behaviour, or unexpected runtime errors in an indexed repository. Accepts an issue ID, failing command, failing test, stack trace, log excerpt, or plain-language bug summary.
argument-hint: "[issue-id...] | --jql \"<JQL query>\" | --parallel <N> | [issue-id|bug-summary|failing-test|stack-trace]"
arguments:
  - bug
  - bugs
  - jql
  - parallel
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
| `--parallel N` | Set slot pool size (default: 5, recommended max: 15, hard limit: 30) |

`--parallel` can be combined with any orchestrator invocation:
```bash
/morpheus-fix-bug-using-gitnexus --jql "project=KAN AND type=Bug" --parallel 10
/morpheus-fix-bug-using-gitnexus JIRA-1 JIRA-2 ... JIRA-30 --parallel 10
```

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

### Step 3 — Spawn workers using a slot-based queue

**Do not spawn all bugs at once.** Use a sliding window pool: keep exactly `--parallel N` workers running at all times, starting the next bug from the queue the moment a slot frees. This handles 30+ bugs without OOM or API rate limit errors.

Use `.claude/hooks/morpheus-orchestrator.sh` (see Install section) or implement inline:

```bash
#!/usr/bin/env bash
# Slot-based worker pool for large bug batches
PARALLEL=${PARALLEL:-5}
BUGS=($@)           # array of issue IDs
declare -A PID_BUG  # pid → issue-id
QUEUE=("${BUGS[@]}")

start_worker() {
  local bug=$1
  (cd ".worktrees/$bug" && claude -p "/morpheus-fix-bug-using-gitnexus $bug" \
    > ".worktrees/$bug/.worker.log" 2>&1) &
  PID_BUG[$!]=$bug
  echo "[$(date +%H:%M:%S)] STARTED $bug (PID $!)"
}

# Seed initial slots
while [[ ${#PID_BUG[@]} -lt $PARALLEL && ${#QUEUE[@]} -gt 0 ]]; do
  start_worker "${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
done

# Drain queue — refill a slot each time any worker exits
while [[ ${#PID_BUG[@]} -gt 0 ]]; do
  wait -n   # wait for any one child to finish (bash 4.3+)
  for pid in "${!PID_BUG[@]}"; do
    if ! kill -0 "$pid" 2>/dev/null; then
      bug="${PID_BUG[$pid]}"
      code=$(wait "$pid" 2>/dev/null; echo $?)
      echo "[$(date +%H:%M:%S)] DONE $bug exit=$code"
      unset PID_BUG[$pid]
      if [[ ${#QUEUE[@]} -gt 0 ]]; then
        start_worker "${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
      fi
      break
    fi
  done
done
echo "All workers finished."
```

Key properties:
- At any moment exactly N workers run — no idle slots, no burst of 30 simultaneous processes
- macOS/Linux: uses `wait -n` (bash 4.3+). On older bash: replace `wait -n` with `sleep 2`
- Each worker's stdout goes to `.worktrees/<id>/.worker.log` for post-run inspection
- Each worker's Stop hook still gates it independently

### Scaling guidance

| Bugs | Recommended `--parallel` | RAM needed | Notes |
|---|---|---|---|
| ≤ 10 | 5 (default) | ~2 GB | No changes needed |
| 11–20 | 8 | ~4 GB | Safe on most dev machines |
| 21–30 | 10 | ~5 GB | Recommended for 30-bug batches |
| > 30 | 10–15 | ~6–8 GB | Cap at 15; beyond that API rate limits dominate |

**Why not spawn all 30 at once?**
- Each `claude` process uses ~150–300 MB RAM → 30 × 300 MB = 9 GB peak
- 30 concurrent sessions saturate Anthropic API concurrency limits, causing retries that slow everyone down
- A pool of 10 finishes 30 bugs nearly as fast (bugs average 3–5 min; wall time ≈ 10 min vs 5 min for true 30-parallel)

**`--parallel` is not a thread count — it is a resource budget.** Choose it based on available RAM and API tier, not the number of bugs.

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

Print a table when all workers finish. Include timing and token totals read from each worker's `.morpheus-telemetry.json`:

```
┌──────────┬─────────┬──────────────┬──────────────┬───────────────┬────────────────────┬──────────────────────────────────┐
│ Issue    │ Status  │ Tests (+add) │ Fail→0?      │ Duration      │ Tokens (total)     │ PR                               │
├──────────┼─────────┼──────────────┼──────────────┼───────────────┼────────────────────┼──────────────────────────────────┤
│ JIRA-101 │ fixed   │ 143 (+1)     │ 1→0  ✓       │ 2m 37s        │ 170,880            │ https://github.com/.../pull/42   │
│ JIRA-102 │ fixed   │  89 (+2)     │ 2→0  ✓       │ 4m 12s        │ 234,120            │ https://github.com/.../pull/43   │
│ JIRA-103 │ failed  │  —           │  —           │ 1m 08s        │  89,400            │ —                                │
│ JIRA-104 │ blocked │  —           │  —           │     22s       │  14,700            │ —  (Stop hook: missing repro)    │
│ JIRA-105 │ fixed   │ 201 (+1)     │ 3→0  ✓       │ 3m 55s        │ 198,560            │ https://github.com/.../pull/44   │
├──────────┼─────────┼──────────────┼──────────────┼───────────────┼────────────────────┼──────────────────────────────────┤
│ TOTAL    │ 3 fixed │ +4 tests     │ 6→0          │ 12m 14s       │ 707,660            │                                  │
└──────────┴─────────┴──────────────┴──────────────┴───────────────┴────────────────────┴──────────────────────────────────┘
```

Column definitions:
- **Tests (+add)**: total test count after fix, with net new tests in parentheses (from `.morpheus-qa.json`)
- **Fail→0?**: failed-test count before and after the fix; `✓` means failures reached zero

If OTEL is enabled, also print each worker's trace URL beneath the table.

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
- Default slot pool is 5. Raise with `--parallel N`. Hard limit is 30 — refuse if the user passes `--parallel > 30` and explain the resource cost.
- Do **not** spawn all bugs simultaneously — always use the slot-based queue regardless of `--parallel` value.
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
    F --> G[Slot pool — N workers max]
    G --> H1[Slot 1: JIRA-101]
    G --> H2[Slot 2: JIRA-102]
    G --> H3[Slot N: JIRA-X]
    H1 -->|done, refill slot| H4[Next from queue]
    H1 & H2 & H3 & H4 --> I[Monitor exit status]
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
- Do **not** end the session without printing the MORPHEUS TELEMETRY SUMMARY block followed by the QA ARTIFACT SUMMARY block — these are the last two visible outputs before the Stop hook runs, every time, without exception.
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

Before any source reading, code editing, or test-writing, enforce this contract in order:

**Step 0 — Pre-flight: verify `.mcp.json` has a `gitnexus` entry**

Check whether `.mcp.json` exists in the repo root AND contains a `gitnexus` key under `mcpServers`.

```bash
cat .mcp.json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print('ok' if 'gitnexus' in d.get('mcpServers',{}) else 'missing')" 2>/dev/null || echo "missing"
```

- If the result is `missing`: **STOP immediately.** Do not proceed. Print this message and wait for the user to fix it:

  ```
  ✗ GitNexus MCP is not configured in .mcp.json.
  
  Add this to your .mcp.json (create the file if it does not exist):
  
  {
    "mcpServers": {
      "gitnexus": {
        "command": "npx",
        "args": ["-y", "gitnexus@latest", "mcp"]
      }
    }
  }
  
  Then re-run: npx gitnexus analyze
  Then restart Claude Code so the MCP server is approved and connected.
  Then re-invoke this skill.
  ```

- If the result is `ok`: continue to step 1.

**Do not proceed to degraded mode when the fix is a missing config file.** Degraded mode is only for when `.mcp.json` is correct but the server is transiently unavailable (network error, process crash, etc.).

1. Call `gitnexus_list_repos()` — verify the index is non-empty. If empty, run `npx gitnexus analyze` and re-check before continuing.
2. Call `gitnexus_query({query: "<bug summary>"})` — broad orientation, find candidate symbols.
3. Call `gitnexus_context({name: "<top candidate>"})` — assemble relevant context bundle.
4. Use GitNexus tools to localise the likely root-cause area.
5. Before editing each target file, call `gitnexus_context` on the target symbol.
6. Prefer `gitnexus_query` + `gitnexus_context` over whole-file reads.
7. Only fall back to `Read`, `Grep`, or `Glob` when `.mcp.json` is correct but the server is transiently unavailable.

### Main fix loop

| Stage | Required action | Output needed before continuing |
|---|---|---|
| Orient | `gitnexus_list_repos()` | non-empty index confirmed |
| Assemble context | `gitnexus_query({query: "<bug area>"})` | candidate symbols |
| Reproduce | `/systematic-debugging` | exact bug reproduction or smallest failing case |
| Localise | `gitnexus_query`, `gitnexus_context` (incoming + outgoing refs), `gitnexus_impact(upstream)` | root-cause candidate with evidence |
| Prepare edit | `gitnexus_context({name: "<target symbol>"})` | callers, deps, process participation |
| Lock regression | `/test-driven-development` | failing regression test + `suite_before_fix` captured in `.morpheus-qa.json` |
| Fix | narrow code change only | test now passes locally; `tests_modified` updated in `.morpheus-qa.json` |
| Diagnose change | `gitnexus_detect_changes({scope: "staged"})` | changed symbols + affected processes |
| Verify impact | `gitnexus_impact(upstream)` + `gitnexus_impact(downstream)` | blast radius confirmed |
| API check | `gitnexus_api_impact` (if routes changed) | route consumers identified |
| Contract check | `gitnexus_group_contracts` (if multi-repo) | cross-repo breakage ruled out |
| Verify | `/verification-before-completion` | fresh green evidence + `suite_after_fix` + coverage captured in `.morpheus-qa.json` |
| Review | `/requesting-code-review` | review findings and follow-up actions |
| **Emit summaries** | **MANDATORY — do not skip** | print MORPHEUS TELEMETRY SUMMARY block (see `## Telemetry`), then print QA ARTIFACT SUMMARY block (see `## QA Artifacts`); both must appear in the session output before the Stop hook runs |

**QA artifact checkpoints** — update `.morpheus-qa.json` at these specific stages:

| Stage | What to write |
|---|---|
| Lock regression | `regression_test` (file, name, framework), `tests_added` list, `suite_before_fix` (total/pass/fail/skip) |
| Fix | `tests_modified` list (any existing tests tightened) |
| Verify | `suite_after_fix` (total/pass/fail/skip/duration), `coverage` delta if tool available |
| Review | `ui_qa` result (invoked or skipped + reason), `security_qa` result (invoked or skipped + reason) |

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
    Q --> R[EMIT: MORPHEUS TELEMETRY SUMMARY block]
    R --> S[EMIT: QA ARTIFACT SUMMARY block]
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

## Telemetry

### What is tracked

Each invocation records three dimensions per stage:

| Dimension | What | How |
|---|---|---|
| **Wall-clock time** | Duration of each stage in milliseconds | `date +%s%3N` at start and end of each stage |
| **Token consumption** | Input, output, and cache tokens per stage | Parsed from `--output-format stream-json` in headless mode; self-reported JSON markers in interactive mode |
| **OTEL spans** | One root span per bug, one child span per stage | `otel-cli span create` — requires `otel-cli` to be installed |

---

### Timing

At the **start of each stage**, record the stage name and millisecond epoch:

```bash
STAGE_NAME="orient"
STAGE_START_MS=$(date +%s%3N)
```

At the **end of each stage**, compute duration and write to the telemetry state file:

```bash
STAGE_END_MS=$(date +%s%3N)
STAGE_DURATION_MS=$((STAGE_END_MS - STAGE_START_MS))
jq --arg stage "$STAGE_NAME" \
   --argjson start "$STAGE_START_MS" \
   --argjson end "$STAGE_END_MS" \
   --argjson dur  "$STAGE_DURATION_MS" \
   '.stages[$stage] |= . + {start_ms: $start, end_ms: $end, duration_ms: $dur}' \
   .morpheus-telemetry.json > .morpheus-telemetry.tmp.json \
   && mv .morpheus-telemetry.tmp.json .morpheus-telemetry.json
```

Apply this pattern to every stage in the main fix loop: **Orient, Assemble context, Reproduce, Localise, Prepare edit, Lock regression, Fix, Diagnose change, Verify impact, API check, Contract check, Verify, Review**.

---

### Token tracking

**Headless mode** — run with `--output-format stream-json` to receive `usage` events:

```bash
claude --output-format stream-json -p '/morpheus-fix-bug-using-gitnexus KAN-229' \
  | tee session-raw.ndjson
```

Each `usage` event in the stream looks like:

```json
{
  "type": "usage",
  "input_tokens": 12400,
  "output_tokens": 2100,
  "cache_read_input_tokens": 9800,
  "cache_creation_input_tokens": 600
}
```

Accumulate delta usage across events to attribute tokens to the stage that was active when the event was emitted. Store per-stage sums in `.morpheus-telemetry.json`.

**Interactive mode** — after each stage completes, emit a machine-readable JSON marker on a single line (this can be parsed from the session log later):

```json
{"morpheus_telemetry": true, "stage": "<stage-name>", "tokens": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0}}
```

---

### OpenTelemetry

Yes, OTEL tracing is supported via [`otel-cli`](https://github.com/equinix-labs/otel-cli) — a lightweight Go binary that creates OTLP spans from the shell with no SDK required.

**Check availability at session start:**

```bash
OTEL_ENABLED=$(which otel-cli >/dev/null 2>&1 && echo "true" || echo "false")
```

**Configure the exporter** (add to `.env` or shell profile):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT:-http://localhost:4317}"
export OTEL_SERVICE_NAME="morpheus-bug-fixer"
# Optional auth header:
# export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>"
```

**Root span** — create at session start and write the traceparent to a carrier file:

```bash
TRACEPARENT_FILE=".morpheus-traceparent"

if [ "$OTEL_ENABLED" = "true" ]; then
  otel-cli span background \
    --service "morpheus-bug-fixer" \
    --name "bug-fix/<issue-id>" \
    --attrs "bug.id=<issue-id>,bug.source=<jira|cli|stack_trace|test|text>,git.branch=$(git rev-parse --abbrev-ref HEAD)" \
    --tp-print \
    --tp-carrier "$TRACEPARENT_FILE"
fi
```

**Per-stage child span** — create after each stage with timing and token attributes:

```bash
if [ "$OTEL_ENABLED" = "true" ]; then
  otel-cli span create \
    --service "morpheus-bug-fixer" \
    --name "stage/$STAGE_NAME" \
    --tp-required \
    --tp-carrier "$TRACEPARENT_FILE" \
    --attrs "stage.duration_ms=$STAGE_DURATION_MS,stage.tokens_in=$TOKENS_IN,stage.tokens_out=$TOKENS_OUT,stage.cache_read=$TOKENS_CACHE_READ,stage.cache_write=$TOKENS_CACHE_WRITE"
fi
```

**Span attribute conventions:**

| Attribute | Value |
|---|---|
| `bug.id` | Jira/GitHub issue key |
| `bug.source` | `jira`, `cli`, `stack_trace`, `test`, `text` |
| `stage.name` | stage name from the fix loop |
| `stage.duration_ms` | integer milliseconds |
| `stage.tokens_in` | input tokens for this stage |
| `stage.tokens_out` | output tokens for this stage |
| `stage.cache_read` | cache-read tokens for this stage |
| `stage.cache_write` | cache-write tokens for this stage |
| `fix.result` | `fixed`, `failed`, `blocked`, `skipped` |
| `git.branch` | current branch |
| `gitnexus.repos_indexed` | repo count from `gitnexus_list_repos` |

**If `otel-cli` is not installed**, skip span creation silently — telemetry falls back to the JSON state file only. Do not block the fix workflow.

---

### Telemetry state file

Initialise `.morpheus-telemetry.json` in the worktree root (or repo root in interactive mode) at session start:

```json
{
  "schema_version": "1",
  "bug_id": "<issue-id>",
  "trace_id": null,
  "session_start_ms": 0,
  "stages": {},
  "totals": {}
}
```

Fill in `trace_id` from the root span's traceparent if OTEL is enabled, and `session_start_ms` from `$(date +%s%3N)`.

---

### Telemetry summary block

After the Review stage and **before the Stop hook runs**, print this summary. Values come from `.morpheus-telemetry.json`:

```
╔════════════════════════════════════════════════════════════════════════════╗
║               MORPHEUS TELEMETRY SUMMARY — JIRA-101                       ║
╠═══════════════════════╦══════════════╦═══════════════════════════════════╣
║ Stage                 ║ Duration     ║ Tokens (in / out / cache)         ║
╠═══════════════════════╬══════════════╬═══════════════════════════════════╣
║ Orient                ║  1,234 ms    ║   2,100 /   340 /  1,500          ║
║ Assemble context      ║  2,890 ms    ║   5,400 /   620 /  4,200          ║
║ Reproduce             ║ 45,210 ms    ║  18,200 / 3,400 / 12,100          ║
║ Localise              ║  8,320 ms    ║   7,800 / 1,200 /  6,400          ║
║ Prepare edit          ║  3,100 ms    ║   4,200 /   580 /  3,800          ║
║ Lock regression       ║ 32,450 ms    ║  14,300 / 2,800 / 11,200          ║
║ Fix                   ║  6,780 ms    ║   3,400 /   920 /  2,800          ║
║ Diagnose change       ║  2,100 ms    ║   2,800 /   440 /  2,400          ║
║ Verify impact         ║  4,560 ms    ║   4,100 /   680 /  3,600          ║
║ API check             ║  1,890 ms    ║   2,200 /   380 /  1,900          ║
║ Contract check        ║    890 ms    ║   1,100 /   220 /    900          ║
║ Verify                ║ 28,340 ms    ║  12,400 / 2,100 /  9,800          ║
║ Review                ║ 19,670 ms    ║   9,600 / 1,800 /  7,200          ║
╠═══════════════════════╬══════════════╬═══════════════════════════════════╣
║ TOTAL                 ║ 157,434 ms   ║  87,600 / 15,480 / 67,800         ║
║                       ║  (2m 37s)    ║  Combined total: 170,880 tokens   ║
╠═══════════════════════╩══════════════╩═══════════════════════════════════╣
║ OTEL Trace ID: 4bf92f3577b34da6a3ce929d0e0e4736                          ║
║ Trace URL:     http://localhost:16686/trace/4bf92f3577b34da6a3ce929d0e0e4736 ║
╚════════════════════════════════════════════════════════════════════════════╝
```

Omit the `OTEL Trace ID` and `Trace URL` rows if OTEL is not configured.

---

## QA Artifacts

### Purpose

After every invocation, produce a `.morpheus-qa.json` artifact that records what tests were created, the full test suite state before and after the fix, coverage delta, and whether UI or security QA was performed.

This answers: *"What tests prove this fix is correct, how many test cases exist now, and how complete is the coverage?"*

---

### QA state file

Initialise `.morpheus-qa.json` in the worktree root at session start:

```json
{
  "schema_version": "1",
  "bug_id": "<issue-id>",
  "regression_test": null,
  "tests_added": [],
  "tests_modified": [],
  "suite_before_fix": null,
  "suite_after_fix": null,
  "coverage": null,
  "ui_qa": null,
  "security_qa": null
}
```

---

### Recording at each QA stage

#### At "Lock regression" (`/test-driven-development`)

After the failing regression test is written, record the test metadata and run the full suite to capture the **before-fix baseline**:

```bash
# 1. Update regression_test and tests_added in .morpheus-qa.json
jq '.regression_test = {
      "file": "tests/auth/test_login.py",
      "test_name": "test_mfa_login_500_regression",
      "framework": "pytest",
      "was_failing_before_fix": true
    } |
    .tests_added = [{
      "file": "tests/auth/test_login.py",
      "test_name": "test_mfa_login_500_regression",
      "type": "regression"
    }]' .morpheus-qa.json > .morpheus-qa.tmp.json && mv .morpheus-qa.tmp.json .morpheus-qa.json

# 2. Run full suite and capture baseline — adapt to the project's test runner:

# Python (pytest):
#   pytest --tb=no -q 2>&1 | tail -1

# JavaScript/TypeScript (jest/vitest):
#   npx jest --passWithNoTests --json 2>/dev/null | jq '{total:.numTotalTests, passed:.numPassedTests, failed:.numFailedTests, skipped:.numPendingTests}'

# C# (.NET / xUnit / NUnit / MSTest):
#   dotnet test --no-build --logger "trx;LogFileName=results.trx" 2>&1
#   # Parse counts from trx or from stdout: "Passed: N, Failed: N, Skipped: N"

# Go:
#   go test ./... -v 2>&1 | grep -E "^(ok|FAIL|---)"

# Java (Maven):
#   mvn test -q 2>&1 | grep -E "Tests run:"

# 3. Write suite_before_fix (replace <n> with actual counts)
jq '.suite_before_fix = {"total": <n>, "passed": <n>, "failed": <n>, "skipped": <n>, "duration_ms": <n>, "command": "<test command>"}' \
   .morpheus-qa.json > .morpheus-qa.tmp.json && mv .morpheus-qa.tmp.json .morpheus-qa.json
```

**Do not proceed to the Fix stage if `suite_before_fix` is null** — the before baseline must exist.

#### At "Fix" (after narrow code change)

If any existing test had to be modified or tightened to accommodate the fix, record it:

```bash
jq '.tests_modified = [{"file": "<path>", "test_name": "<name>", "change": "<why it changed>"}]' \
   .morpheus-qa.json > .morpheus-qa.tmp.json && mv .morpheus-qa.tmp.json .morpheus-qa.json
```

If no existing tests changed, leave `tests_modified` as `[]`.

#### At "Verify" (`/verification-before-completion`)

Run the full suite and capture the **after-fix result**. Also capture coverage if the project has a coverage tool:

```bash
# Run suite and write suite_after_fix
jq '.suite_after_fix = {"total": <n>, "passed": <n>, "failed": <n>, "skipped": <n>, "duration_ms": <n>}' \
   .morpheus-qa.json > .morpheus-qa.tmp.json && mv .morpheus-qa.tmp.json .morpheus-qa.json

# Coverage delta (adapt to tooling)
#   Python (pytest-cov):
#     pytest --cov=. --cov-report=json -q 2>/dev/null
#     AFTER_PCT=$(python3 -c "import json; print(json.load(open('coverage.json'))['totals']['percent_covered_display'])")
#
#   JavaScript (nyc/jest):
#     AFTER_PCT=$(npx jest --coverage --coverageReporters=json-summary 2>/dev/null | \
#       jq -r '.total.lines.pct' coverage/coverage-summary.json)
#
#   C# (dotnet-coverage / coverlet):
#     dotnet test --collect:"XPlat Code Coverage" 2>/dev/null
#     AFTER_PCT=$(python3 -c "
#     import xml.etree.ElementTree as ET, glob
#     f = sorted(glob.glob('**/coverage.cobertura.xml', recursive=True))[-1]
#     root = ET.parse(f).getroot()
#     print(round(float(root.attrib.get('line-rate','0'))*100,1))")
#
#   Go (go tool cover):
#     go test ./... -coverprofile=coverage.out 2>/dev/null
#     AFTER_PCT=$(go tool cover -func=coverage.out | awk '/total/{print $3}' | tr -d %)

jq --arg before "<before_pct>" --arg after "$AFTER_PCT" \
   '.coverage = {"before_pct": ($before | tonumber), "after_pct": ($after | tonumber),
                 "delta_pct": (($after | tonumber) - ($before | tonumber))}' \
   .morpheus-qa.json > .morpheus-qa.tmp.json && mv .morpheus-qa.tmp.json .morpheus-qa.json
```

If coverage tooling is unavailable, set `"coverage": null`.

#### After GStack `/qa` (UI QA — optional)

```bash
jq '.ui_qa = {
      "invoked": true,
      "result": "pass",
      "scenarios_tested": ["<scenario 1>", "<scenario 2>"],
      "screenshots": ["qa/screenshots/<name>.png"]
    }' .morpheus-qa.json > .morpheus-qa.tmp.json && mv .morpheus-qa.tmp.json .morpheus-qa.json
```

If not invoked: `{"invoked": false, "reason": "no UI changes in this fix"}`.

#### After GStack `/cso` (security review — optional)

```bash
jq '.security_qa = {"invoked": true, "result": "pass", "findings": []}' \
   .morpheus-qa.json > .morpheus-qa.tmp.json && mv .morpheus-qa.tmp.json .morpheus-qa.json
```

If not invoked: `{"invoked": false, "reason": "no auth/security surface changed"}`.

---

### QA summary block

After the telemetry summary and before the Stop hook, print the QA summary. Values come from `.morpheus-qa.json`:

```
╔══════════════════════════════════════════════════════════════════╗
║                QA ARTIFACT SUMMARY — JIRA-101                   ║
╠══════════════════════════════════════════════════════════════════╣
║ Regression test                                                  ║
║   File:       tests/auth/test_login.py                          ║
║   Test name:  test_mfa_login_500_regression                     ║
║   Framework:  pytest                                             ║
╠═══════════════════════╦══════════════════════════════════════════╣
║ Test cases             ║ Added: 1   Modified: 0   Deleted: 0    ║
╠═══════════╦════════════╬══════════════════╦═══════════════════════╣
║ Suite     ║ Before fix ║ After fix        ║ Delta                ║
╠═══════════╬════════════╬══════════════════╬═══════════════════════╣
║ Total     ║ 142        ║ 143              ║ +1                   ║
║ Passed    ║ 141        ║ 143              ║ +2                   ║
║ Failed    ║   1        ║   0              ║ -1  ✓                ║
║ Skipped   ║   2        ║   2              ║  0                   ║
║ Duration  ║ 14.2 s     ║ 14.8 s           ║ +0.6 s               ║
╠═══════════╬════════════╬══════════════════╬═══════════════════════╣
║ Coverage  ║ 78.4%      ║ 79.1%            ║ +0.7%                ║
╠═══════════╩════════════╩══════════════════╩═══════════════════════╣
║ UI QA:        not invoked — no UI changes in this fix            ║
║ Security QA:  not invoked — no auth surface changes              ║
╚══════════════════════════════════════════════════════════════════╝
```

Rendering rules:
- If `suite_before_fix` is null → print `baseline not captured` in the Before column and block at the Stop hook.
- If `coverage` is null → omit the Coverage row entirely.
- If `failed` delta is `0` or positive → flag with `⚠ regression` instead of `✓` and the Stop hook must block.
- If `ui_qa.invoked` is false → print `not invoked — <reason>`.
- If `ui_qa.invoked` is true → print `pass` / `fail` and the scenario count.

---

### QA non-negotiable rules

- Do **not** proceed past Lock regression without capturing `suite_before_fix`.
- Do **not** declare done if `suite_after_fix.failed >= suite_before_fix.failed` — the fix must reduce failures.
- Do **not** skip the QA summary block — print it even if all values are zero.
- The regression test **file and name** must be in `.morpheus-qa.json` before the Stop hook runs.

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

### Project MCP server — REQUIRED

`.mcp.json` at the repository root is **required**. Without it, Claude Code cannot connect to the GitNexus MCP server and the skill will refuse to run (it will not silently degrade).

If your repo already has a `.mcp.json` with other servers (e.g. Jira), merge the `gitnexus` entry in — do not replace the file:

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

Use `.claude/settings.local.json` for machine-specific approval and optional permissions:

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

**Why `Edit(*)`, `Write(*)`, `Read(*)` are required for headless mode**: in `claude -p`, any tool not pre-approved causes Claude to stop and ask for permission — which blocks forever since there's no user watching. Pre-approving file tools is mandatory for unattended runs.

### Stop hook (copy this into the repo's `.claude/settings.json`)

Use a **command hook** rather than a prompt hook. Prompt hooks use a language model to evaluate and will always add prose explanation regardless of instructions. A command hook calls the Anthropic API with `max_tokens=50`, making prose output physically impossible.

**Step 1** — copy the gate script:

```bash
mkdir -p .claude/hooks
# Copy .claude/hooks/morpheus-stop-gate.py from this skill's repo
chmod +x .claude/hooks/morpheus-stop-gate.py
```

The script (`.claude/hooks/morpheus-stop-gate.py`):
- Reads the session context from stdin
- Calls `claude-haiku-4-5-20251001` with `max_tokens=50` — hard cap prevents prose
- Loads `ANTHROPIC_API_KEY` from env or `.env` file automatically
- Truncates session to ~20k chars to stay within token limits
- Falls back to `{"decision":"approve"}` on any error (fail-open)
- Coerces `"allow"` → `"approve"` in case the model uses the wrong word (Claude Code Stop hooks require `"approve"` not `"allow"`)
- Extracts the JSON decision even if stray prose leaks through

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

**Monorepo / subdirectory note**: if your repo has `frontend/` and `backend/` subdirectories, place `.claude/` and `.mcp.json` at the **git root** (not inside `frontend/`). The hook command uses `git rev-parse --show-toplevel` so it resolves the script path from the repo root regardless of which subdirectory Claude is working in. A relative path like `python3 .claude/hooks/...` will break when Claude's CWD is a subdirectory.

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

Add to your `.env` or shell profile to point at your collector (Jaeger, Grafana Tempo, etc.):

```bash
export OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4317"
export OTEL_SERVICE_NAME="morpheus-bug-fixer"
```

If `otel-cli` is absent the skill continues normally — OTEL spans are skipped silently.

---

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

Run from the **git root** (not from a subdirectory):

```bash
# Skill
mkdir -p .claude/skills/morpheus-fix-bug-using-gitnexus
# Copy SKILL.md to .claude/skills/morpheus-fix-bug-using-gitnexus/SKILL.md

# Stop-gate hook
mkdir -p .claude/hooks
# Copy morpheus-stop-gate.py to .claude/hooks/morpheus-stop-gate.py
chmod +x .claude/hooks/morpheus-stop-gate.py
```

For monorepos with `frontend/` or `backend/` subdirectories: keep `.claude/` and `.mcp.json` at the git root. The hook uses `git rev-parse --show-toplevel` so it works regardless of which directory Claude is running in.

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
- `.morpheus-qa.json` is created with `regression_test`, `tests_added`, `suite_before_fix`, `suite_after_fix` all non-null
- `suite_after_fix.failed` is strictly less than `suite_before_fix.failed`
- the QA ARTIFACT SUMMARY block is printed before the Stop hook
- the skill runs `gitnexus_detect_changes`, `gitnexus_impact` (both directions)
- the skill invokes `/verification-before-completion`
- the skill invokes `/requesting-code-review`
- the MORPHEUS TELEMETRY SUMMARY block is printed with per-stage timing and tokens
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

- **2026-05-18** — added QA artifacts: `.morpheus-qa.json` state file tracking regression test metadata, tests added/modified, suite_before_fix and suite_after_fix counts, coverage delta, UI QA and security QA results; QA summary block printed before Stop hook; Stop hook steps 13–14 gate on QA artifact completeness and failed-count delta; orchestrator summary extended with Tests and Fail→0 columns; main fix loop table annotated with QA checkpoint instructions
- **2026-05-18** — added telemetry: per-stage wall-clock timing, token tracking (`--output-format stream-json` + interactive JSON markers), OpenTelemetry span emission via `otel-cli`, telemetry summary block printed before Stop hook, Stop hook step 12 now verifies summary was printed, orchestrator summary table extended with Duration and Tokens columns
- **2026-05-18** — initial port of morpheus-fix-my-bug from Gortex to GitNexus
