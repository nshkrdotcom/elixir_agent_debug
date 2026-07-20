#!/usr/bin/env python3
"""Find newly-added temporary Elixir instrumentation marked with BEAMDBG.

Modes:
  no args         Stop-hook mode for Claude Code and Codex CLI
  --scan          print findings, exit 0
  --assert-clean  print findings, exit 1 when any remain

The hook reads event JSON from stdin when available. It blocks one stop by
returning a shared {decision:block, reason:...} shape. If the hook is already
active, it allows stopping with a warning to avoid a continuation loop.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
from typing import Dict, Iterable, List, NamedTuple, Optional, Tuple

MARKER = "BEAMDBG"
SOURCE_GLOBS = ("*.ex", "*.exs")


class Finding(NamedTuple):
    path: str
    line: int
    text: str
    source: str


def git(root_or_cwd, *args):
    # type: (Path, *str) -> subprocess.CompletedProcess
    return subprocess.run(
        ["git", "-C", str(root_or_cwd)] + list(args),
        universal_newlines=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def repo_root(cwd):
    # type: (Path) -> Optional[Path]
    result = git(cwd, "rev-parse", "--show-toplevel")
    if result.returncode != 0:
        return None
    value = result.stdout.strip()
    return Path(value) if value else None


HUNK_RE = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")


def parse_diff(text, source):
    # type: (str, str) -> Iterable[Finding]
    path = None  # type: Optional[str]
    new_line = None  # type: Optional[int]

    for raw in text.splitlines():
        if raw.startswith("+++ "):
            candidate = raw[4:]
            if candidate == "/dev/null":
                path = None
            elif candidate.startswith("b/"):
                path = candidate[2:]
            else:
                path = candidate
            continue

        match = HUNK_RE.match(raw)
        if match:
            new_line = int(match.group(1))
            continue

        if path is None or new_line is None:
            continue

        if raw.startswith("+") and not raw.startswith("+++"):
            content = raw[1:]
            if MARKER in content:
                yield Finding(path, new_line, content.strip(), source)
            new_line += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            continue
        elif not raw.startswith("\\"):
            new_line += 1


def diff_findings(root, cached):
    # type: (Path, bool) -> List[Finding]
    args = ["diff"]
    if cached:
        args.append("--cached")
    args.extend(["--unified=0", "--no-color", "--no-ext-diff", "--"])
    args.extend(SOURCE_GLOBS)
    result = git(root, *args)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip() or "git diff failed")
    return list(parse_diff(result.stdout, "staged" if cached else "working tree"))


def untracked_findings(root):
    # type: (Path) -> List[Finding]
    command = [
        "git",
        "-C",
        str(root),
        "ls-files",
        "--others",
        "--exclude-standard",
        "-z",
        "--",
    ] + list(SOURCE_GLOBS)
    result = subprocess.run(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode(errors="replace").strip() or "git ls-files failed")

    findings = []  # type: List[Finding]
    for raw_path in result.stdout.split(b"\0"):
        if not raw_path:
            continue
        relative = raw_path.decode(errors="surrogateescape")
        path = root / relative
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for number, line in enumerate(text.splitlines(), start=1):
            if MARKER in line:
                findings.append(Finding(relative, number, line.strip(), "untracked"))
    return findings


def collect(cwd):
    # type: (Path) -> Tuple[Optional[Path], List[Finding]]
    root = repo_root(cwd)
    if root is None:
        return None, []

    combined = diff_findings(root, cached=False)
    combined.extend(diff_findings(root, cached=True))
    combined.extend(untracked_findings(root))

    deduped = {}  # type: Dict[Tuple[str, int, str], Finding]
    for item in combined:
        deduped[(item.path, item.line, item.text)] = item
    return root, sorted(deduped.values(), key=lambda x: (x.path, x.line, x.source))


def format_findings(root, findings):
    # type: (Path, List[Finding]) -> str
    lines = ["Temporary {} instrumentation remains under {}:".format(MARKER, root)]
    for item in findings:
        lines.append("  {}:{}: {} [{}]".format(item.path, item.line, item.text, item.source))
    lines.append(
        "Remove the temporary instrumentation, rerun the focused check, then run `beam-debug assert-clean`."
    )
    return "\n".join(lines)


def read_event():
    # type: () -> Dict[str, object]
    if sys.stdin.isatty():
        return {}
    try:
        payload = sys.stdin.read()
    except OSError:
        return {}
    if not payload.strip():
        return {}
    try:
        value = json.loads(payload)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def main():
    # type: () -> int
    parser = argparse.ArgumentParser(add_help=True)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--scan", action="store_true")
    group.add_argument("--assert-clean", action="store_true")
    args = parser.parse_args()

    event = {} if (args.scan or args.assert_clean) else read_event()
    cwd_value = event.get("cwd") if isinstance(event, dict) else None
    cwd = Path(cwd_value) if isinstance(cwd_value, str) and cwd_value else Path.cwd()

    try:
        root, findings = collect(cwd)
    except (OSError, RuntimeError) as exc:
        if args.assert_clean:
            print("beam-debug guard failed: {}".format(exc), file=sys.stderr)
            return 1
        if args.scan:
            print("beam-debug guard failed: {}".format(exc), file=sys.stderr)
        return 0

    if not findings:
        if args.scan:
            location = str(root) if root else str(cwd)
            print("No newly-added {} markers found under {}.".format(MARKER, location))
        return 0

    if root is None:
        return 0
    message = format_findings(root, findings)

    if args.scan:
        print(message)
        return 0

    if args.assert_clean:
        print(message, file=sys.stderr)
        return 1

    if bool(event.get("stop_hook_active")):
        print(
            json.dumps(
                {
                    "systemMessage": message
                    + "\nThe cleanup guard already requested one continuation and is allowing this stop to avoid a loop."
                }
            )
        )
        return 0

    print(json.dumps({"decision": "block", "reason": message}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
