#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Skills to install (directory names under .claude/skills/ in this repo)
SKILLS=(
  "morpheus-fix-bug-using-gitnexus"
  "morpheus-worker"
  "morpheus-orchestrator"
  "morpheus-integration-gate"
)

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
err()  { echo -e "  ${RED}✗${NC} $1"; }
step() { echo -e "\n${BOLD}── $1${NC}"; }
manual() {
  echo -e "  ${YELLOW}Manual step required inside Claude Code:${NC}"
  echo -e "  ${BOLD}$1${NC}"
}

echo ""
echo -e "${BOLD}morpheus-fix-bug-using-gitnexus — setup${NC}"
echo "========================================="

# ── 1. GitNexus MCP ────────────────────────────────────────────────────────
step "1. GitNexus MCP"

if command -v npx &>/dev/null; then
  ok "npx available (GitNexus is delivered as an MCP server via npx)"
else
  err "npx not found — install Node.js 18+ first"
  echo "  https://nodejs.org"
  exit 1
fi

echo "  GitNexus MCP is configured per-project in .claude/settings.json."
echo "  Verify it is listed under 'mcpServers' in your Claude Code settings."
if grep -q '"gitnexus"' "${PWD}/.claude/settings.json" 2>/dev/null; then
  ok "gitnexus MCP entry found in .claude/settings.json"
else
  warn "gitnexus MCP entry not found in .claude/settings.json"
  echo "  Add the following to your project's .claude/settings.json:"
  cat <<'SNIPPET'

    "mcpServers": {
      "gitnexus": {
        "command": "npx",
        "args": ["-y", "@gitnexus/mcp@latest"]
      }
    }
SNIPPET
fi

# ── 2. Superpowers ─────────────────────────────────────────────────────────
step "2. Superpowers"

SUPERPOWERS_MARKER="${HOME}/.claude/plugins/superpowers"

if [ -d "$SUPERPOWERS_MARKER" ]; then
  ok "Superpowers already installed"
else
  err "Superpowers not found"
  manual "/plugin install superpowers@claude-plugins-official"
  echo "  Then re-run this script."
  MISSING_SUPERPOWERS=true
fi

# ── 3. GStack ──────────────────────────────────────────────────────────────
step "3. GStack"

GSTACK_MARKER="${HOME}/.claude/skills/gstack"

if [ -d "$GSTACK_MARKER" ]; then
  ok "GStack already installed"
else
  err "GStack not found"
  echo "  Obtain GStack from your team or the GStack distribution and place it at:"
  echo "  ${HOME}/.claude/skills/gstack/"
  MISSING_GSTACK=true
fi

# ── 4. Install skills ──────────────────────────────────────────────────────
step "4. Installing Morpheus skills"

SAME_REPO=false
if [ "$(realpath "$PWD")" = "$(realpath "$SCRIPT_DIR")" ]; then
  SAME_REPO=true
  ok "Running from the bug-fixer repo itself — no copy needed"
fi

for SKILL in "${SKILLS[@]}"; do
  SKILL_SRC="${SCRIPT_DIR}/.claude/skills/${SKILL}/SKILL.md"
  TARGET_DIR="${PWD}/.claude/skills/${SKILL}"

  if [ ! -f "$SKILL_SRC" ]; then
    err "Skill source not found: ${SKILL_SRC}"
    echo "  Make sure you are running this script from the bug-fixer repo root."
    exit 1
  fi

  if [ "$SAME_REPO" = "true" ]; then
    ok "${SKILL} — already in place"
  else
    mkdir -p "$TARGET_DIR"
    cp "$SKILL_SRC" "${TARGET_DIR}/SKILL.md"
    ok "${SKILL} installed → ${TARGET_DIR}/SKILL.md"
  fi
done

# ── 5. Summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Summary ──────────────────────────────${NC}"
echo ""

if [ "${MISSING_SUPERPOWERS:-false}" = "true" ] || [ "${MISSING_GSTACK:-false}" = "true" ]; then
  warn "Setup incomplete — manual steps required above."
  echo ""
  echo "  Once complete, open Claude Code in this repo and run:"
  echo -e "  ${BOLD}/skills${NC}  — confirm morpheus-fix-bug-using-gitnexus appears"
  echo -e "  ${BOLD}/mcp${NC}     — confirm gitnexus is connected"
else
  ok "All dependencies ready."
  echo ""
  echo "  Open Claude Code in your target repo and verify:"
  echo -e "    ${BOLD}/skills${NC}  — should list morpheus-fix-bug-using-gitnexus"
  echo -e "    ${BOLD}/mcp${NC}     — should show gitnexus connected"
  echo ""
  echo "  Then run:"
  echo -e "    ${BOLD}/morpheus-fix-bug-using-gitnexus \"describe the bug or paste a stack trace\"${NC}"
  echo -e "  or for batch mode:"
  echo -e "    ${BOLD}/morpheus-fix-bug-using-gitnexus --jql \"project = MYPROJ AND status = Open\"${NC}"
fi

echo ""
