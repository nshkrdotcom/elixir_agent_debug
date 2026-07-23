#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${ELIXIR_AGENT_DEBUG_HOME:-$HOME/.local/share/elixir-agent-debug}"

if [[ -f "$TARGET/lib/manage_install.py" ]]; then
  MANAGER="$TARGET/lib/manage_install.py"
elif [[ -f "$SOURCE_ROOT/lib/manage_install.py" ]]; then
  MANAGER="$SOURCE_ROOT/lib/manage_install.py"
else
  printf 'uninstall.sh: manage_install.py not found\n' >&2
  exit 1
fi

PYTHON3_BIN=""
if [[ -r "$TARGET/lib/runtime-paths.conf" ]]; then
  PYTHON3_BIN="$(sed -n 's/^python3=//p' "$TARGET/lib/runtime-paths.conf" | head -1)"
fi
if [[ -z "$PYTHON3_BIN" || ! -x "$PYTHON3_BIN" ]]; then
  PYTHON3_BIN="$(command -v python3)"
fi

"$PYTHON3_BIN" -I -S "$MANAGER" deconfigure "$HOME" "$TARGET"

for skill in "$HOME/.claude/skills/elixir-debug" "$HOME/.agents/skills/elixir-debug"; do
  if [[ -f "$skill/.elixir-agent-debug-managed" ]]; then
    rm -rf -- "$skill"
  fi
done

command_path="$HOME/.local/bin/beam-debug"
target_command="$(readlink -f -- "$TARGET/bin/beam-debug" 2>/dev/null || true)"
if [[ -L "$command_path" && -n "$target_command" && "$(readlink -f -- "$command_path")" == "$target_command" ]]; then
  rm -f -- "$command_path"
fi

case "$TARGET" in
  ""|"/"|"$HOME")
    printf 'uninstall.sh: refusing unsafe target removal: %s\n' "$TARGET" >&2
    exit 2
    ;;
  *) rm -rf -- "$TARGET" ;;
esac

printf 'Uninstalled elixir-agent-debug. JSON backup files, if any, were intentionally retained.\n'
