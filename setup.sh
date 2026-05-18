#!/usr/bin/env bash
set -euo pipefail

SKILL_NAME="morpheus-fix-my-bug"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SRC="${SCRIPT_DIR}/.claude/skills/${SKILL_NAME}/SKILL.md"
TARGET_DIR="${PWD}/.claude/skills/${SKILL_NAME}"

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
echo -e "${BOLD}morpheus-fix-my-bug — setup${NC}"
echo "=============================="

# ── 1. Gortex ──────────────────────────────────────────────────────────────
step "1. Gortex"

if command -v gortex &>/dev/null; then
  ok "Gortex already installed"
else
  warn "Gortex not found — installing..."
  curl -fsSL https://get.gortex.dev | sh
  ok "Gortex installed"
fi

if gortex daemon status 2>/dev/null | grep -q "ready"; then
  ok "Gortex daemon already running"
else
  warn "Starting Gortex daemon..."
  gortex daemon start --detach
  sleep 2
  ok "Gortex daemon started"
fi

if gortex daemon status 2>/dev/null | grep -q "$(basename "$PWD")"; then
  ok "Repo already tracked"
else
  warn "Tracking current repo..."
  gortex track .
  ok "Repo tracked — indexing in background"
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

# ── 4. Install the skill ───────────────────────────────────────────────────
step "4. Installing /${SKILL_NAME} skill"

if [ ! -f "$SKILL_SRC" ]; then
  err "Skill source not found at: ${SKILL_SRC}"
  echo "  Make sure you are running this script from the bug-fixer repo root."
  exit 1
fi

if [ "$(realpath "$PWD")" = "$(realpath "$SCRIPT_DIR")" ]; then
  ok "Already in the skill source repo — no copy needed"
else
  mkdir -p "$TARGET_DIR"
  cp "$SKILL_SRC" "${TARGET_DIR}/SKILL.md"
  ok "Skill installed at ${TARGET_DIR}/SKILL.md"
fi

# ── 5. Summary ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Summary ──────────────────────────────${NC}"
echo ""

if [ "${MISSING_SUPERPOWERS:-false}" = "true" ] || [ "${MISSING_GSTACK:-false}" = "true" ]; then
  warn "Setup incomplete — manual steps required above."
  echo ""
  echo "  Once complete, open Claude Code in this repo and run:"
  echo -e "  ${BOLD}/skills${NC}  — confirm ${SKILL_NAME} appears"
  echo -e "  ${BOLD}/mcp${NC}     — confirm gortex is connected"
else
  ok "All dependencies ready."
  echo ""
  echo "  Open Claude Code in this repo and verify:"
  echo -e "    ${BOLD}/skills${NC}  — should list ${SKILL_NAME}"
  echo -e "    ${BOLD}/mcp${NC}     — should show gortex connected"
  echo ""
  echo "  Then run:"
  echo -e "    ${BOLD}/morpheus-fix-my-bug \"describe the bug or paste a stack trace\"${NC}"
fi

echo ""
