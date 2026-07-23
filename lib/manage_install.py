#!/usr/bin/env python3
"""Idempotently manage package-owned Markdown blocks and hook entries."""

import argparse
import json
from pathlib import Path
import re
import shutil
import shlex
from typing import Dict, Iterable, Optional, Tuple

BEGIN = "<!-- elixir-agent-debug:begin -->"
END = "<!-- elixir-agent-debug:end -->"
BLOCK_RE = re.compile(
    r"(?:\n?)" + re.escape(BEGIN) + r"\n.*?\n" + re.escape(END) + r"(?:\n?)",
    flags=re.DOTALL,
)


def write_text_atomic(path, text):
    # type: (Path, str) -> None
    path.parent.mkdir(parents=True, exist_ok=True)
    temp = path.with_name(path.name + ".elixir-agent-debug.tmp")
    temp.write_text(text, encoding="utf-8")
    temp.replace(path)


def add_block(path, snippet_path):
    # type: (Path, Path) -> None
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    cleaned = BLOCK_RE.sub("\n", existing).rstrip()
    snippet = snippet_path.read_text(encoding="utf-8").strip()
    block = BEGIN + "\n" + snippet + "\n" + END
    output = cleaned + "\n\n" + block + "\n" if cleaned else block + "\n"
    write_text_atomic(path, output)


def remove_block(path):
    # type: (Path) -> None
    if not path.exists():
        return
    existing = path.read_text(encoding="utf-8")
    output = BLOCK_RE.sub("\n", existing).strip()
    write_text_atomic(path, output + "\n" if output else "")


def load_json(path):
    # type: (Path) -> Dict
    if not path.exists() or not path.read_text(encoding="utf-8").strip():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise SystemExit("refusing to modify invalid JSON at {}: {}".format(path, exc))
    if not isinstance(value, dict):
        raise SystemExit("refusing to modify non-object JSON at {}".format(path))
    return value


def write_json(path, data):
    # type: (Path, Dict) -> None
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        backup = path.with_name(path.name + ".elixir-agent-debug.bak")
        shutil.copy2(str(path), str(backup))
    write_text_atomic(path, json.dumps(data, indent=2, sort_keys=False) + "\n")


def iter_hook_commands(entry):
    # type: (object) -> Iterable[str]
    if not isinstance(entry, dict):
        return
    hooks = entry.get("hooks")
    if not isinstance(hooks, list):
        return
    for hook in hooks:
        if isinstance(hook, dict):
            command = hook.get("command")
            if isinstance(command, str):
                yield command


def add_hook(path, command):
    # type: (Path, str) -> None
    data = load_json(path)
    hooks_obj = data.setdefault("hooks", {})
    if not isinstance(hooks_obj, dict):
        raise SystemExit("refusing to modify {}: top-level hooks is not an object".format(path))
    stop_entries = hooks_obj.setdefault("Stop", [])
    if not isinstance(stop_entries, list):
        raise SystemExit("refusing to modify {}: hooks.Stop is not a list".format(path))

    for entry in stop_entries:
        if command in tuple(iter_hook_commands(entry) or ()):
            return

    stop_entries.append(
        {
            "hooks": [
                {
                    "type": "command",
                    "command": command,
                    "timeout": 30,
                }
            ]
        }
    )
    write_json(path, data)


def remove_hook(path, command):
    # type: (Path, str) -> None
    if not path.exists():
        return
    data = load_json(path)
    hooks_obj = data.get("hooks")
    if not isinstance(hooks_obj, dict):
        return
    stop_entries = hooks_obj.get("Stop")
    if not isinstance(stop_entries, list):
        return

    new_entries = []
    changed = False
    for entry in stop_entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("hooks"), list):
            new_entries.append(entry)
            continue
        kept_hooks = [
            hook
            for hook in entry["hooks"]
            if not (isinstance(hook, dict) and hook.get("command") == command)
        ]
        if len(kept_hooks) != len(entry["hooks"]):
            changed = True
        if kept_hooks:
            copy = dict(entry)
            copy["hooks"] = kept_hooks
            new_entries.append(copy)

    if not changed:
        return
    if new_entries:
        hooks_obj["Stop"] = new_entries
    else:
        hooks_obj.pop("Stop", None)
    if not hooks_obj:
        data.pop("hooks", None)
    write_json(path, data)


def hook_commands(target):
    # type: (Path) -> Tuple[str, str]
    # The isolated form plus the legacy pre-1.4.3 form. `-I` ignores
    # PYTHONPATH and user site-packages, `-S` skips sitecustomize: without
    # them, a project environment could inject code into the hook process or
    # corrupt the scripts' stdout protocols. Every install and removal
    # handles both forms so an upgrade never leaves the legacy entry firing
    # beside the isolated one.
    script = shlex.quote(str(target / "hooks" / "stop_guard.py"))
    return "python3 -I -S " + script, "python3 " + script


def configure(home, target, claude, codex, hooks, remove_hooks=False):
    # type: (Path, Path, bool, bool, bool, bool) -> None
    # Selection is additive: configuring one client neither removes the other
    # client's integration nor an already-installed hook. Removal is explicit,
    # via --remove-hooks here or a full deconfigure.
    command, legacy = hook_commands(target)
    if claude:
        add_block(home / ".claude" / "CLAUDE.md", target / "adapters" / "claude-instructions.md")
        if hooks:
            remove_hook(home / ".claude" / "settings.json", legacy)
            add_hook(home / ".claude" / "settings.json", command)
    if codex:
        add_block(home / ".codex" / "AGENTS.md", target / "adapters" / "codex-instructions.md")
        if hooks:
            remove_hook(home / ".codex" / "hooks.json", legacy)
            add_hook(home / ".codex" / "hooks.json", command)
    if remove_hooks:
        for path in (home / ".claude" / "settings.json", home / ".codex" / "hooks.json"):
            remove_hook(path, command)
            remove_hook(path, legacy)


def deconfigure(home, target):
    # type: (Path, Path) -> None
    command, legacy = hook_commands(target)
    remove_block(home / ".claude" / "CLAUDE.md")
    remove_block(home / ".codex" / "AGENTS.md")
    for path in (home / ".claude" / "settings.json", home / ".codex" / "hooks.json"):
        remove_hook(path, command)
        remove_hook(path, legacy)


def main():
    # type: () -> int
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="action", required=True)

    block_add = sub.add_parser("block-add")
    block_add.add_argument("path", type=Path)
    block_add.add_argument("snippet", type=Path)

    block_remove = sub.add_parser("block-remove")
    block_remove.add_argument("path", type=Path)

    hook_add = sub.add_parser("hook-add")
    hook_add.add_argument("path", type=Path)
    hook_add.add_argument("command")

    hook_remove = sub.add_parser("hook-remove")
    hook_remove.add_argument("path", type=Path)
    hook_remove.add_argument("command")

    install = sub.add_parser("configure")
    install.add_argument("home", type=Path)
    install.add_argument("target", type=Path)
    install.add_argument("--claude", action="store_true")
    install.add_argument("--codex", action="store_true")
    install.add_argument("--hooks", action="store_true")
    install.add_argument("--remove-hooks", action="store_true")

    uninstall = sub.add_parser("deconfigure")
    uninstall.add_argument("home", type=Path)
    uninstall.add_argument("target", type=Path)

    args = parser.parse_args()
    if args.action == "block-add":
        add_block(args.path, args.snippet)
    elif args.action == "block-remove":
        remove_block(args.path)
    elif args.action == "hook-add":
        add_hook(args.path, args.command)
    elif args.action == "hook-remove":
        remove_hook(args.path, args.command)
    elif args.action == "configure":
        if not args.claude and not args.codex:
            parser.error("configure requires --claude and/or --codex")
        if args.hooks and args.remove_hooks:
            parser.error("--hooks and --remove-hooks are mutually exclusive")
        configure(args.home, args.target, args.claude, args.codex, args.hooks, args.remove_hooks)
    elif args.action == "deconfigure":
        deconfigure(args.home, args.target)
    else:
        parser.error("unknown action")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
