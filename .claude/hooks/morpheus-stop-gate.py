#!/usr/bin/env python3
"""
Stop-gate for /morpheus-fix-bug-using-gitnexus.

Reads session context from stdin (JSON), calls the Anthropic API with
max_tokens=50 so prose output is physically impossible, and prints a single
JSON decision object:

  {"decision": "approve"}
  {"decision": "block", "reason": "Missing: <step>"}

Language-agnostic: works for any codebase (Python, JS, C#, Go, Java, etc.).
Platform-agnostic: works on macOS, Linux, and Windows (no bash required).
Fails open: any error (no API key, network failure, bad response) returns approve.
Claude Code Stop hook schema: decision must be "approve" | "block" (NOT "allow").
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

FALLBACK = {"decision": "approve"}

PROMPT_TEMPLATE = """\
Output ONLY a JSON object: {{"decision":"approve"}} or {{"decision":"block","reason":"Missing: X"}}.

Was /morpheus-fix-bug-using-gitnexus invoked in this session for a real bug-fix \
(not docs / config edits / discussion)?

Not invoked → {{"decision":"approve"}}

Invoked → all 14 steps must be complete:
1.bug reproduced | 2.superpowers-systematic-debugging | 3.superpowers-test-driven-development+failing test \
| 4.fix applied+test passes | 5.gitnexus_detect_changes | 6.gitnexus_impact upstream \
| 7.gitnexus_impact downstream | 8.gitnexus_api_impact or skipped | 9.gitnexus_group_contracts or skipped \
| 10.superpowers-verification-before-completion | 11.superpowers-requesting-code-review \
| 12.MORPHEUS TELEMETRY SUMMARY block printed | 13.QA ARTIFACT SUMMARY block printed+failures decreased \
| 14..morpheus-qa.json has regression_test.file+suite_before_fix+suite_after_fix non-null

All complete → {{"decision":"approve"}} | Any missing → {{"decision":"block","reason":"Missing: <step>"}}

Session:
{session}"""

MAX_SESSION_CHARS = 20_000  # ~5k tokens — enough to see all tool calls


def git_root() -> str:
    """Return the repo root regardless of which subdirectory we're called from.
    Works on macOS, Linux, and Windows (no bash required).
    """
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "--show-toplevel"],
            stderr=subprocess.DEVNULL,
        ).decode().strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return os.getcwd()


def load_api_key() -> str:
    key = os.environ.get("ANTHROPIC_API_KEY", "")
    if key:
        return key
    # Try loading from .env at the git root (works for any project structure)
    env_path = os.path.join(git_root(), ".env")
    try:
        with open(env_path) as f:
            for line in f:
                line = line.strip()
                if line.startswith("ANTHROPIC_API_KEY="):
                    return line.split("=", 1)[1].strip().strip('"').strip("'")
    except OSError:
        pass
    return ""


def call_api(session_text: str) -> dict:
    api_key = load_api_key()
    if not api_key:
        return FALLBACK

    if len(session_text) > MAX_SESSION_CHARS:
        session_text = session_text[-MAX_SESSION_CHARS:]

    prompt = PROMPT_TEMPLATE.format(session=session_text)

    payload = json.dumps({
        "model": "claude-haiku-4-5-20251001",
        "max_tokens": 50,
        "system": "Output only a JSON object. No prose, no explanation, nothing outside the braces.",
        "messages": [{"role": "user", "content": prompt}],
    }).encode()

    req = urllib.request.Request(
        "https://api.anthropic.com/v1/messages",
        data=payload,
        headers={
            "x-api-key": api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        },
    )

    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError, OSError):
        return FALLBACK

    text = ""
    try:
        text = data["content"][0]["text"].strip()
        obj = json.loads(text)
        if "decision" in obj:
            return _normalise(obj)
    except (KeyError, IndexError, json.JSONDecodeError):
        pass

    # Last resort: extract first {...} from the text if model added stray prose
    m = re.search(r"\{[^}]+\}", text)
    if m:
        try:
            obj = json.loads(m.group())
            if "decision" in obj:
                return _normalise(obj)
        except json.JSONDecodeError:
            pass

    return FALLBACK


def _normalise(obj: dict) -> dict:
    """Coerce 'allow' → 'approve' so old prompt wording never breaks the schema."""
    if obj.get("decision") == "allow":
        obj["decision"] = "approve"
    return obj


def main() -> None:
    session = sys.stdin.read()
    result = call_api(session)
    print(json.dumps(result))


if __name__ == "__main__":
    main()
