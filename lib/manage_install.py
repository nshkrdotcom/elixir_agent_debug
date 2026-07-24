#!/usr/bin/env python3
"""Idempotently manage package-owned Markdown blocks and hook entries."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import shlex
import stat
import sys
import tempfile
from typing import Callable, Dict, Iterable, Optional, Tuple

BEGIN = "<!-- elixir-agent-debug:begin -->"
END = "<!-- elixir-agent-debug:end -->"
# The block itself, for in-place refresh; and the block plus exactly the one
# separator newline the installer introduced, for removal. Every byte
# outside the managed block belongs to the user and is preserved verbatim.
BLOCK_INNER_RE = re.compile(
    re.escape(BEGIN) + r"\n.*?\n" + re.escape(END),
    flags=re.DOTALL,
)
BLOCK_WITH_SEP_RE = re.compile(
    r"\n?" + re.escape(BEGIN) + r"\n.*?\n" + re.escape(END) + r"\n?",
    flags=re.DOTALL,
)


def write_text_atomic(path, text, default_mode=0o644):
    # type: (Path, str, int) -> None
    # Write through symlinks, not over them: dotfile-managed configurations
    # link these files into a repository, and replacing the link with a
    # regular file would silently break that management. The temporary file
    # is created securely in the resolved target's own directory (same
    # filesystem, atomic replace) and carries the target's existing mode —
    # a private 0600 settings file must not come back umask-readable — or
    # default_mode when the file is new.
    target = path.resolve() if path.is_symlink() else path
    target.parent.mkdir(parents=True, exist_ok=True)
    try:
        mode = stat.S_IMODE(target.stat().st_mode)
    except OSError:
        mode = default_mode
    descriptor, temp_name = tempfile.mkstemp(
        prefix=target.name + ".", suffix=".elixir-agent-debug.tmp", dir=str(target.parent)
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(text)
        os.chmod(temp_name, mode)
        os.replace(temp_name, str(target))
    except BaseException:
        try:
            os.unlink(temp_name)
        except OSError:
            pass
        raise


def add_block(path, snippet_path):
    # type: (Path, Path) -> None
    existing = path.read_text(encoding="utf-8") if path.exists() else ""
    snippet = snippet_path.read_text(encoding="utf-8").strip()
    block = BEGIN + "\n" + snippet + "\n" + END
    if BLOCK_INNER_RE.search(existing):
        # Refresh the block in place; unrelated content — including its
        # whitespace, which can be meaningful in Markdown — stays verbatim.
        output = BLOCK_INNER_RE.sub(lambda _match: block, existing, count=1)
        if output == existing:
            return
    elif existing:
        separator = "" if existing.endswith("\n") else "\n"
        output = existing + separator + "\n" + block + "\n"
    else:
        output = block + "\n"
    write_text_atomic(path, output)


def remove_block(path):
    # type: (Path) -> None
    if not path.exists():
        return
    existing = path.read_text(encoding="utf-8")
    if not BLOCK_INNER_RE.search(existing):
        # No managed block: this file is not ours to rewrite, not even to
        # normalize whitespace.
        return
    write_text_atomic(path, BLOCK_WITH_SEP_RE.sub("", existing))


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
    # Hook configuration can reference private setup; new files are 0600.
    write_text_atomic(
        path, json.dumps(data, indent=2, sort_keys=False) + "\n", default_mode=0o600
    )


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


def remove_hooks_matching(path, predicate):
    # type: (Path, Callable[[str], bool]) -> None
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
            if not (
                isinstance(hook, dict)
                and isinstance(hook.get("command"), str)
                and predicate(hook["command"])
            )
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


def remove_hook(path, command):
    # type: (Path, str) -> None
    remove_hooks_matching(path, lambda value: value == command)


def remove_hooks_referencing(path, fragment):
    # type: (Path, str) -> None
    # Every historical hook-command form — legacy plain `python3`, relative
    # `python3 -I -S`, and any earlier absolute-interpreter form — mentions
    # the package's stop_guard.py path, so removing by that fragment migrates
    # them all without touching unrelated hooks.
    remove_hooks_matching(path, lambda value: fragment in value)


def has_hook_referencing(path, fragment):
    # type: (Path, str) -> bool
    if not path.exists():
        return False
    try:
        data = load_json(path)
    except SystemExit:
        # A config this tool refuses to modify also cannot be refreshed;
        # a plain upgrade must not fail over it.
        return False
    hooks_obj = data.get("hooks")
    if not isinstance(hooks_obj, dict):
        return False
    stop_entries = hooks_obj.get("Stop")
    if not isinstance(stop_entries, list):
        return False
    for entry in stop_entries:
        for command in iter_hook_commands(entry) or ():
            if fragment in command:
                return True
    return False


def hook_commands(target):
    # type: (Path) -> Tuple[str, str]
    # The hook command pins both layers of binary resolution: the interpreter
    # is the absolute path of the Python running this installer (recorded at
    # install time, when PATH is trusted), and `-I -S` isolates it after
    # start (no PYTHONPATH, no user site-packages, no sitecustomize). Without
    # the absolute path, a project-prepended PATH could substitute python3
    # itself under the Stop hook. Returns the command plus the quoted script
    # path, the fragment every historical command form contains.
    script = shlex.quote(str(target / "hooks" / "stop_guard.py"))
    return shlex.quote(sys.executable) + " -I -S " + script, script


def configure(home, target, claude, codex, hooks, remove_hooks=False):
    # type: (Path, Path, bool, bool, bool, bool) -> None
    # Selection is additive: configuring one client neither removes the other
    # client's integration nor an already-installed hook. Removal is explicit,
    # via --remove-hooks here or a full deconfigure. A plain upgrade (no hook
    # option) never newly opts a client in, but it does refresh an existing
    # package hook to the current command form — a user who opted in once
    # must not keep an obsolete or less-hardened hook command just because
    # they omitted --hooks when upgrading.
    command, script = hook_commands(target)
    clients = []
    if claude:
        add_block(home / ".claude" / "CLAUDE.md", target / "adapters" / "claude-instructions.md")
        clients.append(home / ".claude" / "settings.json")
    if codex:
        add_block(home / ".codex" / "AGENTS.md", target / "adapters" / "codex-instructions.md")
        clients.append(home / ".codex" / "hooks.json")
    for path in clients:
        if hooks or (not remove_hooks and has_hook_referencing(path, script)):
            remove_hooks_referencing(path, script)
            add_hook(path, command)
    if remove_hooks:
        for path in (home / ".claude" / "settings.json", home / ".codex" / "hooks.json"):
            remove_hooks_referencing(path, script)


def deconfigure(home, target):
    # type: (Path, Path) -> None
    _command, script = hook_commands(target)
    remove_block(home / ".claude" / "CLAUDE.md")
    remove_block(home / ".codex" / "AGENTS.md")
    for path in (home / ".claude" / "settings.json", home / ".codex" / "hooks.json"):
        remove_hooks_referencing(path, script)


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
