#!/usr/bin/env python3
"""Track and find temporary BEAM instrumentation marked with BEAMDBG.

Marker convention: every temporary diagnostic line contains the literal
BEAMDBG marker in the language's own comment syntax -- `# BEAMDBG` in
Elixir, `% BEAMDBG` in Erlang. Scanned sources: *.ex, *.exs, *.erl, *.hrl,
in staged and unstaged diffs and untracked files (newly-added lines only).

Modes:
  --scan          print every newly-added marker in the worktree, exit 0
  --assert-clean  print them, exit 1 when any remain (the manual gate)
  --begin         record a session-owned marker ledger entry and print the
                  token to embed in markers (`# BEAMDBG:<token>`)
  --end [TOKEN]   verify no markers with that token remain, then drop the
                  ledger entry; exit 1 while any remain
  no args         Stop-hook mode for Claude Code and Codex CLI

Stop-hook mode enforces ownership, never a global scan. It acts only when a
ledger entry created by `beam-debug begin` is bound to the calling session's
session_id, and it checks only markers carrying that session's token.
Missing session metadata, no repository, no ledger, or no owned entry all
mean the stop is allowed: the hook fails open. Markers belonging to other
sessions, committed fixtures, or unrelated worktree changes are never
reported, and the hook never edits files itself. It blocks at most once
(stop_hook_active is honored) so a bad state cannot trap the CLI in a loop.
"""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
from typing import Dict, Iterable, List, NamedTuple, Optional, Tuple

MARKER = "BEAMDBG"
SOURCE_GLOBS = ("*.ex", "*.exs", "*.erl", "*.hrl")
SESSION_ENV_VARS = ("CLAUDE_CODE_SESSION_ID", "CLAUDE_SESSION_ID", "CODEX_SESSION_ID")


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


def parse_diff(text, source, needle):
    # type: (str, str, str) -> Iterable[Finding]
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
            if needle in content:
                yield Finding(path, new_line, content.strip(), source)
            new_line += 1
        elif raw.startswith("-") and not raw.startswith("---"):
            continue
        elif not raw.startswith("\\"):
            new_line += 1


def diff_findings(root, cached, needle):
    # type: (Path, bool, str) -> List[Finding]
    args = ["diff"]
    if cached:
        args.append("--cached")
    args.extend(["--unified=0", "--no-color", "--no-ext-diff", "--"])
    args.extend(SOURCE_GLOBS)
    result = git(root, *args)
    if result.returncode not in (0, 1):
        raise RuntimeError(result.stderr.strip() or "git diff failed")
    return list(parse_diff(result.stdout, "staged" if cached else "working tree", needle))


def untracked_findings(root, needle):
    # type: (Path, str) -> List[Finding]
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
            if needle in line:
                findings.append(Finding(relative, number, line.strip(), "untracked"))
    return findings


def collect(cwd, needle=MARKER):
    # type: (Path, str) -> Tuple[Optional[Path], List[Finding]]
    root = repo_root(cwd)
    if root is None:
        return None, []

    combined = diff_findings(root, False, needle)
    combined.extend(diff_findings(root, True, needle))
    combined.extend(untracked_findings(root, needle))

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


# --- session ledger -----------------------------------------------------------


def marker_for(token):
    # type: (str) -> str
    return "{}:{}".format(MARKER, token)


def state_dir(root):
    # type: (Path) -> Path
    # Must mirror bin/beam-debug's state_dir: sha256 of the repository root
    # path, first 16 hex characters, under ${XDG_STATE_HOME:-~/.local/state}.
    base_value = os.environ.get("XDG_STATE_HOME")
    base = Path(base_value) if base_value else Path.home() / ".local" / "state"
    digest = hashlib.sha256(str(root).encode()).hexdigest()[:16]
    return base / "beam-debug" / digest


def sessions_dir(root):
    # type: (Path) -> Path
    return state_dir(root) / "sessions"


def load_entries(root):
    # type: (Path) -> List[Tuple[Path, Dict[str, object]]]
    directory = sessions_dir(root)
    entries = []  # type: List[Tuple[Path, Dict[str, object]]]
    if not directory.is_dir():
        return entries
    for path in sorted(directory.glob("*.json")):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(value, dict) and isinstance(value.get("token"), str) and value["token"]:
            entries.append((path, value))
    return entries


def env_session_id():
    # type: () -> Optional[str]
    for name in SESSION_ENV_VARS:
        value = os.environ.get(name)
        if value:
            return value
    return None


def print_begin_instructions(token, session_id, reused):
    # type: (str, Optional[str], bool) -> None
    print("{} marker session {}.".format("Reusing" if reused else "Started", token))
    print("Mark every temporary diagnostic line with this token in the language's comment syntax:")
    print("  Elixir:  # {}".format(marker_for(token)))
    print("  Erlang:  % {}".format(marker_for(token)))
    print("Finish with: beam-debug end {}".format(token))
    if session_id:
        print("Bound to agent session {}; a Stop hook, if installed, checks only this session's markers.".format(session_id))
    else:
        print("No agent session id found in the environment: the Stop hook will not")
        print("enforce this ledger. Run `beam-debug end {}` yourself.".format(token))


def begin(cwd, explicit_session):
    # type: (Path, Optional[str]) -> int
    root = repo_root(cwd)
    if root is None:
        print("beam-debug begin: not inside a git worktree; marker tracking needs one.", file=sys.stderr)
        return 1

    session_id = explicit_session or env_session_id()
    if session_id:
        for _path, entry in load_entries(root):
            if entry.get("session_id") == session_id:
                print_begin_instructions(str(entry["token"]), session_id, reused=True)
                return 0

    token = secrets.token_hex(4)
    directory = sessions_dir(root)
    directory.mkdir(parents=True, exist_ok=True)
    entry = {
        "token": token,
        "session_id": session_id,
        "repo": str(root),
        "created": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    (directory / (token + ".json")).write_text(
        json.dumps(entry, indent=2) + "\n", encoding="utf-8"
    )
    print_begin_instructions(token, session_id, reused=False)
    return 0


def end(cwd, token):
    # type: (Path, str) -> int
    root = repo_root(cwd)
    if root is None:
        print("beam-debug end: not inside a git worktree.", file=sys.stderr)
        return 1

    entries = load_entries(root)
    if token:
        chosen = [(p, e) for p, e in entries if e["token"] == token]
        if not chosen:
            _root, findings = collect(cwd, marker_for(token))
            if findings:
                print(format_findings(root, findings), file=sys.stderr)
                return 1
            print("No ledger entry and no markers for token {}; nothing to do.".format(token))
            return 0
    else:
        session_id = env_session_id()
        chosen = [(p, e) for p, e in entries if session_id and e.get("session_id") == session_id]
        if not chosen and len(entries) == 1:
            chosen = entries
        if not chosen:
            if not entries:
                print("No marker sessions recorded for this repository.")
                return 0
            print("Several marker sessions exist; pass a token:", file=sys.stderr)
            for _path, entry in entries:
                print("  beam-debug end {}".format(entry["token"]), file=sys.stderr)
            return 2

    status = 0
    for path, entry in chosen:
        _root, findings = collect(cwd, marker_for(str(entry["token"])))
        if findings:
            print(format_findings(root, findings), file=sys.stderr)
            status = 1
        else:
            try:
                path.unlink()
            except OSError:
                pass
            print("Marker session {} is clean; ledger entry removed.".format(entry["token"]))
    return status


# --- Stop-hook mode -----------------------------------------------------------


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


def format_hook_message(root, remaining):
    # type: (Path, List[Tuple[str, List[Finding]]]) -> str
    lines = [
        "This session's temporary BEAMDBG instrumentation remains under {}:".format(root)
    ]
    for token, findings in remaining:
        for item in findings:
            lines.append("  {}:{}: {} [{}]".format(item.path, item.line, item.text, item.source))
        lines.append(
            "Remove only the lines carrying {} — any other BEAMDBG markers belong to "
            "other sessions or committed code and must be left alone — then run "
            "`beam-debug end {}`.".format(marker_for(token), token)
        )
    return "\n".join(lines)


def hook_mode():
    # type: () -> int
    # Every failure path allows the stop: a cleanup guard that can break task
    # completion is worse than a forgotten marker, and `beam-debug
    # assert-clean` remains the manual fallback.
    try:
        event = read_event()
        session_id = event.get("session_id")
        if not isinstance(session_id, str) or not session_id:
            return 0

        cwd_value = event.get("cwd")
        cwd = Path(cwd_value) if isinstance(cwd_value, str) and cwd_value else Path.cwd()
        root = repo_root(cwd)
        if root is None:
            return 0

        owned = [
            (path, entry)
            for path, entry in load_entries(root)
            if entry.get("session_id") == session_id
        ]
        if not owned:
            return 0

        remaining = []  # type: List[Tuple[str, List[Finding]]]
        for path, entry in owned:
            token = str(entry["token"])
            _root, findings = collect(cwd, marker_for(token))
            if findings:
                remaining.append((token, findings))
            else:
                # The session's markers are gone: retire the ledger entry so
                # the next stop has nothing to check.
                try:
                    path.unlink()
                except OSError:
                    pass

        if not remaining:
            return 0

        message = format_hook_message(root, remaining)
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
    except Exception:  # noqa: BLE001 - the hook must fail open, whatever broke
        return 0


def main():
    # type: () -> int
    parser = argparse.ArgumentParser(add_help=True)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--scan", action="store_true")
    group.add_argument("--assert-clean", action="store_true")
    group.add_argument("--begin", action="store_true")
    group.add_argument("--end", nargs="?", const="", default=None, metavar="TOKEN")
    parser.add_argument("--session-id", default=None, help="explicit agent session id for --begin")
    args = parser.parse_args()

    if args.begin:
        return begin(Path.cwd(), args.session_id)
    if args.end is not None:
        return end(Path.cwd(), args.end)

    if not args.scan and not args.assert_clean:
        return hook_mode()

    try:
        root, findings = collect(Path.cwd())
    except (OSError, RuntimeError) as exc:
        print("beam-debug guard failed: {}".format(exc), file=sys.stderr)
        return 1 if args.assert_clean else 0

    if not findings:
        if args.scan:
            location = str(root) if root else str(Path.cwd())
            print("No newly-added {} markers found under {}.".format(MARKER, location))
        return 0

    if root is None:
        return 0
    message = format_findings(root, findings)

    if args.scan:
        print(message)
        return 0

    print(message, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
