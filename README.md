# morpheus-fix-my-bug

A Claude Code skill that fixes bugs using Gortex (code knowledge graph) + Superpowers (debugging, TDD, verification, review) + GStack (QA/security).

## Quick setup

Clone this repo into a machine that has Claude Code, then run:

```bash
./setup.sh
```

The script installs Gortex, starts the daemon, tracks the repo, and copies the skill. It will tell you if Superpowers or GStack still need to be installed manually inside Claude Code.

---

## Manual setup (step by step)

### Step 1 — Install Gortex (once per machine)

```bash
curl -fsSL https://get.gortex.dev | sh
gortex install --start --track
```

### Step 2 — Install Superpowers and GStack (once per machine)

Follow the install instructions for:
- [Superpowers](https://superpowers.so) — provides `/systematic-debugging`, `/test-driven-development`, `/verification-before-completion`, `/requesting-code-review`
- [GStack](https://gstack.so) — provides `/qa` and `/cso` for UI and security review

### Step 3 — Copy the skill into your repository

```bash
mkdir -p .claude/skills/morpheus-fix-my-bug
cp /path/to/bug-fixer/.claude/skills/morpheus-fix-my-bug/SKILL.md \
   .claude/skills/morpheus-fix-my-bug/SKILL.md
```

### Step 4 — Start the Gortex daemon and track the repo

```bash
gortex daemon start --detach
gortex track .
```

### To check the gortex running status
```bash
gortex daemon status
```

Verify indexing is working:

```bash
gortex status --index .
```

You should see non-zero nodes and edges. If you see zero nodes, wait a moment and re-run — indexing runs in the background.

### Step 5 — Open Claude Code and confirm the skill loaded

```
/skills
```

You should see `morpheus-fix-my-bug` in the list.

### Step 6 — Run it

```
/morpheus-fix-my-bug KAN-229
/morpheus-fix-my-bug "500 on POST /auth/login when MFA is enabled"
/morpheus-fix-my-bug "failing test: spec/requests/reset_password_spec.rb:42"
/morpheus-fix-my-bug "stack trace: NullPointerException in PaymentRetryJob after deploy"
```

Headless (CI / RalphLoop workers):

```bash
claude -p '/morpheus-fix-my-bug "500 on POST /auth/login when MFA is enabled"'
```

Do not use `--bare` — it skips skill and hook loading.

---

## What the skill does

| Stage | Tool |
|---|---|
| Orient | Gortex `get_repo_outline` / `graph_stats` / `plan_turn` / `smart_context` |
| Reproduce | Superpowers `/systematic-debugging` |
| Localise | Gortex `search_symbols`, `find_usages`, `get_call_chain`, `get_symbol_source` |
| Lock regression | Superpowers `/test-driven-development` |
| Fix | Narrowest code change only |
| Post-fix diagnostics | Gortex `detect_changes`, `get_test_targets`, `check_guards`, `analyze`, `contracts` |
| Verify | Superpowers `/verification-before-completion` |
| Review | Superpowers `/requesting-code-review` |
| QA / security (optional) | GStack `/qa` or `/cso` |
| Escalation (last resort) | GSD `/gsd-debug` for multi-session bugs only |

---

## Troubleshooting

| Problem | Fix |
|---|---|
| `/skills` does not show `morpheus-fix-my-bug` | Check `.claude/skills/morpheus-fix-my-bug/SKILL.md` exists and reload Claude Code |
| Gortex errors / zero nodes | Run `gortex track .` then `gortex status --index .` |
| Daemon not running | `gortex daemon start --detach` |
| Superpowers skill not found | Install Superpowers globally and confirm with `/skills` |
| GStack skill not found | Install GStack globally and confirm with `/skills` |


