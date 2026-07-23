---
name: elixir-debug
description: Evidence-first debugging for Elixir, Erlang, OTP, ExUnit, GenServer, supervision, process state, message flow, races, hangs, memory, performance, macros, and failing BEAM tests. Use when diagnosing unexpected behavior or test failures in an Elixir/Erlang repository.
---

# Elixir/OTP evidence-first debugging

Constrain mutation and unsupported conclusions, not diagnostic breadth.

## The loop

**Generate broadly. Test efficiently. Edit cautiously.**

1. Form a *ranked set* of hypotheses, not one. Five to fifteen is normal for a
   non-obvious failure. Committing to the first plausible story is the most
   common way a debugging session goes wrong.
2. Identify what evidence *discriminates* between them — the observation whose
   outcome changes the ranking, not one that merely confirms the favourite.
3. Collect that evidence in as few runs as possible. Independent read-only
   checks should be batched into one pass, not serialized across turns. One run
   that captures the exception, the process state, the mailbox, the stacktraces
   and the failing seed can eliminate eight hypotheses at once.
4. Update the ranking from what was observed, including values that contradict
   the favoured theory. Record what died: `beam-debug note "..." --status killed`.
5. Repeat until one hypothesis is supported by direct evidence.
6. Only then edit.

What stays strictly disciplined is **mutation**:

- Many hypotheses at once: good.
- Many read-only checks at once: good.
- Many instrumentation points in one run: usually good.
- Unrelated speculative fixes combined in one patch: not acceptable.
- Multiple changes whose individual effects cannot be separated: not acceptable.

Multiple edits are fine when they implement one evidence-supported causal
correction, or when each is independently verifiable. Keep every verification
cycle causally interpretable: after the run, you must be able to say which
change produced which change in behaviour.

Keep the reproducer narrow — one test file, one line, one process, one message
path — but keep the *observation* wide. Narrowing the reproducer is cheap;
narrowing what you look at during the run is how theories survive that should
have died.

## Start from the symptom

Pick the row that matches what was actually observed. Do not route every problem
through inline instrumentation.

| Symptom | First move |
|---|---|
| Deterministic test failure | Read the full exception and stacktrace, then `beam-debug trace <Mod.fun/arity> -- mix test <file>:<line>` for args and return values |
| Flaky / order-dependent | Preserve the failing seed, then `mix test --seed <that seed> --repeat-until-failure 50` |
| Hangs or times out | `beam-debug snapshot --after <ms> -- mix test <file>:<line>` — current stacktraces show where it is blocked |
| Crashes and restarts | The crash report and the supervisor's state, not the callback source |
| Wrong GenServer/Agent state | `beam-debug snapshot --names MyApp.Worker -- mix test <file>:<line>`, or `:sys.get_state` at a chosen point |
| Mailbox growth / stuck consumer | `message_queue_len` and mailbox sample from the same snapshot |
| Slow | `mix test --slowest 10`, then `mix profile.eprof` / `mix profile.cprof` |
| Memory grows | `:erlang.memory/1` deltas, per-process `:memory`, binary refc |
| Regression with a known-good commit | `git bisect run mix test <file>:<line>` |
| "Who calls this" / compile coupling | `mix xref callers`, `mix xref graph --label compile` |
| Macro-generated behaviour | `Macro.expand_once/2` then `Macro.to_string/1` |
| Localized data-flow error you can already point at | One temporary inline `dbg()` — see below |

## Observe without editing source

Prefer this when the target is a function, a process, or a hang. It edits
nothing, so there is nothing to clean up and nothing to leave behind.

```bash
beam-debug trace MyApp.Worker.handle_call/3 -- mix test test/worker_test.exs:42
beam-debug trace MyApp.Worker --limit 50 --for 2000 -- mix test test/worker_test.exs
```

`trace` installs a bounded `:dbg` call trace from a probe file outside the
repository. It reports arguments, return values and exceptions, for local as
well as exported functions, including code you cannot edit. It stops itself
after `--limit` events (default 200) and after `--for` milliseconds if given.

Its cost is real: keep the target specific. `Mod` with no function traces every
function in the module and will flood a busy run. Prefer `Mod.fun/arity`.

For a hang, a deadlock, or a slow test:

```bash
beam-debug snapshot --after 5000 --names MyApp.Worker,MyApp.Cache -- mix test test/slow_test.exs
```

The watchdog fires at a wall-clock time you choose, while the system is still
running, and dumps state, mailbox sample, current stacktrace, links, monitors
and supervisor children for the named processes plus the busiest ones on the
node. Timing is explicit on purpose: ExUnit tears down supervised processes as
soon as a test finishes, so anything that captures *after* the failure finds
nothing left to inspect.

Inside an IEx session the same observations are available directly:

```elixir
BeamDebug.snapshot(MyApp.Worker)
BeamDebug.stacktraces()          # every process, busiest mailbox first
BeamDebug.state(MyApp.Worker)
BeamDebug.messages(MyApp.Worker)
BeamDebug.trace_calls({MyApp.Worker, :handle_call, 3}, limit: 50)
BeamDebug.stop_calls()
```

The underlying built-ins are `:dbg`, `:sys.get_state/2`, `:sys.get_status/2`,
`:sys.trace/2,3` and `Process.info/2`. Note that `:sys.*` only works on OTP
behaviours; `:dbg` works on anything.

## Inline instrumentation: a real fallback, not the default

A temporary `dbg/1`, `IO.inspect/2` or `Logger.debug/2` is still the fastest
check for an already-localized data-flow error — when you know the function, the
values are in one pipeline, and constructing a correct trace would take longer
than reading the output. Use it there without apology.

Every temporary source line must contain the literal marker `# BEAMDBG`:

```elixir
input
|> normalize()
|> dbg() # BEAMDBG
|> persist()
```

Remove the marked lines as soon as they confirm or kill the hypothesis. Do not
leave instrumentation "for later." Adding several probes in one run is fine —
that is one experiment with a wide aperture, not several speculative changes.

Use `beam-debug capture -- <command>` when preserving the output as a log helps.
Do not pipe an interactive pry session through capture.

## Flaky and order-dependent failures

Reproduce reliably *before* forming a fix. The order matters:

1. Capture the seed ExUnit printed for the failing run.
2. Re-run with exactly that seed: `mix test --seed <seed> <file>`.
3. Confirm it is reproducible: `mix test --seed <seed> --repeat-until-failure 50`.
4. Only then narrow.

Do not start with `--seed 0`. It disables order randomization and will often
erase the very order dependency being investigated.

Do not use `--trace` while investigating a concurrency failure. It sets
`--max-cases 1`, which serializes the suite and can hide the interleaving that
produces the bug. `beam-debug test` is a plain `mix test` passthrough for this
reason; `--trace` appears only in `beam-debug pry-test`, where disabling test
timeouts is the point.

Comparing normal concurrency against controlled serialization is a legitimate
*experiment* — a failure that survives `--max-cases 1` is not an interleaving
bug. Just do not make serialization the default.

## Interactive escalation

`beam-debug pry-test` runs `iex -S mix test --trace` with the helpers preloaded,
for a `require IEx; IEx.pry() # BEAMDBG` breakpoint. `--trace` is deliberate
there: it sets test timeouts to `:infinity`, which is what makes `pry` usable.

This path needs a real terminal. It is not reliably drivable from a
non-interactive tool call, so treat it as human-assisted: prefer `trace` and
`snapshot` when working without a usable TTY, and ask the user to run the pry
session when one is genuinely needed.

`IEx.break!/2,4` sets a breakpoint on a function without editing source and is
usually preferable to inserting a `pry` call.

## Optional tools, not baseline requirements

Use `recon`, `observer_cli`, Sourceror or StreamData when they are already
available and fit the confirmed problem:

- `recon` for rate-limited call tracing on a busy live node;
- `observer_cli` for process/supervision/mailbox resource questions;
- Sourceror when source-level AST insertion/removal is truly warranted;
- StreamData after one example confirms the theory and a property needs broad
  validation.

Do not add one of these dependencies merely to avoid a built-in check. The OTP
profilers (`mix profile.eprof`, `mix profile.cprof`, `mix profile.fprof`) and
`:erlang.system_monitor` need no dependency at all.

## Before completing

```bash
beam-debug assert-clean
git diff --check
```

Then run the narrowest relevant regression test. If the failure was flaky, re-run
with the recorded seed and `--repeat-until-failure`. Run broader tests only when
scope and risk justify it.

`beam-debug report` turns the journal into the skeleton of the final write-up.
Distinguish, explicitly:

- evidence observed;
- hypotheses ruled out, and by what evidence;
- code changed because of that evidence;
- tests actually run;
- anything not verified.
