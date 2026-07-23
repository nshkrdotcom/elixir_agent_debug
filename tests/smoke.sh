#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

printf 'Checking syntax...\n'
bash -n "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/bin/beam-debug" "$ROOT/tests/smoke.sh"
python3 -m py_compile "$ROOT/hooks/stop_guard.py" "$ROOT/lib/manage_install.py" "$ROOT/lib/journal.py"

printf 'Checking that test runs are not silently serialized...\n'
grep -q 'exec mix test "\$@"' "$ROOT/bin/beam-debug" \
  || fail '`beam-debug test` must be a plain mix test passthrough (no implicit --trace)'
grep -q 'exec iex -r "\$HELPER" -S mix test --trace' "$ROOT/bin/beam-debug" \
  || fail '`beam-debug pry-test` must keep --trace'

printf 'Checking Elixir helper and probe syntax...\n'
if command -v elixirc >/dev/null 2>&1; then
  probe_out="$(mktemp -d)"
  # One invocation so the probes can reference the helper module.
  (cd "$probe_out" && elixirc \
    "$ROOT/support/beam_debug.exs" \
    "$ROOT/support/probe_trace.exs" \
    "$ROOT/support/probe_snapshot.exs" >/dev/null) \
    || fail 'failed to compile the BEAM helper and probes'
  rm -rf -- "$probe_out"
else
  printf 'note: elixirc not available; skipped BEAM helper compilation.\n'
fi

printf 'Checking marker scanner and Stop-hook output...\n'
repo="$(mktemp -d)"
home="$(mktemp -d)"
trap 'rm -rf -- "$repo" "$home"' EXIT

git -C "$repo" init -q
git -C "$repo" config user.email smoke@example.invalid
git -C "$repo" config user.name Smoke
cat > "$repo/sample.ex" <<'ELIXIR'
defmodule Sample do
  def value, do: :ok
end
ELIXIR
cat > "$repo/old_marker.ex" <<'ELIXIR'
defmodule OldMarker do
  # A committed historical marker must not make the guard fail. # BEAMDBG
  def value, do: :ok
end
ELIXIR
git -C "$repo" add sample.ex old_marker.ex
git -C "$repo" commit -qm baseline

(cd "$repo" && python3 "$ROOT/hooks/stop_guard.py" --assert-clean) \
  || fail 'committed markers should not trigger the changed-line guard'

cat > "$repo/sample.ex" <<'ELIXIR'
defmodule Sample do
  def value do
    IO.inspect(:ok, label: "BEAMDBG value") # BEAMDBG
  end
end
ELIXIR

if (cd "$repo" && python3 "$ROOT/hooks/stop_guard.py" --assert-clean >/dev/null 2>&1); then
  fail 'assert-clean did not detect a newly-added marker'
fi
(cd "$repo" && python3 "$ROOT/hooks/stop_guard.py" --scan | grep -q 'sample.ex:3') \
  || fail 'scan did not report expected line'

hook_json="$(printf '{"cwd":"%s","stop_hook_active":false}' "$repo" | python3 "$ROOT/hooks/stop_guard.py")"
python3 - "$hook_json" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value["decision"] == "block", value
assert "sample.ex:3" in value["reason"], value
PY

git -C "$repo" checkout -q -- sample.ex

printf 'Checking isolated install, idempotence, JSON preservation, capture, and uninstall...\n'
export HOME="$home"
export PATH="$HOME/.local/bin:$PATH"
export ELIXIR_AGENT_DEBUG_HOME="$HOME/.local/share/elixir-agent-debug"
mkdir -p "$HOME/.claude" "$HOME/.codex"
printf '# Existing Claude preference\n' > "$HOME/.claude/CLAUDE.md"
printf '# Existing Codex preference\n' > "$HOME/.codex/AGENTS.md"
cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "theme": "existing",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "echo existing-claude"}
        ]
      }
    ]
  }
}
JSON
cat > "$HOME/.codex/hooks.json" <<'JSON'
{
  "description": "existing",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "echo existing-codex"}
        ]
      }
    ]
  }
}
JSON

"$ROOT/install.sh" --hooks
"$ROOT/install.sh" --hooks

[[ -x "$HOME/.local/bin/beam-debug" ]] || fail 'beam-debug not installed'
[[ -f "$HOME/.claude/skills/elixir-debug/SKILL.md" ]] || fail 'Claude skill missing'
[[ -f "$HOME/.agents/skills/elixir-debug/SKILL.md" ]] || fail 'Codex skill missing'
[[ "$(grep -c 'elixir-agent-debug:begin' "$HOME/.claude/CLAUDE.md")" -eq 1 ]] \
  || fail 'Claude instruction block duplicated'
[[ "$(grep -c 'elixir-agent-debug:begin' "$HOME/.codex/AGENTS.md")" -eq 1 ]] \
  || fail 'Codex instruction block duplicated'
grep -q 'Existing Claude preference' "$HOME/.claude/CLAUDE.md" \
  || fail 'existing Claude instructions were not preserved'
grep -q 'Existing Codex preference' "$HOME/.codex/AGENTS.md" \
  || fail 'existing Codex instructions were not preserved'

python3 - "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" <<'PY'
import json
import sys
expected_existing = ["echo existing-claude", "echo existing-codex"]
for index, name in enumerate(sys.argv[1:]):
    with open(name, encoding="utf-8") as handle:
        data = json.load(handle)
    entries = data["hooks"]["Stop"]
    commands = [hook["command"] for entry in entries for hook in entry["hooks"]]
    package = [value for value in commands if "elixir-agent-debug/hooks/stop_guard.py" in value]
    assert len(package) == 1, (name, package)
    assert expected_existing[index] in commands, (name, commands)
PY

"$HOME/.local/bin/beam-debug" help >/dev/null

printf 'Checking argument validation and the evidence journal...\n'
if (cd "$repo" && "$HOME/.local/bin/beam-debug" trace >/dev/null 2>&1); then
  fail 'trace without a target should be rejected'
fi
if (cd "$repo" && "$HOME/.local/bin/beam-debug" trace Foo --bogus >/dev/null 2>&1); then
  fail 'trace should reject unknown options'
fi
if (cd "$repo" && "$HOME/.local/bin/beam-debug" trace Foo --limit banana >/dev/null 2>&1); then
  fail 'trace should reject a non-integer --limit'
fi
if (cd "$repo" && "$HOME/.local/bin/beam-debug" trace Foo --limit 0 >/dev/null 2>&1); then
  fail 'trace should reject --limit 0'
fi
if (cd "$repo" && "$HOME/.local/bin/beam-debug" snapshot --after -5 >/dev/null 2>&1); then
  fail 'snapshot should reject a negative --after'
fi
if (cd "$repo" && "$HOME/.local/bin/beam-debug" snapshot --top x >/dev/null 2>&1); then
  fail 'snapshot should reject a non-integer --top'
fi
(
  cd "$repo"
  "$HOME/.local/bin/beam-debug" note 'mailbox theory' --status killed --evidence 'trace shows 3 calls' >/dev/null
  "$HOME/.local/bin/beam-debug" note 'ttl theory' --status confirmed >/dev/null
  "$HOME/.local/bin/beam-debug" history | grep -q 'mailbox theory'
) || fail 'journal note/history did not round-trip'
(cd "$repo" && "$HOME/.local/bin/beam-debug" report | grep -q 'Ruled out by evidence (1)') \
  || fail 'journal report did not group entries by status'
set +e
(
  cd "$repo"
  "$HOME/.local/bin/beam-debug" capture -- sh -c 'printf "captured-output\\n"; exit 7'
) >/dev/null 2>&1
capture_status=$?
set -e
[[ "$capture_status" -eq 7 ]] || fail "capture did not preserve exit status (got $capture_status)"
(
  cd "$repo"
  "$HOME/.local/bin/beam-debug" latest | grep -q 'captured-output'
) || fail 'captured log was not retrievable'

"$ELIXIR_AGENT_DEBUG_HOME/uninstall.sh"

[[ ! -e "$HOME/.local/bin/beam-debug" ]] || fail 'beam-debug symlink remained'
[[ ! -e "$HOME/.claude/skills/elixir-debug" ]] || fail 'Claude skill remained'
[[ ! -e "$HOME/.agents/skills/elixir-debug" ]] || fail 'Codex skill remained'
[[ ! -e "$ELIXIR_AGENT_DEBUG_HOME" ]] || fail 'package directory remained'
! grep -q 'elixir-agent-debug:begin' "$HOME/.claude/CLAUDE.md" || fail 'Claude block remained'
! grep -q 'elixir-agent-debug:begin' "$HOME/.codex/AGENTS.md" || fail 'Codex block remained'
grep -q 'Existing Claude preference' "$HOME/.claude/CLAUDE.md" || fail 'existing Claude text was removed'
grep -q 'Existing Codex preference' "$HOME/.codex/AGENTS.md" || fail 'existing Codex text was removed'
grep -q 'existing-claude' "$HOME/.claude/settings.json" || fail 'existing Claude hook was removed'
grep -q 'existing-codex' "$HOME/.codex/hooks.json" || fail 'existing Codex hook was removed'
! grep -q 'stop_guard.py' "$HOME/.claude/settings.json" || fail 'package Claude hook remained'
! grep -q 'stop_guard.py' "$HOME/.codex/hooks.json" || fail 'package Codex hook remained'

printf 'PASS\n'
