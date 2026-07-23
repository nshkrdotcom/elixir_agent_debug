#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

printf 'Checking syntax...\n'
bash -n "$ROOT/install.sh" "$ROOT/uninstall.sh" "$ROOT/bin/beam-debug" \
  "$ROOT/tests/smoke.sh" "$ROOT/tests/integration.sh"
python3 -m py_compile "$ROOT/hooks/stop_guard.py" "$ROOT/lib/manage_install.py" \
  "$ROOT/lib/journal.py" "$ROOT/lib/project_manifest.py"

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
state="$(mktemp -d)"
trap 'rm -rf -- "$repo" "$home" "$state"' EXIT

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

(cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --assert-clean) \
  || fail 'committed markers should not trigger the changed-line guard'

cat > "$repo/sample.ex" <<'ELIXIR'
defmodule Sample do
  def value do
    IO.inspect(:ok, label: "BEAMDBG value") # BEAMDBG
  end
end
ELIXIR

if (cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --assert-clean >/dev/null 2>&1); then
  fail 'assert-clean did not detect a newly-added marker'
fi
(cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --scan | grep -q 'sample.ex:3') \
  || fail 'scan did not report expected line'

# The hook must fail open on a generic marker: no session ledger, no block —
# a global worktree scan cannot tell this session's instrumentation from
# another agent's active work or committed fixtures.
hook_out="$(printf '{"cwd":"%s","session_id":"sess-abc","stop_hook_active":false}' "$repo" \
  | XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py")"
[[ -z "$hook_out" ]] || fail "hook acted without a session ledger: $hook_out"

# ... and with no session metadata at all.
hook_out="$(printf '{"cwd":"%s","stop_hook_active":false}' "$repo" \
  | XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py")"
[[ -z "$hook_out" ]] || fail "hook did not fail open without session metadata: $hook_out"

git -C "$repo" checkout -q -- sample.ex

printf 'Checking session-owned Stop-hook semantics...\n'
token="$(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" \
  --begin --session-id sess-abc | sed -n 's/.*# BEAMDBG:\([0-9a-f]\{8\}\).*/\1/p' | head -1)"
[[ -n "$token" ]] || fail 'begin did not print a marker token'

token_again="$(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" \
  --begin --session-id sess-abc | sed -n 's/.*# BEAMDBG:\([0-9a-f]\{8\}\).*/\1/p' | head -1)"
[[ "$token" == "$token_again" ]] || fail 'begin was not idempotent for the same session'

cat > "$repo/sample.ex" <<ELIXIR
defmodule Sample do
  def value do
    IO.inspect(:ok, label: "BEAMDBG value") # BEAMDBG:$token
  end
end
ELIXIR

# The owning session is blocked once, and the reason names only its token.
hook_json="$(printf '{"cwd":"%s","session_id":"sess-abc","stop_hook_active":false}' "$repo" \
  | XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py")"
python3 - "$hook_json" "$token" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value["decision"] == "block", value
assert "sample.ex:3" in value["reason"], value
assert "BEAMDBG:" + sys.argv[2] in value["reason"], value
PY

# A different session sees the same markers and is not blocked.
hook_out="$(printf '{"cwd":"%s","session_id":"sess-other","stop_hook_active":false}' "$repo" \
  | XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py")"
[[ -z "$hook_out" ]] || fail "hook blocked a session that owns no markers: $hook_out"

# The second stop of the owning session is allowed with a warning: no loop.
hook_json="$(printf '{"cwd":"%s","session_id":"sess-abc","stop_hook_active":true}' "$repo" \
  | XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py")"
python3 - "$hook_json" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert "decision" not in value, value
assert "systemMessage" in value, value
PY

# end refuses while owned markers remain, names the token workflow, then
# succeeds after removal.
end_out="$(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" --end "$token" 2>&1)" \
  && fail 'end succeeded while owned markers remained'
printf '%s' "$end_out" | grep -q "beam-debug end $token" \
  || fail "end did not point back at itself: $end_out"

# An accidentally *committed* owned marker leaves a clean diff but must still
# be caught by the token-specific checks (hook and end).
git -C "$repo" add sample.ex
git -C "$repo" commit -qm 'accidentally committed instrumentation'
hook_json="$(printf '{"cwd":"%s","session_id":"sess-abc","stop_hook_active":false}' "$repo" \
  | XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py")"
python3 - "$hook_json" "$token" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value["decision"] == "block", value
assert "sample.ex:3" in value["reason"], value
assert "BEAMDBG:" + sys.argv[2] in value["reason"], value
PY
if (cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" --end "$token" >/dev/null 2>&1); then
  fail 'end missed a committed owned marker'
fi
# The whole-worktree audit stays newly-added-lines-only: the committed marker
# must not fail it.
(cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --assert-clean) \
  || fail 'assert-clean flagged committed content'

git -C "$repo" revert --no-edit HEAD >/dev/null
(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" --end "$token" >/dev/null) \
  || fail 'end failed after markers were removed'

# With the ledger retired the hook is inert again for that session.
hook_out="$(printf '{"cwd":"%s","session_id":"sess-abc","stop_hook_active":false}' "$repo" \
  | XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py")"
[[ -z "$hook_out" ]] || fail "hook still active after end: $hook_out"

# A marker staged in the index while the worktree is clean must still be
# caught: a worktree grep sees neither the diff nor the staged content, but
# the staged marker is exactly what the next commit would contain.
token_idx="$(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" \
  --begin --session-id sess-idx | sed -n 's/.*# BEAMDBG:\([0-9a-f]\{8\}\).*/\1/p' | head -1)"
[[ -n "$token_idx" ]] || fail 'begin (staged-index test) did not print a token'
cat > "$repo/sample.ex" <<ELIXIR
defmodule Sample do
  def value do
    IO.inspect(:ok, label: "BEAMDBG value") # BEAMDBG:$token_idx
  end
end
ELIXIR
git -C "$repo" add sample.ex
git -C "$repo" restore --source=HEAD --worktree sample.ex
if (cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" --end "$token_idx" >/dev/null 2>&1); then
  fail 'end missed a staged-only marker (dirty index, clean worktree)'
fi
hook_json="$(printf '{"cwd":"%s","session_id":"sess-idx","stop_hook_active":false}' "$repo" \
  | XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py")"
python3 - "$hook_json" "$token_idx" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value["decision"] == "block", value
assert "BEAMDBG:" + sys.argv[2] in value["reason"], value
PY
git -C "$repo" restore --staged sample.ex
(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" --end "$token_idx" >/dev/null) \
  || fail 'end failed after the staged marker was removed'

printf 'Checking untracked-file scan hardening (symlinks, non-regular files)...\n'
mkfifo "$repo/direct.ex"
mkfifo "$repo/fifo_target"
ln -s fifo_target "$repo/hang.ex"
printf 'contains a BEAMDBG marker\n' > "$repo/notes.txt"
ln -s notes.txt "$repo/alias.ex"
scan_out="$(cd "$repo" && timeout 15 python3 -I -S "$ROOT/hooks/stop_guard.py" --scan)" \
  || fail 'scan blocked or failed on symlinked/non-regular untracked files'
printf '%s' "$scan_out" | grep -q 'hang.ex' && fail 'scan read through a symlink to a FIFO'
printf '%s' "$scan_out" | grep -q 'direct.ex' && fail 'scan read a FIFO directly'
printf '%s' "$scan_out" | grep -q 'alias.ex' && fail 'scan followed a symlink to file content'
rm -f "$repo/direct.ex" "$repo/fifo_target" "$repo/hang.ex" "$repo/notes.txt" "$repo/alias.ex"

printf 'Checking state file permissions (ledger)...\n'
sessions_dir="$(find "$state" -type d -name sessions | head -1)"
[[ -n "$sessions_dir" ]] || fail 'no sessions directory was created'
[[ "$(stat -c %a "$sessions_dir")" == "700" ]] \
  || fail "sessions directory is not 0700: $(stat -c %a "$sessions_dir")"
ledger_token="$(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" \
  --begin --session-id sess-perms | sed -n 's/.*# BEAMDBG:\([0-9a-f]\{8\}\).*/\1/p' | head -1)"
ledger_file="$(find "$sessions_dir" -name "$ledger_token.json" | head -1)"
[[ -n "$ledger_file" ]] || fail 'ledger file not found'
[[ "$(stat -c %a "$ledger_file")" == "600" ]] \
  || fail "ledger file is not 0600: $(stat -c %a "$ledger_file")"

# A pre-1.4.4 ledger created under a permissive umask must be tightened when
# the session is reused, not only when a new ledger is created.
chmod 0644 -- "$ledger_file"
chmod 0755 -- "$sessions_dir"
(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" \
  --begin --session-id sess-perms >/dev/null) || fail 'begin (reuse) failed'
[[ "$(stat -c %a "$ledger_file")" == "600" ]] \
  || fail "reused ledger was not tightened to 0600: $(stat -c %a "$ledger_file")"
[[ "$(stat -c %a "$sessions_dir")" == "700" ]] \
  || fail "sessions directory was not re-tightened to 0700: $(stat -c %a "$sessions_dir")"

(cd "$repo" && XDG_STATE_HOME="$state" python3 -I -S "$ROOT/hooks/stop_guard.py" --end "$ledger_token" >/dev/null) \
  || fail 'could not retire the permissions-test ledger'

printf 'Checking Erlang marker coverage (unstaged, staged, untracked)...\n'
cat > "$repo/sample.erl" <<'ERLANG'
-module(sample).
-export([value/0]).
value() -> ok.
ERLANG
git -C "$repo" add sample.erl
git -C "$repo" commit -qm erlang-baseline

cat > "$repo/sample.erl" <<'ERLANG'
-module(sample).
-export([value/0]).
value() ->
    io:format("BEAMDBG value ~p~n", [ok]), % BEAMDBG
    ok.
ERLANG
(cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --scan | grep -q 'sample.erl:4') \
  || fail 'scan did not report an unstaged Erlang marker'

git -C "$repo" add sample.erl
(cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --scan | grep -q 'sample.erl:4') \
  || fail 'scan did not report a staged Erlang marker'
git -C "$repo" checkout -q HEAD -- sample.erl

cat > "$repo/probe.hrl" <<'ERLANG'
%% BEAMDBG probe macro
-define(PROBE, beamdbg).
ERLANG
(cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --scan | grep -q 'probe.hrl:1') \
  || fail 'scan did not report an untracked Erlang header marker'
if (cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --assert-clean >/dev/null 2>&1); then
  fail 'assert-clean passed while Erlang markers remained'
fi
rm -f "$repo/probe.hrl"
(cd "$repo" && python3 -I -S "$ROOT/hooks/stop_guard.py" --assert-clean >/dev/null) \
  || fail 'assert-clean failed after Erlang markers were removed'

printf 'Checking isolated install, idempotence, JSON preservation, capture, and uninstall...\n'
export HOME="$home"
export PATH="$HOME/.local/bin:$PATH"
export ELIXIR_AGENT_DEBUG_HOME="$HOME/.local/share/elixir-agent-debug"
mkdir -p "$HOME/.claude" "$HOME/.codex"
printf '# Existing Claude preference\n' > "$HOME/.claude/CLAUDE.md"
printf '# Existing Codex preference\n' > "$HOME/.codex/AGENTS.md"
# Each config carries an unrelated hook that must survive, plus every legacy
# package hook-command form — plain python3 (pre-1.4.3) and PATH-resolved
# python3 -I -S (1.4.3) — which the upgrade must migrate to one absolute
# isolated entry instead of leaving old forms firing beside it.
cat > "$HOME/.claude/settings.json" <<JSON
{
  "theme": "existing",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "echo existing-claude"},
          {"type": "command", "command": "python3 $ELIXIR_AGENT_DEBUG_HOME/hooks/stop_guard.py"},
          {"type": "command", "command": "python3 -I -S $ELIXIR_AGENT_DEBUG_HOME/hooks/stop_guard.py"}
        ]
      }
    ]
  }
}
JSON
cat > "$HOME/.codex/hooks.json" <<JSON
{
  "description": "existing",
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {"type": "command", "command": "echo existing-codex"},
          {"type": "command", "command": "python3 $ELIXIR_AGENT_DEBUG_HOME/hooks/stop_guard.py"},
          {"type": "command", "command": "python3 -I -S $ELIXIR_AGENT_DEBUG_HOME/hooks/stop_guard.py"}
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
    # Exactly one package hook: both legacy forms must have been migrated,
    # not joined, and the survivor runs an absolute interpreter isolated
    # from PATH and Python environment injection.
    assert len(package) == 1, (name, package)
    assert package[0].startswith("/"), (name, package)
    assert " -I -S " in package[0], (name, package)
    assert expected_existing[index] in commands, (name, commands)
PY

"$ROOT/install.sh" --remove-hooks
python3 - "$HOME/.claude/settings.json" "$HOME/.codex/hooks.json" <<'PY'
import json
import sys
expected_existing = ["echo existing-claude", "echo existing-codex"]
for index, name in enumerate(sys.argv[1:]):
    with open(name, encoding="utf-8") as handle:
        data = json.load(handle)
    entries = data.get("hooks", {}).get("Stop", [])
    commands = [hook["command"] for entry in entries for hook in entry["hooks"]]
    package = [value for value in commands if "elixir-agent-debug/hooks/stop_guard.py" in value]
    assert not package, (name, package)
    assert expected_existing[index] in commands, (name, commands)
PY
"$ROOT/install.sh" --hooks

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

journal_file="$(find "$HOME/.local/state/beam-debug" -name journal.jsonl | head -1)"
[[ -n "$journal_file" ]] || fail 'journal file not found'
[[ "$(stat -c %a "$journal_file")" == "600" ]] \
  || fail "journal is not 0600: $(stat -c %a "$journal_file")"
capture_log="$(find "$HOME/.local/state/beam-debug" -name latest.log | head -1)"
[[ -n "$capture_log" ]] || fail 'capture log not found'
[[ "$(stat -c %a "$capture_log")" == "600" ]] \
  || fail "capture log is not 0600: $(stat -c %a "$capture_log")"
[[ "$(stat -c %a "$(dirname -- "$capture_log")")" == "700" ]] \
  || fail "state directory is not 0700: $(stat -c %a "$(dirname -- "$capture_log")")"

printf 'Checking per-project manifest and version floor...\n'
if python3 -c 'import tomllib' >/dev/null 2>&1; then
  (
    cd "$repo"
    "$HOME/.local/bin/beam-debug" init-project >/dev/null
    "$HOME/.local/bin/beam-debug" init-project >/dev/null
  ) || fail 'init-project failed'
  [[ -f "$repo/.beam-debug.toml" ]] || fail 'init-project did not write the manifest'
  grep -q "minimum_version = \"$(cat "$ROOT/VERSION")\"" "$repo/.beam-debug.toml" \
    || fail 'manifest minimum_version does not match the installed version'
  [[ "$(grep -c 'elixir-agent-debug:begin' "$repo/CLAUDE.md")" -eq 1 ]] \
    || fail 'project CLAUDE.md block missing or duplicated'
  [[ "$(grep -c 'elixir-agent-debug:begin' "$repo/AGENTS.md")" -eq 1 ]] \
    || fail 'project AGENTS.md block missing or duplicated'
  grep -q 'never install or upgrade user-level tooling' "$repo/CLAUDE.md" \
    || fail 'project note must forbid agent-run installation'

  printf 'enabled = true\nminimum_version = "99.0.0"\n' > "$repo/.beam-debug.toml"
  set +e
  (cd "$repo" && "$HOME/.local/bin/beam-debug" history) >/dev/null 2>&1
  floor_status=$?
  set -e
  [[ "$floor_status" -eq 3 ]] || fail "an unmet version floor should exit 3 (got $floor_status)"
  (cd "$repo" && "$HOME/.local/bin/beam-debug" help >/dev/null) \
    || fail 'help must stay reachable under an unmet floor'
  if (cd "$repo" && "$HOME/.local/bin/beam-debug" doctor >/dev/null 2>&1); then
    fail 'doctor should exit nonzero under an unmet floor'
  fi
  # Recovery commands must never be locked out by the floor.
  (cd "$repo" && "$HOME/.local/bin/beam-debug" scan >/dev/null) \
    || fail 'scan must stay reachable under an unmet floor'
  (cd "$repo" && "$HOME/.local/bin/beam-debug" assert-clean >/dev/null) \
    || fail 'assert-clean must stay reachable under an unmet floor'
  (cd "$repo" && XDG_STATE_HOME="$state" "$HOME/.local/bin/beam-debug" end >/dev/null) \
    || fail 'end must stay reachable under an unmet floor'
  # init-project must refuse to rewrite the notes of a project it is too old for.
  if (cd "$repo" && "$HOME/.local/bin/beam-debug" init-project >/dev/null 2>&1); then
    fail 'init-project rewrote a project whose floor it does not meet'
  fi
  # A requirement manifest fails closed on strict-TOML grounds, not only on
  # bad values: unterminated strings, duplicate keys, quoted booleans,
  # missing required keys and unknown keys are all errors.
  while IFS= read -r bad; do
    printf '%b\n' "$bad" > "$repo/.beam-debug.toml"
    if (cd "$repo" && "$HOME/.local/bin/beam-debug" history >/dev/null 2>&1); then
      fail "a malformed manifest must be an error: $bad"
    fi
  done <<'BADCASES'
enabled = maybe
enabled = "true"
enabled = "true
enabled = true\nenabled = true
enabled = true\nminimum_version = "banana"
enabled = true\nminimum_version = "1.4.1
enabled = true
enabled = true\nminimum_version = "1.0.0"\nextra = 1
BADCASES
  if (cd "$repo" && "$HOME/.local/bin/beam-debug" doctor >/dev/null 2>&1); then
    fail 'doctor should exit nonzero on a malformed manifest'
  fi
  printf 'enabled = false\n' > "$repo/.beam-debug.toml"
  (cd "$repo" && "$HOME/.local/bin/beam-debug" history >/dev/null) \
    || fail 'enabled = false must disable the floor check'
  # A disabled floor is a deliberate passing state: doctor reports it as an
  # explicit ok-line (the project note requires one before proceeding), and
  # init-project cannot verify template compatibility against it.
  doctor_out="$( (cd "$repo" && "$HOME/.local/bin/beam-debug" doctor) 2>&1 || true )"
  printf '%s' "$doctor_out" | grep -q 'ok: project floor disabled by manifest' \
    || fail "doctor must report a disabled floor as an ok line: $doctor_out"
  if (cd "$repo" && "$HOME/.local/bin/beam-debug" init-project >/dev/null 2>&1); then
    fail 'init-project must not rewrite notes while the floor is disabled'
  fi
  printf 'enabled = true\nminimum_version = "1.0.0"\n' > "$repo/.beam-debug.toml"
  (cd "$repo" && "$HOME/.local/bin/beam-debug" history >/dev/null) \
    || fail 'a satisfied floor must not block commands'
else
  printf 'note: python3 lacks tomllib (needs 3.11+); checking fail-closed behavior only.\n'
  (cd "$repo" && "$HOME/.local/bin/beam-debug" init-project >/dev/null) \
    || fail 'init-project failed'
  printf 'enabled = true\nminimum_version = "1.0.0"\n' > "$repo/.beam-debug.toml"
  if (cd "$repo" && "$HOME/.local/bin/beam-debug" history >/dev/null 2>&1); then
    fail 'the floor must fail closed when tomllib is unavailable'
  fi
fi

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
