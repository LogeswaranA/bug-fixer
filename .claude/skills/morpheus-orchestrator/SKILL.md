---
name: morpheus-orchestrator
description: Multi-bug batch orchestrator. Resolves a list of bug IDs (directly or via JQL), creates isolated git worktrees, runs morpheus-worker sessions in a slot-based pool, opens PRs for fixed bugs, and prints a summary report. Spawned by morpheus-fix-bug-using-gitnexus when two or more IDs or --jql is provided.
when_to_use: Invoked by morpheus-fix-bug-using-gitnexus when multiple bug IDs or --jql is provided. Not invoked directly by users.
argument-hint: "[issue-id ...] | --jql \"<JQL query>\" | --parallel <N>"
disable-model-invocation: true
user-invocable: false
---

## Orchestrator mode

### Step 1 — Resolve bug list

- If IDs were provided directly, use them as-is.
- If `--jql` was provided, call the Jira MCP tool with the JQL to retrieve the list of issue keys.
  - Abort with a clear error if the query returns zero results or the API is unreachable.
  - If Jira MCP is unavailable, abort and tell the user to provide issue IDs directly.

### Step 2 — Prepare worktrees

For each bug ID, create an isolated git worktree and branch:

```bash
git worktree add .worktrees/<issue-id> -b fix/<issue-id>
```

- Branch name convention: `fix/<issue-id>` (e.g. `fix/JIRA-101`)
- Worktree path: `.worktrees/<issue-id>`
- If `.worktreeinclude` exists, apply it to each worktree so gitignored local files (`.env`, secrets) are available.
- If a worktree already exists: skip creation, reuse it, and warn the user.

### Step 3 — Spawn workers using a slot-based queue

**Do not spawn all bugs at once.** Use a sliding window pool: keep exactly `--parallel N` workers running, starting the next bug the moment a slot frees.

```bash
#!/usr/bin/env bash
PARALLEL=${PARALLEL:-5}
BUGS=($@)
declare -A PID_BUG
QUEUE=("${BUGS[@]}")

start_worker() {
  local bug=$1
  (cd ".worktrees/$bug" && claude -p "/morpheus-fix-bug-using-gitnexus $bug" \
    > ".worktrees/$bug/.worker.log" 2>&1) &
  PID_BUG[$!]=$bug
  echo "[$(date +%H:%M:%S)] STARTED $bug (PID $!)"
}

while [[ ${#PID_BUG[@]} -lt $PARALLEL && ${#QUEUE[@]} -gt 0 ]]; do
  start_worker "${QUEUE[0]}"; QUEUE=("${QUEUE[@]:1}")
done

while [[ ${#PID_BUG[@]} -gt 0 ]]; do
  wait -n
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
- At any moment exactly N workers run — no idle slots, no burst
- macOS/Linux: uses `wait -n` (bash 4.3+). On older bash: replace `wait -n` with `sleep 2`
- Each worker's stdout goes to `.worktrees/<id>/.worker.log`
- Each worker's Stop hook gates it independently

### Scaling guidance

| Bugs | Recommended `--parallel` | RAM needed | Notes |
|---|---|---|---|
| ≤ 10 | 5 (default) | ~2 GB | No changes needed |
| 11–20 | 8 | ~4 GB | Safe on most dev machines |
| 21–30 | 10 | ~5 GB | Recommended for 30-bug batches |
| > 30 | 10–15 | ~6–8 GB | Cap at 15; beyond that API rate limits dominate |

Refuse if the user passes `--parallel > 30` — explain the resource cost.

**`--parallel` is a resource budget, not a thread count.** Choose based on available RAM and API tier.

### Step 4 — Monitor workers

Poll or stream each worker's exit status. Record for each:

- `status`: `fixed` | `failed` | `blocked` (Stop hook rejected) | `skipped`
- `branch`: `fix/<issue-id>`
- `test_result`: pass / fail / not-run
- `pr_url`: filled in step 5

### Step 5 — Open PRs for successful workers

For each worker with `status: fixed`:

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

Print when all workers finish. Read timing and token totals from each worker's `.morpheus-telemetry.json` and test counts from `.morpheus-qa.json`:

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
- **Tests (+add)**: total test count after fix, with net new tests in parentheses
- **Fail→0?**: failed-test count before and after the fix; `✓` means failures reached zero

If OTEL is enabled, print each worker's trace URL beneath the table.
For `failed` or `blocked` workers, include the failure reason beneath the table.

### Step 7 — Cleanup

Remove worktrees for completed workers only (leave failed/blocked for inspection):

```bash
git worktree remove .worktrees/<issue-id>
```

---

## Orchestrator non-negotiable rules

- Do **not** merge worktree branches automatically — PRs are the merge gate.
- Do **not** skip PR creation for successful workers — the report PR URL must be filled.
- Do **not** delete failed or blocked worktrees — leave them for human inspection.
- Default slot pool is 5. Raise with `--parallel N`. Hard limit is 30.
- Do **not** spawn all bugs simultaneously — always use the slot-based queue.
- If Jira MCP is unavailable for `--jql` mode, abort and tell the user to provide IDs directly.
- If PR creation fails for a bug, log the failure and continue — do not skip the summary report.

---

## Orchestrator mode diagram

```mermaid
flowchart TD
    A[/morpheus-orchestrator args/] --> B{Mode detection}
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

## Examples

### Multiple IDs

```text
User: /morpheus-fix-bug-using-gitnexus JIRA-101 JIRA-102 JIRA-103 JIRA-104 JIRA-105

- Detect 5 IDs — orchestrator mode
- git worktree add .worktrees/JIRA-101 -b fix/JIRA-101  (× 5)
- Spawn 5 parallel headless workers (slot pool = 5)
- Monitor exit status of all 5 workers
- gh pr create for each successful worker
- Print summary report
- git worktree remove for fixed/succeeded worktrees
```

### JQL mode

```text
User: /morpheus-fix-bug-using-gitnexus --jql "project=KAN AND sprint='Sprint 42' AND type=Bug AND priority=High"

- Detect --jql flag — fetch bug list from Jira
- Jira returns: JIRA-101, JIRA-102, JIRA-103 (3 bugs)
- Proceed with worktree + worker creation for each
```

### With --parallel

```bash
/morpheus-fix-bug-using-gitnexus --jql "project=KAN AND type=Bug" --parallel 10
/morpheus-fix-bug-using-gitnexus JIRA-1 JIRA-2 ... JIRA-30 --parallel 10
```
