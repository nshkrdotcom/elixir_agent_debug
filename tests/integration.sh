#!/usr/bin/env bash
# End-to-end tests for `beam-debug trace` and `beam-debug snapshot` against a
# generated throwaway Mix project. Requires elixir/mix; exits 0 with a note
# when they are unavailable so CI without a BEAM toolchain still passes smoke.
#
# Usage: tests/integration.sh [scenario-filter]
#   scenario-filter: run only scenarios whose name contains this substring.
set -uo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
BEAM_DEBUG="$ROOT/bin/beam-debug"
FILTER="${1:-}"

if ! command -v elixir >/dev/null 2>&1 || ! command -v mix >/dev/null 2>&1; then
  printf 'SKIP: elixir/mix not available; integration tests need a BEAM toolchain.\n'
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
PROJECT="$WORK/demo"
OUT="$WORK/out.log"
FAILURES=0
RAN=0

# --- fixture: a minimal Mix project ------------------------------------------

mkdir -p "$PROJECT/lib" "$PROJECT/test"

cat > "$PROJECT/mix.exs" <<'EOF'
defmodule Demo.MixProject do
  use Mix.Project

  def project do
    [app: :demo, version: "0.1.0", elixir: "~> 1.14", deps: []]
  end

  def application do
    [extra_applications: [:logger]]
  end
end
EOF

cat > "$PROJECT/lib/demo.ex" <<'EOF'
defmodule Demo do
  def compute(n) do
    :lists.seq(1, n) |> Enum.sum()
  end
end

defmodule Demo.Worker do
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: {:ok, %{marker: :demo_state_marker_7519}}

  @impl true
  def handle_call(:ping, _from, state), do: {:reply, :pong, state}
end

defmodule Demo.Blocker do
  use GenServer

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call(:block, _from, state) do
    wait_forever()
    {:reply, :ok, state}
  end

  def wait_forever do
    receive do
      :never_comes -> :ok
    end
  end
end
EOF

cat > "$PROJECT/test/test_helper.exs" <<'EOF'
ExUnit.start()
EOF

cat > "$PROJECT/test/fast_test.exs" <<'EOF'
defmodule FastTest do
  use ExUnit.Case

  test "calls compute immediately" do
    # 200 keeps inspect from rendering the argument list as a charlist.
    assert Demo.compute(200) == 20_100
  end
end
EOF

cat > "$PROJECT/test/many_test.exs" <<'EOF'
defmodule ManyTest do
  use ExUnit.Case

  test "calls compute many times" do
    for _ <- 1..10, do: Demo.compute(3)
    assert true
  end
end
EOF

cat > "$PROJECT/test/worker_test.exs" <<'EOF'
defmodule WorkerTest do
  use ExUnit.Case

  test "worker survives a snapshot aimed at it" do
    {:ok, _pid} = Demo.Worker.start_link()
    # Outlive the snapshot watchdog, then prove the worker was not crashed
    # by whatever the snapshot sent it.
    Process.sleep(2_500)
    assert GenServer.call(Demo.Worker, :ping) == :pong
  end
end
EOF

cat > "$PROJECT/test/mailbox_test.exs" <<'EOF'
defmodule MailboxTest do
  use ExUnit.Case

  test "a large mailbox is reported without being copied" do
    pid = spawn(fn -> Demo.Blocker.wait_forever() end)
    Process.register(pid, :mailbox_hog)
    for i <- 1..150_000, do: send(pid, {:filler, i})
    # Keep the queue alive past the watchdog.
    Process.sleep(2_500)
    assert Process.alive?(pid)
  end
end
EOF

cat > "$PROJECT/test/block_test.exs" <<'EOF'
defmodule BlockTest do
  use ExUnit.Case

  test "blocks on a genserver that never replies" do
    {:ok, _pid} = Demo.Blocker.start_link()
    GenServer.call(Demo.Blocker, :block, 4_000)
  end
end
EOF

cat > "$PROJECT/test/sup_test.exs" <<'EOF'
defmodule SupTest do
  use ExUnit.Case

  test "a supervised worker outlives the watchdog" do
    {:ok, _pid} =
      Supervisor.start_link([Demo.Worker], strategy: :one_for_one, name: Demo.Sup)

    Process.sleep(2_500)
    assert GenServer.call(Demo.Worker, :ping) == :pong
  end
end
EOF

cat > "$PROJECT/test/failing_test.exs" <<'EOF'
defmodule FailingTest do
  use ExUnit.Case

  test "fails after calling compute" do
    assert Demo.compute(9) == :wrong
  end
end
EOF

cat > "$PROJECT/test/late_test.exs" <<'EOF'
defmodule LateHelper do
  def double(n), do: n + n
end

defmodule LateTest do
  use ExUnit.Case

  test "uses a module defined in this test file" do
    Process.sleep(300)
    assert LateHelper.double(150) == 300
  end
end
EOF

cat > "$PROJECT/test/window_test.exs" <<'EOF'
defmodule WindowTest do
  use ExUnit.Case
  @moduletag timeout: 30_000

  test "calls before and after the trace window" do
    Demo.compute(300)
    Process.sleep(6_000)
    Demo.compute(301)
  end
end
EOF

# A second project whose mix.exs starts a :dbg session at project-load time,
# i.e. before any probe can install — a genuine pre-existing tracer.
CONFLICT="$WORK/demo2"
mkdir -p "$CONFLICT/lib" "$CONFLICT/test"

cat > "$CONFLICT/mix.exs" <<'EOF'
{:ok, _} = :dbg.tracer()

defmodule Demo2.MixProject do
  use Mix.Project

  def project do
    [app: :demo2, version: "0.1.0", deps: []]
  end
end
EOF

cat > "$CONFLICT/lib/demo2.ex" <<'EOF'
defmodule Demo2 do
  def ping(n), do: n
end
EOF

cat > "$CONFLICT/test/test_helper.exs" <<'EOF'
ExUnit.start()
EOF

cat > "$CONFLICT/test/ping_test.exs" <<'EOF'
defmodule PingTest do
  use ExUnit.Case

  test "pings" do
    assert Demo2.ping(170) == 170
  end
end
EOF

# --- harness ------------------------------------------------------------------

# run <scenario-name> <working-dir> [--expect-status N] -- command...
# Captures combined output into $OUT; status into $STATUS.
STATUS=0
run() {
  local name="$1" dir="$2"
  shift 2
  if [[ "$1" == "--" ]]; then shift; fi
  (cd "$dir" && "$@") >"$OUT" 2>&1
  STATUS=$?
}

skip_scenario() {
  [[ -n "$FILTER" && "$1" != *"$FILTER"* ]]
}

pass() {
  printf 'ok: %s\n' "$1"
}

fail_scenario() {
  printf 'FAIL: %s\n' "$1" >&2
  sed 's/^/    | /' "$OUT" | tail -40 >&2
  FAILURES=$((FAILURES + 1))
}

expect_contains() {
  local name="$1" pattern="$2"
  if ! grep -Eq -- "$pattern" "$OUT"; then
    printf '  missing pattern: %s\n' "$pattern" >&2
    return 1
  fi
}

expect_not_contains() {
  local name="$1" pattern="$2"
  if grep -Eq -- "$pattern" "$OUT"; then
    printf '  forbidden pattern present: %s\n' "$pattern" >&2
    return 1
  fi
}

scenario() {
  local name="$1"
  if skip_scenario "$name"; then
    return 1
  fi
  RAN=$((RAN + 1))
  return 0
}

# --- helper-level scenarios (no probe / CLI involved) -------------------------

if scenario helper-limit-exact; then
  # A4: with exactly `limit` events and nothing after them, the tracer must
  # still announce that it stopped at the limit.
  run helper-limit-exact "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    {:ok, _} = BeamDebug.trace_calls({:lists, :reverse, 1}, limit: 2)
    :lists.reverse([1, 2, 3])
    BeamDebug.flush_trace()
    Process.sleep(200)
    IO.puts("HELPER-DONE")
  '
  if expect_contains helper-limit-exact 'trace limit 2 reached' &&
     expect_contains helper-limit-exact 'HELPER-DONE'; then
    pass helper-limit-exact
  else
    fail_scenario helper-limit-exact
  fi
fi

if scenario helper-limit-no-overrun; then
  # A4: `--limit 3` prints exactly three events, not four.
  run helper-limit-no-overrun "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    {:ok, _} = BeamDebug.trace_calls({:lists, :reverse, 1}, limit: 3)
    for _ <- 1..10, do: :lists.reverse([1, 2, 3])
    BeamDebug.flush_trace()
    Process.sleep(200)
    IO.puts("HELPER-DONE")
  '
  events="$(grep -Ec '(call|return) :lists\.reverse/1' "$OUT")"
  if [[ "$events" -eq 3 ]] && expect_contains helper-limit-no-overrun 'trace limit 3 reached'; then
    pass helper-limit-no-overrun
  else
    printf '  expected exactly 3 traced events, got %s\n' "$events" >&2
    fail_scenario helper-limit-no-overrun
  fi
fi

if scenario helper-replace-guard; then
  # E4: a second trace must not silently destroy an existing tracer.
  run helper-replace-guard "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    {:ok, _} = BeamDebug.trace_calls({:lists, :reverse, 1}, limit: 5)
    {:error, :tracer_already_running} = BeamDebug.trace_calls({:lists, :seq, 2}, limit: 5)
    {:ok, _} = BeamDebug.trace_calls({:lists, :seq, 2}, limit: 5, replace: true)
    BeamDebug.stop_calls()
    IO.puts("REPLACE-GUARD-OK")
  '
  if expect_contains helper-replace-guard 'REPLACE-GUARD-OK'; then
    pass helper-replace-guard
  else
    fail_scenario helper-replace-guard
  fi
fi

if scenario helper-restart-after-limit; then
  # 1c: reaching the limit must release ownership so a new trace can start.
  run helper-restart-after-limit "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    {:ok, _} = BeamDebug.trace_calls({:lists, :reverse, 1}, limit: 2)
    :lists.reverse([1, 2, 3])
    BeamDebug.flush_trace()
    Process.sleep(300)
    case BeamDebug.trace_calls({:lists, :seq, 2}, limit: 5) do
      {:ok, _} -> IO.puts("RESTART-OK")
      other -> IO.puts("RESTART-FAILED #{inspect(other)}")
    end
    BeamDebug.stop_calls()
  '
  if expect_contains helper-restart-after-limit 'RESTART-OK'; then
    pass helper-restart-after-limit
  else
    fail_scenario helper-restart-after-limit
  fi
fi

if scenario helper-zero-match-clean; then
  # 1c: a zero-match trace is useless and must leave no live session behind.
  run helper-zero-match-clean "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    {:ok, 0} = BeamDebug.trace_calls({:lists, :nosuchfun, 9})
    case BeamDebug.trace_calls({:lists, :seq, 2}, limit: 5) do
      {:ok, n} when n > 0 -> IO.puts("ZERO-MATCH-CLEAN")
      other -> IO.puts("ZERO-MATCH-DIRTY #{inspect(other)}")
    end
    BeamDebug.stop_calls()
  '
  if expect_contains helper-zero-match-clean 'ZERO-MATCH-CLEAN'; then
    pass helper-zero-match-clean
  else
    fail_scenario helper-zero-match-clean
  fi
fi

if scenario helper-mailbox-not-copied; then
  # A2: a large mailbox must be reported by length, not materialized.
  run helper-mailbox-not-copied "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    pid = spawn(fn -> receive do: (:never -> :ok) end)
    for i <- 1..50_000, do: send(pid, {:filler, i})
    snap = BeamDebug.snapshot(pid)
    case snap.messages do
      {:omitted, {:mailbox_too_large, n}} when n > 100 -> IO.puts("MAILBOX-OMITTED #{n}")
      other -> IO.puts("MAILBOX-UNEXPECTED #{inspect(other, limit: 5)}")
    end
  '
  if expect_contains helper-mailbox-not-copied 'MAILBOX-OMITTED'; then
    pass helper-mailbox-not-copied
  else
    fail_scenario helper-mailbox-not-copied
  fi
fi

if scenario helper-small-mailbox-sampled; then
  # A2: small mailboxes still get a sample.
  run helper-small-mailbox-sampled "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    pid = spawn(fn -> receive do: (:never -> :ok) end)
    for i <- 1..5, do: send(pid, {:filler, i})
    snap = BeamDebug.snapshot(pid)
    IO.puts("SAMPLE #{inspect(snap.messages)}")
  '
  if expect_contains helper-small-mailbox-sampled 'SAMPLE \[filler: 1'; then
    pass helper-small-mailbox-sampled
  else
    fail_scenario helper-small-mailbox-sampled
  fi
fi

if scenario helper-snapshot-no-children-probe; then
  # A1: snapshot of an ordinary process must not send it a supervisor call.
  run helper-snapshot-no-children-probe "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    {:ok, agent} = Agent.start_link(fn -> :fine end)
    snap = BeamDebug.snapshot(agent)
    if Map.has_key?(snap, :children) do
      IO.puts("SNAPSHOT-STILL-PROBES-CHILDREN")
    else
      Process.sleep(50)
      IO.puts("AGENT-ALIVE #{Process.alive?(agent)} STATE #{inspect(snap.state)}")
    end
  '
  if expect_contains helper-snapshot-no-children-probe 'AGENT-ALIVE true STATE \{:ok, :fine\}'; then
    pass helper-snapshot-no-children-probe
  else
    fail_scenario helper-snapshot-no-children-probe
  fi
fi

if scenario helper-supervisor-children-explicit; then
  # A1: the explicit accessor still answers for a real supervisor and degrades
  # to an error for a non-supervisor without crashing the caller.
  run helper-supervisor-children-explicit "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    children = [%{id: :a, start: {Agent, :start_link, [fn -> 0 end]}}]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
    {:ok, [{:a, _, _, _}]} = BeamDebug.supervisor_children(sup)
    {:ok, plain} = Agent.start(fn -> 0 end)
    {:error, _} = BeamDebug.supervisor_children(plain)
    IO.puts("SUP-CHILDREN-OK")
  '
  if expect_contains helper-supervisor-children-explicit 'SUP-CHILDREN-OK'; then
    pass helper-supervisor-children-explicit
  else
    fail_scenario helper-supervisor-children-explicit
  fi
fi

if scenario helper-parse-erlang-target; then
  # E3: an explicit syntax for Erlang modules.
  run helper-parse-erlang-target "$WORK" -- elixir -r "$ROOT/support/beam_debug.exs" -e '
    {:lists, :seq, 2} = BeamDebug.parse_target(":lists.seq/2")
    {:lists, :seq, :_} = BeamDebug.parse_target(":lists.seq")
    {:lists, :_, :_} = BeamDebug.parse_target(":lists")
    {Demo.Worker, :handle_call, 3} = BeamDebug.parse_target("Demo.Worker.handle_call/3")
    IO.puts("PARSE-OK")
  '
  if expect_contains helper-parse-erlang-target 'PARSE-OK'; then
    pass helper-parse-erlang-target
  else
    fail_scenario helper-parse-erlang-target
  fi
fi

# --- CLI validation scenarios (no project needed) -----------------------------

if scenario cli-rejects-bad-integers; then
  ok=1
  run cli-limit "$WORK" -- "$BEAM_DEBUG" trace Demo --limit banana
  [[ "$STATUS" -eq 2 ]] && expect_contains cli-limit 'integer' || ok=0
  run cli-for "$WORK" -- "$BEAM_DEBUG" trace Demo --for -3
  [[ "$STATUS" -eq 2 ]] || ok=0
  run cli-after "$WORK" -- "$BEAM_DEBUG" snapshot --after x2
  [[ "$STATUS" -eq 2 ]] && expect_contains cli-after 'integer' || ok=0
  run cli-top "$WORK" -- "$BEAM_DEBUG" snapshot --top ""
  [[ "$STATUS" -eq 2 ]] || ok=0
  run cli-limit-zero "$WORK" -- "$BEAM_DEBUG" trace Demo --limit 0
  [[ "$STATUS" -eq 2 ]] || ok=0
  if [[ "$ok" -eq 1 ]]; then
    pass cli-rejects-bad-integers
  else
    fail_scenario cli-rejects-bad-integers
  fi
fi

# --- full CLI scenarios against the fixture project ---------------------------

if scenario trace-fast-first-call; then
  # A3: the very first invocation in a fast test must be captured.
  run trace-fast-first-call "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 -- mix test test/fast_test.exs
  if [[ "$STATUS" -eq 0 ]] &&
     expect_contains trace-fast-first-call 'call Demo\.compute/1' &&
     expect_contains trace-fast-first-call 'args: \[200\]' &&
     expect_contains trace-fast-first-call 'value: 20100'; then
    pass trace-fast-first-call
  else
    printf '  expected status 0 (got %s) with traced events\n' "$STATUS" >&2
    fail_scenario trace-fast-first-call
  fi
fi

if scenario trace-after-clean-compile; then
  # A3: works when the project must be compiled from scratch in the same run.
  rm -rf "$PROJECT/_build"
  run trace-after-clean-compile "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 -- mix test test/fast_test.exs
  if expect_contains trace-after-clean-compile 'call Demo\.compute/1' &&
     expect_contains trace-after-clean-compile 'value: 20100'; then
    pass trace-after-clean-compile
  else
    fail_scenario trace-after-clean-compile
  fi
fi

if scenario trace-after-recompile; then
  # A3: works right after the target module changed and must be recompiled.
  printf '\n# recompile marker %s\n' "$RANDOM" >> "$PROJECT/lib/demo.ex"
  run trace-after-recompile "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 -- mix test test/fast_test.exs
  if expect_contains trace-after-recompile 'call Demo\.compute/1' &&
     expect_contains trace-after-recompile 'value: 20100'; then
    pass trace-after-recompile
  else
    fail_scenario trace-after-recompile
  fi
fi

if scenario trace-absent-target-fails; then
  # A3: a target that never loads must produce an explicit failure, not silence.
  run trace-absent-target-fails "$PROJECT" -- \
    "$BEAM_DEBUG" trace Nosuch.fun/1 -- mix test test/fast_test.exs
  if [[ "$STATUS" -ne 0 ]] && expect_contains trace-absent-target-fails 'Nosuch'; then
    pass trace-absent-target-fails
  else
    printf '  expected nonzero exit and an explicit diagnostic (status %s)\n' "$STATUS" >&2
    fail_scenario trace-absent-target-fails
  fi
fi

if scenario trace-absent-function-fails; then
  # A3: an existing module with a function that matches nothing must also fail.
  run trace-absent-function-fails "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.nosuch/3 -- mix test test/fast_test.exs
  if [[ "$STATUS" -ne 0 ]] && expect_contains trace-absent-function-fails 'match'; then
    pass trace-absent-function-fails
  else
    printf '  expected nonzero exit for a no-match pattern (status %s)\n' "$STATUS" >&2
    fail_scenario trace-absent-function-fails
  fi
fi

if scenario trace-limit-stops; then
  # A4 end to end: `--limit 3` prints at most three events and reports stopping.
  run trace-limit-stops "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 --limit 3 -- mix test test/many_test.exs
  events="$(grep -Ec '(call|return) Demo\.compute/1' "$OUT")"
  if [[ "$STATUS" -eq 0 && "$events" -le 3 && "$events" -ge 1 ]] &&
     expect_contains trace-limit-stops 'trace limit 3 reached'; then
    pass trace-limit-stops
  else
    printf '  expected 1..3 traced events and a stop notice, got %s events\n' "$events" >&2
    fail_scenario trace-limit-stops
  fi
fi

if scenario trace-erlang-module; then
  # E3 end to end: Erlang modules are traceable with the `:mod` syntax.
  run trace-erlang-module "$PROJECT" -- \
    "$BEAM_DEBUG" trace :lists.seq/2 --limit 6 -- mix test test/fast_test.exs
  if [[ "$STATUS" -eq 0 ]] && expect_contains trace-erlang-module 'call :lists\.seq/2'; then
    pass trace-erlang-module
  else
    fail_scenario trace-erlang-module
  fi
fi

if scenario trace-late-module; then
  # 2b: a module defined only inside a test file uses the late-load path and
  # must still be traced, with the fallback announced.
  run trace-late-module "$PROJECT" -- \
    "$BEAM_DEBUG" trace LateHelper.double/1 -- mix test test/late_test.exs
  if [[ "$STATUS" -eq 0 ]] &&
     expect_contains trace-late-module 'watching for a late load' &&
     expect_contains trace-late-module 'call LateHelper\.double/1' &&
     expect_contains trace-late-module 'args: \[150\]'; then
    pass trace-late-module
  else
    printf '  expected late-load notice and traced call (status %s)\n' "$STATUS" >&2
    fail_scenario trace-late-module
  fi
fi

if scenario trace-for-window; then
  # 1c/1d: events generated before the --for cutoff are preserved; events
  # after it are not traced.
  run trace-for-window "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 --for 3500 -- mix test test/window_test.exs
  if [[ "$STATUS" -eq 0 ]] &&
     expect_contains trace-for-window 'args: \[300\]' &&
     expect_contains trace-for-window 'trace window elapsed' &&
     expect_not_contains trace-for-window 'args: \[301\]'; then
    pass trace-for-window
  else
    printf '  expected the pre-cutoff event only (status %s)\n' "$STATUS" >&2
    fail_scenario trace-for-window
  fi
fi

if scenario trace-preserves-failure-status; then
  # 3b: the wrapper must never mask a failing wrapped test.
  run trace-preserves-failure-status "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 -- mix test test/failing_test.exs
  if [[ "$STATUS" -ne 0 ]] &&
     expect_contains trace-preserves-failure-status 'call Demo\.compute/1' &&
     expect_contains trace-preserves-failure-status 'Failed: 1 test|1 test, 1 failure'; then
    pass trace-preserves-failure-status
  else
    printf '  expected nonzero status with trace output (status %s)\n' "$STATUS" >&2
    fail_scenario trace-preserves-failure-status
  fi
fi

if scenario trace-compile-failure-status; then
  # 3b: a compile failure in the wrapped project must exit nonzero.
  printf 'defmodule Broken do\n' > "$PROJECT/lib/broken.ex"
  run trace-compile-failure-status "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 -- mix test test/fast_test.exs
  rm -f "$PROJECT/lib/broken.ex"
  if [[ "$STATUS" -ne 0 ]]; then
    pass trace-compile-failure-status
  else
    printf '  expected nonzero status for a compile failure (status %s)\n' "$STATUS" >&2
    fail_scenario trace-compile-failure-status
  fi
fi

if scenario trace-invalid-task-status; then
  # 3b: a nonexistent wrapped Mix task must exit nonzero.
  run trace-invalid-task-status "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 -- mix nosuchtask
  if [[ "$STATUS" -ne 0 ]]; then
    pass trace-invalid-task-status
  else
    printf '  expected nonzero status for an unknown task (status %s)\n' "$STATUS" >&2
    fail_scenario trace-invalid-task-status
  fi
fi

if scenario trace-refuses-existing-tracer; then
  # 1a/1d: a tracer that existed before the probe (started by mix.exs at
  # project-load time) must not be silently destroyed.
  run trace-refuses-existing-tracer "$CONFLICT" -- \
    "$BEAM_DEBUG" trace Demo2.ping/1 -- mix test test/ping_test.exs
  if [[ "$STATUS" -ne 0 ]] &&
     expect_contains trace-refuses-existing-tracer 'tracer_already_running'; then
    pass trace-refuses-existing-tracer
  else
    printf '  expected refusal without --replace-tracer (status %s)\n' "$STATUS" >&2
    fail_scenario trace-refuses-existing-tracer
  fi
fi

if scenario trace-replace-tracer-flag; then
  # 1a/1d: --replace-tracer authorizes the takeover, and the trace then works.
  run trace-replace-tracer-flag "$CONFLICT" -- \
    "$BEAM_DEBUG" trace Demo2.ping/1 --replace-tracer -- mix test test/ping_test.exs
  if [[ "$STATUS" -eq 0 ]] &&
     expect_contains trace-replace-tracer-flag 'call Demo2\.ping/1' &&
     expect_contains trace-replace-tracer-flag 'args: \[170\]'; then
    pass trace-replace-tracer-flag
  else
    printf '  expected takeover and traced call (status %s)\n' "$STATUS" >&2
    fail_scenario trace-replace-tracer-flag
  fi
fi

if scenario trace-no-compile; then
  # 4a/4c: --no-compile in the wrapped command is respected — the probe must
  # not compile modified sources behind the flag's back.
  (cd "$PROJECT" && MIX_ENV=test mix compile >/dev/null 2>&1)
  printf '\n# stale marker %s\n' "$RANDOM" >> "$PROJECT/lib/demo.ex"
  run trace-no-compile "$PROJECT" -- \
    "$BEAM_DEBUG" trace Demo.compute/1 -- mix test --no-compile test/fast_test.exs
  if [[ "$STATUS" -eq 0 ]] &&
     expect_not_contains trace-no-compile 'Compiling' &&
     expect_contains trace-no-compile 'call Demo\.compute/1'; then
    pass trace-no-compile
  else
    printf '  expected no compilation and a working trace (status %s)\n' "$STATUS" >&2
    fail_scenario trace-no-compile
  fi
fi

if scenario snapshot-does-not-crash-genserver; then
  # A1 end to end: naming an ordinary GenServer must not crash it. The test
  # itself asserts the worker is alive after the watchdog fired.
  run snapshot-does-not-crash-genserver "$PROJECT" -- \
    "$BEAM_DEBUG" snapshot --after 1500 --names Demo.Worker -- mix test test/worker_test.exs
  if [[ "$STATUS" -eq 0 ]] &&
     expect_contains snapshot-does-not-crash-genserver 'demo_state_marker_7519' &&
     expect_contains snapshot-does-not-crash-genserver 'Result: 1 passed|1 test, 0 failures'; then
    pass snapshot-does-not-crash-genserver
  else
    printf '  expected passing test and the state marker (status %s)\n' "$STATUS" >&2
    fail_scenario snapshot-does-not-crash-genserver
  fi
fi

if scenario snapshot-large-mailbox-omitted; then
  # A2 end to end: the report shows the queue length, not the queue.
  run snapshot-large-mailbox-omitted "$PROJECT" -- \
    "$BEAM_DEBUG" snapshot --after 1500 --names mailbox_hog -- mix test test/mailbox_test.exs
  if expect_contains snapshot-large-mailbox-omitted 'mailbox_too_large' &&
     expect_contains snapshot-large-mailbox-omitted '150000'; then
    pass snapshot-large-mailbox-omitted
  else
    fail_scenario snapshot-large-mailbox-omitted
  fi
fi

if scenario snapshot-surfaces-blocked-process; then
  # A5: an unnamed snapshot must surface a blocked process with an empty
  # mailbox — here both the blocked GenServer and the blocked test process.
  run snapshot-surfaces-blocked-process "$PROJECT" -- \
    "$BEAM_DEBUG" snapshot --after 2000 -- mix test test/block_test.exs
  if expect_contains snapshot-surfaces-blocked-process 'Demo\.Blocker' &&
     expect_contains snapshot-surfaces-blocked-process 'wait_forever'; then
    pass snapshot-surfaces-blocked-process
  else
    fail_scenario snapshot-surfaces-blocked-process
  fi
fi

if scenario snapshot-preserves-failure-status; then
  # 3b: the snapshot wrapper must also pass a failing status through.
  run snapshot-preserves-failure-status "$PROJECT" -- \
    "$BEAM_DEBUG" snapshot --after 500 -- mix test test/failing_test.exs
  if [[ "$STATUS" -ne 0 ]] && expect_contains snapshot-preserves-failure-status 'Failed: 1 test|1 test, 1 failure'; then
    pass snapshot-preserves-failure-status
  else
    printf '  expected nonzero status (status %s)\n' "$STATUS" >&2
    fail_scenario snapshot-preserves-failure-status
  fi
fi

if scenario snapshot-explicit-supervisors; then
  # A1: supervisor children are reported only for explicitly named supervisors.
  run snapshot-explicit-supervisors "$PROJECT" -- \
    "$BEAM_DEBUG" snapshot --after 1500 --supervisors Demo.Sup -- mix test test/sup_test.exs
  if [[ "$STATUS" -eq 0 ]] &&
     expect_contains snapshot-explicit-supervisors 'Demo\.Worker' &&
     expect_contains snapshot-explicit-supervisors 'Result: 1 passed|1 test, 0 failures'; then
    pass snapshot-explicit-supervisors
  else
    printf '  expected passing test and a children listing (status %s)\n' "$STATUS" >&2
    fail_scenario snapshot-explicit-supervisors
  fi
fi

# --- result -------------------------------------------------------------------

printf '\n%d scenario groups ran, %d failed\n' "$RAN" "$FAILURES"
if [[ "$FAILURES" -gt 0 ]]; then
  exit 1
fi
printf 'PASS\n'
