#!/usr/bin/env python3
"""
Live log tailer for morpheus-orchestrator.sh workers.
Reads .worker-raw.ndjson as it grows, prints readable text to stdout with a
per-worker prefix, writes .worker.log, and extracts token totals at the end.

Usage: python3 -u morpheus-live-log.py <slug> <claude-pid> <worktree-path>
"""
import json, os, sys, time

slug       = sys.argv[1]
claude_pid = int(sys.argv[2])
wt         = sys.argv[3]
prefix     = f"[{slug[:28]}] "

raw_path = os.path.join(wt, ".worker-raw.ndjson")
log_path = os.path.join(wt, ".worker.log")
tok_path = os.path.join(wt, ".worker-tokens.json")


def claude_running(pid):
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def process_line(line, log_fh):
    """Parse one NDJSON line; print text events with prefix; return usage if result event."""
    try:
        e = json.loads(line)
        t = e.get("type", "")
        if t == "assistant":
            for b in e.get("message", {}).get("content", []):
                if b.get("type") == "text":
                    text = b["text"]
                    log_fh.write(text)
                    log_fh.flush()
                    for ln in text.split("\n"):
                        if ln.strip():
                            sys.stdout.write(f"{prefix}{ln}\n")
            sys.stdout.flush()
        elif t == "result":
            return e.get("usage", {})
    except Exception:
        pass
    return None


seen_bytes  = 0
line_buf    = b""
final_usage = {}
result_seen = False   # exit on result event, not PID death (avoids race)

with open(log_path, "w") as log_fh:
    while True:
        # Read new bytes from the raw file
        try:
            with open(raw_path, "rb") as f:
                f.seek(seen_bytes)
                chunk = f.read()
        except FileNotFoundError:
            chunk = b""

        if chunk:
            seen_bytes += len(chunk)
            data = line_buf + chunk
            *complete, line_buf = data.split(b"\n")
            for raw_line in complete:
                decoded = raw_line.decode("utf-8", errors="replace").strip()
                if decoded:
                    usage = process_line(decoded, log_fh)
                    if usage:
                        final_usage = usage
                        result_seen = True

        # Prefer exiting on result event; fall back to PID death if claude crashes
        if result_seen:
            break
        if not claude_running(claude_pid):
            # Final drain — process any partial line left in the buffer
            time.sleep(0.2)
            try:
                with open(raw_path, "rb") as f:
                    f.seek(seen_bytes)
                    tail = f.read()
            except FileNotFoundError:
                tail = b""
            remaining = (line_buf + tail).decode("utf-8", errors="replace")
            for raw_line in remaining.split("\n"):
                stripped = raw_line.strip()
                if stripped:
                    usage = process_line(stripped, log_fh)
                    if usage:
                        final_usage = usage
            break

        time.sleep(0.4)

# Write token totals
tokens = {
    "input":       final_usage.get("input_tokens", 0),
    "output":      final_usage.get("output_tokens", 0),
    "cache_read":  final_usage.get("cache_read_input_tokens", 0),
    "cache_write": final_usage.get("cache_creation_input_tokens", 0),
}
json.dump(tokens, open(tok_path, "w"), indent=2)
