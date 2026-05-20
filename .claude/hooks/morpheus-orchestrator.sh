#!/usr/bin/env bash
# morpheus-orchestrator.sh — slot-based worker pool for large bug batches
# Compatible with bash 3.2+ (macOS default shell)
#
# Usage:
#   PARALLEL=10 bash .claude/hooks/morpheus-orchestrator.sh JIRA-1 JIRA-2 ... JIRA-30
#   PARALLEL=10 bash .claude/hooks/morpheus-orchestrator.sh --jql "project=KAN AND type=Bug"
#
# Environment:
#   PARALLEL      — slot pool size (default: 5, max: 30)
#   CLAUDE_FLAGS  — extra flags passed to each `claude -p` invocation

set -euo pipefail

PARALLEL=${PARALLEL:-5}
CLAUDE_FLAGS=${CLAUDE_FLAGS:-}
REPO_ROOT=$(git rev-parse --show-toplevel)
WORKTREES_DIR="$REPO_ROOT/.worktrees"
RESULTS_FILE="$REPO_ROOT/.morpheus-results.json"

# ── Parse args ────────────────────────────────────────────────────────────────

BUGS=()
JQL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --parallel) PARALLEL=$2; shift 2 ;;
    --jql)      JQL=$2;      shift 2 ;;
    *)          BUGS+=("$1"); shift  ;;
  esac
done

if [[ $PARALLEL -gt 30 ]]; then
  echo "ERROR: --parallel $PARALLEL exceeds hard limit of 30." >&2
  echo "       Recommended max: 15. Refusing to proceed." >&2
  exit 1
fi

# ── Resolve bug list from JQL if needed ──────────────────────────────────────

if [[ -n "$JQL" ]]; then
  echo "[orchestrator] Fetching bugs from Jira: $JQL"
  JQL_RESULT=$(claude -p "Call jira_search with jql=\"$JQL\" and return ONLY a newline-separated list of issue keys, nothing else." $CLAUDE_FLAGS 2>/dev/null) || {
    echo "ERROR: Jira fetch failed. Provide issue IDs directly." >&2; exit 1
  }
  while IFS= read -r line; do
    [[ -n "$line" ]] && BUGS+=("$line")
  done <<< "$JQL_RESULT"
fi

if [[ ${#BUGS[@]} -eq 0 ]]; then
  echo "ERROR: No bugs to fix." >&2; exit 1
fi

echo "[orchestrator] ${#BUGS[@]} bugs queued | slot pool: $PARALLEL"
echo "[orchestrator] Queue: ${BUGS[*]}"

# ── Helpers (bash 3.2 compatible — use .pid files instead of associative arrays) ──

mkdir -p "$WORKTREES_DIR"
echo '[]' > "$RESULTS_FILE"

# Sanitise a bug description into a safe directory name
slug() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/-*$//'
}

running_count() {
  local count=0
  local pidfile
  for pidfile in "$WORKTREES_DIR"/*/.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid
    pid=$(cat "$pidfile")
    kill -0 "$pid" 2>/dev/null && count=$((count + 1))
  done
  echo "$count"
}

start_worker() {
  local bug=$1
  local safe
  safe=$(slug "$bug")
  local worktree="$WORKTREES_DIR/$safe"
  local log="$worktree/.worker.log"

  mkdir -p "$worktree"

  # Purge stale state from previous runs so reap_finished isn't fooled
  rm -f "$worktree/.reaped" "$worktree/.exit_code" "$worktree/.end_ms" \
        "$worktree/.start_ms" "$worktree/.pid" \
        "$worktree/.worker.log" "$worktree/.worker-raw.ndjson" "$worktree/.worker-tokens.json"

  # Create git worktree — fall back to checking out existing branch if it already exists
  if [[ ! -f "$worktree/.git" ]] && [[ ! -d "$worktree/.git" ]]; then
    git -C "$REPO_ROOT" worktree add "$worktree" -b "fix/$safe" 2>/dev/null || \
    git -C "$REPO_ROOT" worktree add "$worktree" "fix/$safe" 2>/dev/null || true
  fi

  # Copy untracked project config into worktree so skills, MCP, and CLAUDE.md load
  for _f in .mcp.json CLAUDE.md .claude; do
    [[ -e "$REPO_ROOT/$_f" ]] && cp -r "$REPO_ROOT/$_f" "$worktree/$_f" 2>/dev/null || true
  done

  # Copy gitignored secrets if .worktreeinclude exists
  if [[ -f "$REPO_ROOT/.worktreeinclude" ]]; then
    rsync -a --files-from="$REPO_ROOT/.worktreeinclude" "$REPO_ROOT/" "$worktree/" 2>/dev/null || true
  fi

  # Store the original bug description so we can read it back later
  echo "$bug" > "$worktree/.bug_desc"
  date +%s%3N > "$worktree/.start_ms"

  # Launch worker — claude writes raw stream; live-log tails it in real time
  (
    cd "$worktree"
    claude --verbose --output-format stream-json -p "/morpheus-fix-bug-using-gitnexus $bug" $CLAUDE_FLAGS \
      > .worker-raw.ndjson 2>&1 &
    CLAUDE_PID=$!
    python3 -u "$REPO_ROOT/.claude/hooks/morpheus-live-log.py" "$safe" "$CLAUDE_PID" "$worktree"
    wait $CLAUDE_PID
    echo $? > .exit_code
    date +%s%3N > .end_ms
  ) &

  echo "$!" > "$worktree/.pid"
  echo "[$(date +%H:%M:%S)] STARTED  '$bug'  (slug: $safe, PID $!)"
}

reap_finished() {
  local pidfile
  for pidfile in "$WORKTREES_DIR"/*/.pid; do
    [[ -f "$pidfile" ]] || continue
    local pid worktree bug exit_code status
    pid=$(cat "$pidfile")
    worktree=$(dirname "$pidfile")
    bug=$(cat "$worktree/.bug_desc" 2>/dev/null || basename "$worktree")

    # Still running — skip
    kill -0 "$pid" 2>/dev/null && continue
    # Already reaped — skip
    [[ -f "$worktree/.reaped" ]] && continue

    # Worker finished — record result
    exit_code=$(cat "$worktree/.exit_code" 2>/dev/null || echo "1")
    status=$([[ "$exit_code" == "0" ]] && echo "fixed" || echo "failed")
    touch "$worktree/.reaped"

    echo "[$(date +%H:%M:%S)] FINISHED '$bug'  exit=$exit_code  status=$status"

    # Append to results JSON
    python3 - "$RESULTS_FILE" "$bug" "$status" "$exit_code" "$worktree" <<'PYEOF'
import json, sys
f, bug, status, code, wt = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
try:    results = json.load(open(f))
except: results = []
entry = {"bug": bug, "status": status, "exit_code": int(code)}
# QA artifacts
try:
    qa = json.load(open(f"{wt}/.morpheus-qa.json"))
    entry["tests_added"] = len(qa.get("tests_added", []))
    after = qa.get("suite_after_fix") or {}
    entry["failed_after"] = after.get("failed", "?")
except: pass
# Duration from external wall-clock timestamps (reliable regardless of skill output)
try:
    start_ms = int(open(f"{wt}/.start_ms").read().strip())
    end_ms   = int(open(f"{wt}/.end_ms").read().strip())
    entry["duration_ms"] = end_ms - start_ms
except: pass
# Tokens from stream-json extraction
try:
    tok = json.load(open(f"{wt}/.worker-tokens.json"))
    total = sum(tok.values())
    if total > 0:
        entry["tokens_total"] = total
except: pass
# Fallback: .morpheus-telemetry.json written by the skill itself
if not entry.get("duration_ms") or not entry.get("tokens_total"):
    try:
        tel = json.load(open(f"{wt}/.morpheus-telemetry.json"))
        totals = tel.get("totals", {})
        stages = tel.get("stages", {})
        if not entry.get("duration_ms"):
            entry["duration_ms"] = totals.get("duration_ms") or sum(
                s.get("duration_ms", 0) for s in stages.values())
        if not entry.get("tokens_total"):
            entry["tokens_total"] = (
                sum(v for k,v in totals.items() if "token" in k) or
                sum(v for s in stages.values() for k,v in s.items() if "token" in k))
    except: pass
results.append(entry)
json.dump(results, open(f, "w"), indent=2)
PYEOF
    echo "$bug" >> "$WORKTREES_DIR/.finished"
  done
}

# ── Slot-based worker pool ────────────────────────────────────────────────────

rm -f "$WORKTREES_DIR/.finished"
touch "$WORKTREES_DIR/.finished"
QUEUE=("${BUGS[@]}")
QUEUE_INDEX=0

# Seed initial slots
while [[ $QUEUE_INDEX -lt ${#QUEUE[@]} ]] && [[ $(running_count) -lt $PARALLEL ]]; do
  start_worker "${QUEUE[$QUEUE_INDEX]}"
  QUEUE_INDEX=$((QUEUE_INDEX + 1))
done

# Drain — poll every 2s, reap finished workers, refill freed slots
TOTAL=${#BUGS[@]}
while true; do
  reap_finished
  DONE=$(wc -l < "$WORKTREES_DIR/.finished" 2>/dev/null || echo 0)
  RUNNING=$(running_count)

  # Refill freed slots from queue
  while [[ $QUEUE_INDEX -lt ${#QUEUE[@]} ]] && [[ $(running_count) -lt $PARALLEL ]]; do
    start_worker "${QUEUE[$QUEUE_INDEX]}"
    QUEUE_INDEX=$((QUEUE_INDEX + 1))
  done

  # Exit when all bugs are done
  if [[ $DONE -ge $TOTAL ]]; then
    break
  fi

  sleep 2
done

echo ""
echo "[orchestrator] All $TOTAL workers finished."

# ── Open PRs and create Jira tickets for fixed bugs ──────────────────────────
#
# GitHub: set GITHUB_TOKEN, OR run `gh auth login` once.
# Jira:   set all four env vars to enable:
#   JIRA_BASE_URL   e.g. https://yourorg.atlassian.net
#   JIRA_EMAIL      your Atlassian account email
#   JIRA_API_TOKEN  API token from id.atlassian.com/manage-profile/security/api-tokens
#   JIRA_PROJECT    Jira project key e.g. KAN
# If neither is configured, this section is skipped gracefully.

python3 - "$RESULTS_FILE" "$REPO_ROOT" "$WORKTREES_DIR" <<'PYEOF'
import json, subprocess, sys, os, re, urllib.request, urllib.error, base64

results   = json.load(open(sys.argv[1]))
repo_root = sys.argv[2]
wt_dir    = sys.argv[3]

def slug(bug):
    return re.sub(r'-+$', '', re.sub(r'[^a-z0-9]+', '-', bug.lower()))

# ── Detect active integrations ───────────────────────────────────────────────
JIRA_BASE    = os.environ.get("JIRA_BASE_URL", "").rstrip("/")
JIRA_EMAIL   = os.environ.get("JIRA_EMAIL", "")
JIRA_TOKEN   = os.environ.get("JIRA_API_TOKEN", "")
JIRA_PROJECT = os.environ.get("JIRA_PROJECT", "")
jira_enabled = bool(JIRA_BASE and JIRA_EMAIL and JIRA_TOKEN and JIRA_PROJECT)

github_enabled = False
if os.environ.get("GITHUB_TOKEN"):
    github_enabled = True  # gh CLI picks up GITHUB_TOKEN automatically
else:
    try:
        github_enabled = subprocess.run(
            ["gh", "auth", "status"], capture_output=True
        ).returncode == 0
    except FileNotFoundError:
        pass  # gh not installed

gh_sym   = "✓" if github_enabled else "✗  (set GITHUB_TOKEN or run `gh auth login`)"
jira_sym = "✓" if jira_enabled   else "✗  (set JIRA_BASE_URL / JIRA_EMAIL / JIRA_API_TOKEN / JIRA_PROJECT)"
print(f"[orchestrator] Integrations:  GitHub {gh_sym}   Jira {jira_sym}")

if not github_enabled and not jira_enabled:
    print("[orchestrator] No integrations active — skipping PR/ticket creation.")
    sys.exit(0)

# ── Jira helper ──────────────────────────────────────────────────────────────
def jira_request(method, path, body=None):
    creds   = base64.b64encode(f"{JIRA_EMAIL}:{JIRA_TOKEN}".encode()).decode()
    headers = {"Authorization": f"Basic {creds}", "Content-Type": "application/json", "Accept": "application/json"}
    data    = json.dumps(body).encode() if body else None
    req     = urllib.request.Request(f"{JIRA_BASE}/rest/api/3{path}", data=data, headers=headers, method=method)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())

def create_jira_ticket(bug, pr_url):
    payload = {
        "fields": {
            "project":     {"key": JIRA_PROJECT},
            "summary":     f"fix: {bug}",
            "description": {
                "type": "doc", "version": 1,
                "content": [{"type": "paragraph", "content": [
                    {"type": "text", "text": f"Fixed by morpheus-fix-bug-using-gitnexus.\n\nPR: {pr_url or '(none)'}"}
                ]}]
            },
            "issuetype":   {"name": "Bug"},
            "labels":      ["morpheus", "auto-fixed"],
        }
    }
    result = jira_request("POST", "/issue", payload)
    return result.get("key", "?"), f"{JIRA_BASE}/browse/{result.get('key','')}"

# ── Process each fixed bug ───────────────────────────────────────────────────
for r in results:
    if r["status"] != "fixed":
        continue
    bug  = r["bug"]
    safe = slug(bug)
    wt   = os.path.join(wt_dir, safe)
    pr_url = ""

    # GitHub PR
    if github_enabled:
        try:
            remote = subprocess.check_output(
                ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"],
                cwd=repo_root, stderr=subprocess.DEVNULL
            ).decode().strip()

            # Push branch to remote first — PR creation fails if branch isn't pushed
            push_proc = subprocess.run(
                ["git", "push", "-u", "origin", f"fix/{safe}"],
                cwd=wt, capture_output=True, text=True
            )
            if push_proc.returncode != 0:
                print(f"  Push failed for '{bug}': {push_proc.stderr.strip()}")
                continue

            jira_line = "\n\nJira: (ticket will be created)" if jira_enabled else ""
            pr_proc = subprocess.run([
                "gh", "pr", "create",
                "--title", f"fix: {bug}",
                "--body",  (
                    f"Fixed by morpheus-fix-bug-using-gitnexus.\n\n"
                    f"See `.worktrees/{safe}/.worker.log` for full session.{jira_line}"
                ),
                "--base", "master",
                "--head", f"fix/{safe}",
                "--repo", remote,
            ], cwd=wt, capture_output=True, text=True)

            if pr_proc.returncode == 0:
                pr_url = pr_proc.stdout.strip()
                r["pr_url"] = pr_url
                print(f"  PR opened:  {bug}")
                print(f"              {pr_url}")
            else:
                print(f"  PR failed for '{bug}': {pr_proc.stderr.strip()}")
        except FileNotFoundError:
            print(f"  PR skipped for '{bug}': `gh` not found in PATH")
        except Exception as e:
            print(f"  PR skipped for '{bug}': {e}")

    # Jira ticket
    if jira_enabled:
        try:
            key, ticket_url = create_jira_ticket(bug, pr_url)
            r["jira_key"] = key
            r["jira_url"] = ticket_url
            print(f"  Jira ticket: {key}  {ticket_url}")
        except Exception as e:
            print(f"  Jira skipped for '{bug}': {e}")

# Persist pr_url and jira_key back into results JSON
json.dump(results, open(sys.argv[1], "w"), indent=2)
PYEOF

# ── Print summary ─────────────────────────────────────────────────────────────

python3 - "$RESULTS_FILE" <<'PYEOF'
import json, sys
results = json.load(open(sys.argv[1]))
fixed  = [r for r in results if r["status"] == "fixed"]
failed = [r for r in results if r["status"] != "fixed"]
total_tok = sum(r.get("tokens_total", 0) for r in results)
total_ms  = sum(r.get("duration_ms",  0) for r in results)

W = 100
print("\n" + "─" * W)
print(f"  MORPHEUS SUMMARY — {len(results)} bugs  |  {len(fixed)} fixed  |  {len(failed)} failed")
print("─" * W)
print(f"  {'Bug':<28} {'Status':<8} {'Tests+':>6}  {'Duration':>8}  {'Tokens':>8}  {'PR / Jira'}")
print("  " + "─" * (W - 2))
for r in results:
    ms   = r.get("duration_ms", 0)
    dur  = f"{ms//60000}m{(ms%60000)//1000}s" if ms else "—"
    tok  = f"{r.get('tokens_total',0):,}"      if r.get("tokens_total") else "—"
    add  = f"+{r.get('tests_added', 0)}"       if r.get("tests_added") is not None else "—"
    sym  = "✓" if r["status"] == "fixed" else "✗"
    pr   = r.get("pr_url", "—")
    jira = r.get("jira_key", "")
    link = f"{pr}  {jira}" if jira else pr
    print(f"  {sym} {r['bug']:<26} {r['status']:<8} {add:>6}  {dur:>8}  {tok:>8}  {link}")
print("  " + "─" * (W - 2))
print(f"  {'TOTAL':<28} {'':8} {'':6}  {total_ms//60000}m{(total_ms%60000)//1000}s  {total_tok:>8,}")
if failed:
    print(f"\n  Failed: {', '.join(r['bug'] for r in failed)}")
print("─" * W + "\n")
PYEOF

# ── Per-worker telemetry and QA summaries ────────────────────────────────────

python3 - "$RESULTS_FILE" "$WORKTREES_DIR" <<'PYEOF'
import json, sys, os, re

results = json.load(open(sys.argv[1]))
wt_dir  = sys.argv[2]

def slug(bug):
    return re.sub(r'-+$', '', re.sub(r'[^a-z0-9]+', '-', bug.lower()))

def extract_blocks(text, keyword):
    """Extract box-drawing blocks that contain keyword."""
    blocks = []
    lines  = text.split('\n')
    buf    = []
    inside = False
    for line in lines:
        if '╔' in line and not inside:
            buf    = [line]
            inside = True
        elif inside:
            buf.append(line)
            if '╚' in line:
                block = '\n'.join(buf)
                if keyword in block:
                    blocks.append(block)
                buf    = []
                inside = False
    return blocks

for r in results:
    log_path = os.path.join(wt_dir, slug(r["bug"]), ".worker.log")
    if not os.path.exists(log_path):
        continue
    content = open(log_path).read()
    tel_blocks = extract_blocks(content, "MORPHEUS TELEMETRY SUMMARY")
    qa_blocks  = extract_blocks(content, "QA ARTIFACT SUMMARY")
    if tel_blocks or qa_blocks:
        print(f"\n{'━'*80}")
        print(f"  Worker detail: {r['bug']}")
        print(f"{'━'*80}")
        for b in tel_blocks:
            print(b)
        for b in qa_blocks:
            print(b)
PYEOF

# ── Cleanup fixed worktrees ───────────────────────────────────────────────────

python3 - "$RESULTS_FILE" "$REPO_ROOT" "$WORKTREES_DIR" <<'PYEOF'
import json, subprocess, sys, os
results = json.load(open(sys.argv[1]))
repo_root, wt_dir = sys.argv[2], sys.argv[3]
for r in results:
    if r["status"] == "fixed":
        import re
        safe = re.sub(r'-+$', '', re.sub(r'[^a-z0-9]+', '-', r["bug"].lower()))
        wt = os.path.join(wt_dir, safe)
        subprocess.run(["git", "worktree", "remove", "--force", wt],
                       cwd=repo_root, capture_output=True)
print("[orchestrator] Done. Failed worktrees left for inspection in .worktrees/")
PYEOF
