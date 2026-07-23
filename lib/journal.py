#!/usr/bin/env python3
"""Per-repository evidence journal for the elixir-debug workflow.

Optional. Records hypotheses and what the observed evidence did to them, so a
long debugging session does not re-test theories it already killed. `report`
prints a hypothesis summary — the notes grouped by status — not a finished
write-up.
"""

import argparse
import json
from datetime import datetime
from pathlib import Path
import sys

STATUSES = ("open", "confirmed", "killed")


def journal_path(state_dir):
    # type: (str) -> Path
    return Path(state_dir) / "journal.jsonl"


def read_entries(path):
    # type: (Path) -> list
    if not path.exists():
        return []
    entries = []
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            entries.append(value)
    return entries


def command_note(args):
    # type: (argparse.Namespace) -> int
    path = journal_path(args.state_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        "ts": datetime.now().isoformat(timespec="seconds"),
        "status": args.status,
        "text": args.text,
    }
    if args.evidence:
        entry["evidence"] = args.evidence
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(entry, sort_keys=True) + "\n")
    print("{} [{}] {}".format(entry["ts"], entry["status"], entry["text"]))
    return 0


def format_entry(entry):
    # type: (dict) -> str
    line = "{} [{}] {}".format(
        entry.get("ts", "?"), entry.get("status", "open"), entry.get("text", "")
    )
    evidence = entry.get("evidence")
    if evidence:
        line += "\n    evidence: {}".format(evidence)
    return line


def command_history(args):
    # type: (argparse.Namespace) -> int
    path = journal_path(args.state_dir)
    entries = read_entries(path)
    if not entries:
        print("beam-debug: no journal entries for this repository: {}".format(path))
        return 0
    if args.limit and args.limit > 0:
        entries = entries[-args.limit :]
    for entry in entries:
        print(format_entry(entry))
    return 0


def command_report(args):
    # type: (argparse.Namespace) -> int
    path = journal_path(args.state_dir)
    entries = read_entries(path)
    if not entries:
        print("beam-debug: no journal entries for this repository: {}".format(path))
        return 0

    grouped = {status: [] for status in STATUSES}
    for entry in entries:
        grouped.setdefault(entry.get("status", "open"), []).append(entry)

    print("# Hypothesis summary")
    print("")
    headings = (
        ("confirmed", "Confirmed by evidence"),
        ("killed", "Ruled out by evidence"),
        ("open", "Still open / not verified"),
    )
    for status, heading in headings:
        items = grouped.get(status) or []
        print("## {} ({})".format(heading, len(items)))
        if not items:
            print("- none")
        for entry in items:
            print("- {}".format(entry.get("text", "")))
            evidence = entry.get("evidence")
            if evidence:
                print("  - evidence: {}".format(evidence))
        print("")
    return 0


def main(argv=None):
    # type: (list) -> int
    parser = argparse.ArgumentParser(prog="beam-debug", add_help=True)
    parser.add_argument("--state-dir", required=True)
    subparsers = parser.add_subparsers(dest="command")

    note = subparsers.add_parser("note")
    note.add_argument("text")
    note.add_argument("--status", choices=STATUSES, default="open")
    note.add_argument("--evidence", default="")
    note.set_defaults(handler=command_note)

    history = subparsers.add_parser("history")
    history.add_argument("--limit", type=int, default=0)
    history.set_defaults(handler=command_history)

    report = subparsers.add_parser("report")
    report.set_defaults(handler=command_report)

    # `beam-debug <command> --state-dir DIR <args>` reaches us as
    # `<command> --state-dir DIR <args>`; reorder so argparse sees the global
    # option first.
    raw = list(sys.argv[1:] if argv is None else argv)
    args = parser.parse_args(reorder(raw))
    if not getattr(args, "handler", None):
        parser.error("missing command")
    return args.handler(args)


def reorder(raw):
    # type: (list) -> list
    """Move a leading subcommand after the global --state-dir option."""
    if len(raw) >= 3 and not raw[0].startswith("-") and raw[1] == "--state-dir":
        return [raw[1], raw[2], raw[0]] + raw[3:]
    return raw


if __name__ == "__main__":
    raise SystemExit(main())
