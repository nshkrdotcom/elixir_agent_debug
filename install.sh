#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${ELIXIR_AGENT_DEBUG_HOME:-$HOME/.local/share/elixir-agent-debug}"
WITH_HOOKS=0
INSTALL_CLAUDE=1
INSTALL_CODEX=1

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--hooks] [--claude-only|--codex-only]

  --hooks         Add a Stop hook that asks the agent once to remove newly-added
                  # BEAMDBG markers before stopping
  --claude-only   Install only Claude Code integration
  --codex-only    Install only Codex CLI integration
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hooks) WITH_HOOKS=1 ;;
    --claude-only) INSTALL_CLAUDE=1; INSTALL_CODEX=0 ;;
    --codex-only) INSTALL_CLAUDE=0; INSTALL_CODEX=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

for command in python3 cp mkdir rm readlink mktemp mv ln; do
  command -v "$command" >/dev/null 2>&1 || {
    printf 'install.sh: required command not found: %s\n' "$command" >&2
    exit 127
  }
done

case "$TARGET" in
  ""|"/"|"$HOME")
    printf 'install.sh: refusing unsafe target: %s\n' "$TARGET" >&2
    exit 2
    ;;
esac

install_package() {
  if [[ "$(readlink -f -- "$SOURCE_ROOT")" == "$(readlink -m -- "$TARGET")" ]]; then
    return
  fi

  local temp
  temp="$(mktemp -d)"
  mkdir -p -- "$temp/package"
  if ! cp -a -- "$SOURCE_ROOT/." "$temp/package/"; then
    rm -rf -- "$temp"
    return 1
  fi
  rm -rf -- "$temp/package/.git" "$temp/package/__pycache__" \
    "$temp/package/hooks/__pycache__" "$temp/package/lib/__pycache__"
  mkdir -p -- "$(dirname -- "$TARGET")"
  rm -rf -- "$TARGET"
  mv -- "$temp/package" "$TARGET"
  rm -rf -- "$temp"
}

install_managed_skill() {
  local destination="$1"
  if [[ -e "$destination" && ! -f "$destination/.elixir-agent-debug-managed" ]]; then
    printf 'install.sh: refusing to overwrite unrelated skill: %s\n' "$destination" >&2
    exit 1
  fi
  rm -rf -- "$destination"
  mkdir -p -- "$(dirname -- "$destination")"
  cp -a -- "$TARGET/skill/elixir-debug" "$destination"
  : > "$destination/.elixir-agent-debug-managed"
}

install_command() {
  local destination="$HOME/.local/bin/beam-debug"
  mkdir -p -- "$(dirname -- "$destination")"
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ ! -L "$destination" || "$(readlink -f -- "$destination")" != "$(readlink -f -- "$TARGET/bin/beam-debug")" ]]; then
      printf 'install.sh: refusing to overwrite unrelated executable: %s\n' "$destination" >&2
      exit 1
    fi
  fi
  ln -sfn -- "$TARGET/bin/beam-debug" "$destination"
}

install_package
MANAGER="$TARGET/lib/manage_install.py"
install_command

manager_args=(configure "$HOME" "$TARGET")
if [[ "$INSTALL_CLAUDE" -eq 1 ]]; then
  install_managed_skill "$HOME/.claude/skills/elixir-debug"
  manager_args+=(--claude)
fi
if [[ "$INSTALL_CODEX" -eq 1 ]]; then
  install_managed_skill "$HOME/.agents/skills/elixir-debug"
  manager_args+=(--codex)
fi
if [[ "$WITH_HOOKS" -eq 1 ]]; then
  manager_args+=(--hooks)
fi
python3 "$MANAGER" "${manager_args[@]}"

printf 'Installed elixir-agent-debug at %s\n' "$TARGET"
printf 'Command: %s\n' "$HOME/.local/bin/beam-debug"
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  printf 'Note: add %s to PATH for the beam-debug command.\n' "$HOME/.local/bin"
fi
if [[ "$WITH_HOOKS" -eq 1 && "$INSTALL_CODEX" -eq 1 ]]; then
  printf 'Codex: open /hooks and trust the new user hook before it can run.\n'
fi
printf 'Start a new CLI session, then run: beam-debug doctor\n'
