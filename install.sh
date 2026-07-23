#!/usr/bin/env bash
set -euo pipefail

SOURCE_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${ELIXIR_AGENT_DEBUG_HOME:-$HOME/.local/share/elixir-agent-debug}"
WITH_HOOKS=0
REMOVE_HOOKS=0
INSTALL_CLAUDE=1
INSTALL_CODEX=1

usage() {
  cat <<'USAGE'
Usage: ./install.sh [--hooks|--remove-hooks] [--claude-only|--codex-only]

  --hooks         Opt in to the session-owned Stop hook: it asks the agent
                  once to remove marker lines that its own `beam-debug begin`
                  session left behind, and does nothing in any other case
  --remove-hooks  Remove a previously installed Stop hook from both clients
  --claude-only   Install only Claude Code integration
  --codex-only    Install only Codex CLI integration

Selection is additive: installing for one client does not remove the other
client's integration, and omitting --hooks does not remove an existing hook.
Removal is always explicit (--remove-hooks or ./uninstall.sh).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hooks) WITH_HOOKS=1 ;;
    --remove-hooks) REMOVE_HOOKS=1 ;;
    --claude-only) INSTALL_CLAUDE=1; INSTALL_CODEX=0 ;;
    --codex-only) INSTALL_CLAUDE=0; INSTALL_CODEX=1 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'install.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [[ "$WITH_HOOKS" -eq 1 && "$REMOVE_HOOKS" -eq 1 ]]; then
  printf 'install.sh: --hooks and --remove-hooks are mutually exclusive\n' >&2
  exit 2
fi

for command in python3 cp mkdir rm readlink mktemp mv ln chmod; do
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
chmod 0755 -- "$TARGET/bin/beam-debug"
chmod 0755 -- "$TARGET/hooks/stop_guard.py"
chmod 0755 -- "$TARGET/lib/manage_install.py"
chmod 0755 -- "$TARGET/lib/journal.py"
chmod 0755 -- "$TARGET/lib/project_manifest.py"
chmod 0755 -- "$TARGET/uninstall.sh"
MANAGER="$TARGET/lib/manage_install.py"

# Record trusted absolute binary paths now, while PATH is the installing
# user's own. Everything package-owned resolves python3 and git through this
# file afterwards, so a project-prepended PATH (direnv, venv, a repo bin/)
# cannot substitute either binary under the Stop hook or the CLI.
PYTHON3_BIN="$(readlink -f -- "$(command -v python3)")"
if command -v git >/dev/null 2>&1; then
  GIT_BIN="$(readlink -f -- "$(command -v git)")"
else
  GIT_BIN=""
fi
printf 'python3=%s\ngit=%s\n' "$PYTHON3_BIN" "$GIT_BIN" > "$TARGET/lib/runtime-paths.conf"
chmod 0644 -- "$TARGET/lib/runtime-paths.conf"

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
if [[ "$REMOVE_HOOKS" -eq 1 ]]; then
  manager_args+=(--remove-hooks)
fi
"$PYTHON3_BIN" -I -S "$MANAGER" "${manager_args[@]}"

printf 'Installed elixir-agent-debug at %s\n' "$TARGET"
printf 'Command: %s\n' "$HOME/.local/bin/beam-debug"
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  printf 'Note: add %s to PATH for the beam-debug command.\n' "$HOME/.local/bin"
fi
if [[ "$WITH_HOOKS" -eq 1 && "$INSTALL_CODEX" -eq 1 ]]; then
  printf 'Codex only: inside a Codex CLI session, run /hooks once and trust the new hook; Claude Code needs no such step.\n'
fi
printf 'Start new agent CLI sessions to pick up the changes.\n'
printf 'Then verify the install from any shell: beam-debug doctor\n'
