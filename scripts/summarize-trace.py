#!/usr/bin/env python3
"""Summarize metadata-only ClipShelf JSONL, tolerating interleaved native stderr.

Dispatch records prove command submission, never insertion at the receiver.
New traces correlate attempts by UUID; older traces use sequential association.
"""
import argparse
import datetime
import json
import math
from pathlib import Path
import sys


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None


def cell(value):
    return str(value if value is not None else "—").replace("|", "\\|").replace("\n", " ").replace("\r", " ")


def timestamp(value):
    try:
        return datetime.datetime.fromtimestamp(value, datetime.timezone.utc).isoformat(timespec="milliseconds")
    except (ValueError, OverflowError, OSError, TypeError):
        return "—"


def summarize(lines):
    rows, attempts = [], {}
    invocation = None
    current_attempt = None
    pending_source = "unknown"
    ignored = 0
    for line in lines:
        try:
            event = json.loads(line)
        except (ValueError, TypeError):
            ignored += 1
            continue
        if not isinstance(event, dict) or not isinstance(event.get("event"), str) or number(event.get("timestamp")) is None:
            ignored += 1
            continue
        name, at = event["event"], event["timestamp"]
        if name == "hotkey_received":
            invocation = None
            current_attempt = None
            pending_source = "hotkey:" + (event.get("shortcut") if event.get("shortcut") in ("activation", "stack") else "unknown")
        elif name == "reopen":
            invocation = None
            current_attempt = None
            pending_source = "reopen"
        elif name == "menu_invocation":
            invocation = None
            current_attempt = None
            pending_source = "menu"
        elif name == "invocation":
            invocation = dict(start=at, source=pending_source, bundle=None, shown=None, ax_timeouts=0, attempts=[])
            rows.append(invocation)
            pending_source = "unknown"
            current_attempt = None
        elif name == "panel_shown" and invocation is not None:
            invocation["shown"] = at
        elif name == "target_captured" and invocation is not None:
            invocation["bundle"] = event.get("bundleID")
        elif name == "ax_timeout" and invocation is not None:
            invocation["ax_timeouts"] += 1
        elif name in ("paste_prepared", "paste_completed", "paste_dispatch"):
            identity = event.get("attemptID")
            if not isinstance(identity, str):
                identity = None
            attempt = attempts.get(identity) if identity is not None else current_attempt
            if name == "paste_prepared" or attempt is None:
                if invocation is None:
                    invocation = dict(start=at, source=pending_source, bundle=None, shown=None, ax_timeouts=0, attempts=[])
                    rows.append(invocation)
                    pending_source = "unknown"
                attempt = dict(start=at, bundle=event.get("bundleID"), state="incomplete", failure=None,
                               method=None, elapsed=None, mode=event.get("strictness"), completed=False)
                invocation["attempts"].append(attempt)
                if identity is not None:
                    attempts[identity] = attempt
                current_attempt = attempt
            attempt["bundle"] = event.get("bundleID") or attempt["bundle"]
            attempt["mode"] = event.get("strictness") or attempt["mode"]
            if name == "paste_dispatch":
                attempt["method"] = event.get("method")
            elif name == "paste_completed":
                attempt.update(state=event.get("state"), failure=event.get("failure"), completed=True)
                attempt["method"] = event.get("method") or attempt["method"]
                attempt["elapsed"] = number(event.get("elapsedMS"))
                if attempt["elapsed"] is None:
                    attempt["elapsed"] = max(0, at - attempt["start"]) * 1000
                if current_attempt is attempt:
                    current_attempt = None

    result = ["# ClipShelf trace summary", "",
              "This report shows command dispatch and cancellation, not confirmed insertion in a receiver.",
              "Entrance `unknown` includes unlabelled menu invocations; it is not proof of a physical hotkey.",
              "", "| Invocation (UTC) | Entrance | App | Panel ms | Paste ms | Mode | Outcome | Failure | Method | AX timeouts |",
              "| --- | --- | --- | ---: | ---: | --- | --- | --- | --- | ---: |"]
    for invocation in rows:
        panel_ms = None if invocation["shown"] is None else max(0, invocation["shown"] - invocation["start"]) * 1000
        for attempt in invocation["attempts"] or [dict(bundle=None, elapsed=None, mode=None, state="no paste attempt", failure=None, method=None)]:
            values = [timestamp(invocation["start"]), invocation["source"], attempt["bundle"] or invocation["bundle"],
                      None if panel_ms is None else f"{panel_ms:.1f}", None if attempt["elapsed"] is None else f"{attempt['elapsed']:.1f}",
                      attempt["mode"], attempt["state"], attempt["failure"], attempt["method"], invocation["ax_timeouts"]]
            result.append("| " + " | ".join(cell(value) for value in values) + " |")
    result.extend(["", f"Ignored non-trace or malformed lines: {ignored}.", ""])
    return "\n".join(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", nargs="?", type=Path, help="JSONL stderr file (default: stdin)")
    parser.add_argument("--output", type=Path, help="Write Markdown to this file")
    args = parser.parse_args()
    if args.trace:
        with args.trace.open(encoding="utf-8", errors="replace") as stream:
            report = summarize(stream)
    else:
        report = summarize(sys.stdin)
    if args.output:
        args.output.write_text(report, encoding="utf-8")
    else:
        sys.stdout.write(report)


if __name__ == "__main__":
    main()
