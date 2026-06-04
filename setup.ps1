# morpheus-fix-bug-using-gitnexus — Windows Setup Script
# Requires PowerShell 5.1 or later

param(
    [switch]$Help
)

if ($Help) {
    Write-Host @"
Usage: .\setup.ps1

Installs Morpheus skills and verifies dependencies for bug-fixer.
This is the Windows version. Unix users should run ./setup.sh instead.
"@
    exit 0
}

$SCRIPT_DIR = $PSScriptRoot

# Skills to install
$SKILLS = @(
    "morpheus-fix-bug-using-gitnexus",
    "morpheus-worker",
    "morpheus-orchestrator",
    "morpheus-integration-gate"
)

# Color output functions
function Write-Ok { param($msg) Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn { param($msg) Write-Host "  ! $msg" -ForegroundColor Yellow }
function Write-Err { param($msg) Write-Host "  ✗ $msg" -ForegroundColor Red }
function Write-Step { param($msg) Write-Host "`n── $msg" -ForegroundColor White -BackgroundColor DarkBlue }
function Write-Manual {
    param($msg)
    Write-Host "  Manual step required inside Claude Code:" -ForegroundColor Yellow
    Write-Host "  $msg" -ForegroundColor White
}

Write-Host ""
Write-Host "morpheus-fix-bug-using-gitnexus — setup (Windows)" -ForegroundColor White
Write-Host "=================================================" -ForegroundColor White

# ── 1. GitNexus MCP ────────────────────────────────────────────────────────
Write-Step "1. GitNexus MCP"

$npxPath = Get-Command npx -ErrorAction SilentlyContinue
if ($npxPath) {
    Write-Ok "npx available (GitNexus is delivered as an MCP server via npx)"
} else {
    Write-Err "npx not found — install Node.js 18+ first"
    Write-Host "  https://nodejs.org"
    exit 1
}

Write-Host "  GitNexus MCP is configured per-project in .claude/settings.json."
Write-Host "  Verify it is listed under 'mcpServers' in your Claude Code settings."

$settingsPath = Join-Path $PWD ".claude\settings.json"
if (Test-Path $settingsPath) {
    $settingsContent = Get-Content $settingsPath -Raw
    if ($settingsContent -match '"gitnexus"') {
        Write-Ok "gitnexus MCP entry found in .claude\settings.json"
    } else {
        Write-Warn "gitnexus MCP entry not found in .claude\settings.json"
        Write-Host "  Add the following to your project's .claude\settings.json:"
        Write-Host @'

    "mcpServers": {
      "gitnexus": {
        "command": "npx",
        "args": ["-y", "@gitnexus/mcp@latest"]
      }
    }
'@
    }
} else {
    Write-Warn ".claude\settings.json not found in current directory"
}

# ── 2. Superpowers ─────────────────────────────────────────────────────────
Write-Step "2. Superpowers"

$SUPERPOWERS_MARKER = Join-Path $env:USERPROFILE ".claude\plugins\superpowers"

if (Test-Path $SUPERPOWERS_MARKER) {
    Write-Ok "Superpowers already installed"
} else {
    Write-Err "Superpowers not found"
    Write-Manual "/plugin install superpowers@claude-plugins-official"
    Write-Host "  Then re-run this script."
    $script:MISSING_SUPERPOWERS = $true
}

# ── 3. GStack ──────────────────────────────────────────────────────────────
Write-Step "3. GStack"

$GSTACK_MARKER = Join-Path $env:USERPROFILE ".claude\skills\gstack"

if (Test-Path $GSTACK_MARKER) {
    Write-Ok "GStack already installed"
} else {
    Write-Warn "GStack not found — attempting to install..."
    $gitPath = Get-Command git -ErrorAction SilentlyContinue
    if ($gitPath) {
        try {
            git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git $GSTACK_MARKER 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                $setupScript = Join-Path $GSTACK_MARKER "setup"
                if (Test-Path $setupScript) {
                    Push-Location $GSTACK_MARKER
                    # On Windows, setup might be a bash script - try both
                    if (Get-Command bash -ErrorAction SilentlyContinue) {
                        bash ./setup 2>&1 | Out-Null
                    } elseif (Test-Path "setup.ps1") {
                        .\setup.ps1
                    }
                    Pop-Location
                    Write-Ok "GStack installed successfully"
                } else {
                    Write-Ok "GStack cloned (setup script not found)"
                }
            } else {
                throw "Clone failed"
            }
        } catch {
            Write-Err "Failed to clone GStack repository"
            Write-Host "  You can manually install it with:"
            Write-Host "  git clone --single-branch --depth 1 https://github.com/garrytan/gstack.git $GSTACK_MARKER"
            Write-Host "  cd $GSTACK_MARKER && ./setup"
            $script:MISSING_GSTACK = $true
        }
    } else {
        Write-Err "git not found — cannot auto-install GStack"
        Write-Host "  Install git first, or manually clone GStack to:"
        Write-Host "  $GSTACK_MARKER\"
        $script:MISSING_GSTACK = $true
    }
}

# ── 4. Install skills ──────────────────────────────────────────────────────
Write-Step "4. Installing Morpheus skills"

$SAME_REPO = $false
$currentPath = (Resolve-Path $PWD).Path
$scriptPath = (Resolve-Path $SCRIPT_DIR).Path

if ($currentPath -eq $scriptPath) {
    $SAME_REPO = $true
    Write-Ok "Running from the bug-fixer repo itself — no copy needed"
}

foreach ($SKILL in $SKILLS) {
    $SKILL_SRC = Join-Path $SCRIPT_DIR ".claude\skills\$SKILL\SKILL.md"
    $TARGET_DIR = Join-Path $PWD ".claude\skills\$SKILL"

    if (-not (Test-Path $SKILL_SRC)) {
        Write-Err "Skill source not found: $SKILL_SRC"
        Write-Host "  Make sure you are running this script from the bug-fixer repo root."
        exit 1
    }

    if ($SAME_REPO) {
        Write-Ok "$SKILL — already in place"
    } else {
        if (-not (Test-Path $TARGET_DIR)) {
            New-Item -ItemType Directory -Path $TARGET_DIR -Force | Out-Null
        }
        Copy-Item $SKILL_SRC (Join-Path $TARGET_DIR "SKILL.md") -Force
        Write-Ok "$SKILL installed → $TARGET_DIR\SKILL.md"
    }
}

# ── 5. Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "── Summary ──────────────────────────────────────" -ForegroundColor White
Write-Host ""

if ($script:MISSING_SUPERPOWERS -or $script:MISSING_GSTACK) {
    Write-Warn "Setup incomplete — manual steps required above."
    Write-Host ""
    Write-Host "  Once complete, open Claude Code in this repo and run:"
    Write-Host "  /skills" -ForegroundColor White -NoNewline
    Write-Host "  — confirm morpheus-fix-bug-using-gitnexus appears"
    Write-Host "  /mcp" -ForegroundColor White -NoNewline
    Write-Host "     — confirm gitnexus is connected"
} else {
    Write-Ok "All dependencies ready."
    Write-Host ""
    Write-Host "  Open Claude Code in your target repo and verify:"
    Write-Host "    /skills" -ForegroundColor White -NoNewline
    Write-Host "  — should list morpheus-fix-bug-using-gitnexus"
    Write-Host "    /mcp" -ForegroundColor White -NoNewline
    Write-Host "     — should show gitnexus connected"
    Write-Host ""
    Write-Host "  Then run:"
    Write-Host '    /morpheus-fix-bug-using-gitnexus "describe the bug or paste a stack trace"' -ForegroundColor White
    Write-Host "  or for batch mode:"
    Write-Host '    /morpheus-fix-bug-using-gitnexus --jql "project = MYPROJ AND status = Open"' -ForegroundColor White
}

Write-Host ""
