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

| Arguments | Mode | Action |
|---|---|---|
| Single ID, summary, stack trace, or test | **Worker mode** | `Skill("morpheus-worker")` |
| Two or more space-separated IDs | **Orchestrator mode** | `Skill("morpheus-orchestrator")` |
| `--jql "<query>"` | **Orchestrator mode** | `Skill("morpheus-orchestrator")` |
| `--parallel N` | Pass through to orchestrator | `Skill("morpheus-orchestrator")` |

Pass all arguments and context through to the delegated skill unchanged.

---

## Non-negotiable rules

- Do **not** begin with blind `Read`, `Grep`, or `Glob` across indexed source files.
- Do **not** patch before reproducing the bug or creating the smallest failing case.
- Do **not** edit a source file before calling `gitnexus_context` for the target symbol.
- Do **not** declare success before running the post-fix GitNexus diagnostic sequence.
- Do **not** skip Superpowers skills — invoke them with the `Skill` tool explicitly, never emulate inline.
- Do **not** rename symbols with find-and-replace — use `gitnexus_rename`.
- Do **not** end the session without printing the MORPHEUS TELEMETRY SUMMARY block followed by the QA ARTIFACT SUMMARY block.
- Do **not** create the comprehensive PR (GSD multi-phase path) until `.morpheus-integration-qa.json` exists with both results set to `"pass"`.
- If running inside a headless worker or git worktree, stay inside the assigned worktree.
- Do **not** run in `claude -p --bare` mode — project skills, hooks, `.mcp.json`, and `CLAUDE.md` will not load.

---

## Skill map

| Skill | Responsibility |
|---|---|
| `morpheus-fix-bug-using-gitnexus` | Entry point and router (this file) |
| `morpheus-worker` | Core single-bug fix workflow |
| `morpheus-orchestrator` | Multi-bug batch mode (worktrees, slot pool, PRs, report) |
| `morpheus-integration-gate` | Mandatory security & QA gate for GSD multi-phase path |

---

## Usage

```bash
# Worker mode (single bug)
/morpheus-fix-bug-using-gitnexus KAN-229
/morpheus-fix-bug-using-gitnexus "500 on POST /auth/login when MFA is enabled"
/morpheus-fix-bug-using-gitnexus "failing test: spec/requests/reset_password_spec.rb:42"
/morpheus-fix-bug-using-gitnexus "stack trace: NullPointerException in PaymentRetryJob after deploy"

# Orchestrator mode (multi-bug)
/morpheus-fix-bug-using-gitnexus JIRA-101 JIRA-102 JIRA-103
/morpheus-fix-bug-using-gitnexus --jql "project=KAN AND sprint='Sprint 42' AND type=Bug AND priority=High"
/morpheus-fix-bug-using-gitnexus --jql "project=KAN AND type=Bug" --parallel 10

# Headless
claude -p '/morpheus-fix-bug-using-gitnexus KAN-229'
claude -p '/morpheus-fix-bug-using-gitnexus JIRA-101 JIRA-102 JIRA-103'
```

---

## Reference

See `REFERENCE.md` in this directory for:
- GitNexus ↔ Gortex tool map
- Failure modes and recovery actions
- MCP config and local settings templates
- Stop hook setup
- Install instructions
- Testing and CI checklist
- Changelog
