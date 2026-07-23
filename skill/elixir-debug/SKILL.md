---
name: elixir-debug
description: Evidence-first debugging for Elixir, Erlang, OTP, ExUnit, GenServer, supervision, process state, message flow, races, hangs, memory, performance, macros, and failing BEAM tests. Use when diagnosing unexpected behavior or test failures in an Elixir/Erlang repository.
---

# Elixir/OTP evidence-first debugging

**Explore broadly, observe efficiently, change deliberately.**

Constrain mutation and unsupported conclusions, not diagnostic breadth. Match
breadth to uncertainty: an ambiguous failure deserves several ranked candidate
causes; a failure that is already localized deserves a fix, not a ritual.

## The loop

1. For a non-obvious failure, consider multiple plausible causes and rank them
   loosely. Committing to the first plausible story is the most common way a
   debugging session goes wrong. Skip formal enumeration when the failure is
   already localized — the exception names the defect, a compile error has one
   obvious cause, a regression test pinpoints the malformed condition.
2. Identify what evidence *discriminates* between the candidates — the
   observation whose outcome changes the ranking, not one that merely confirms
   the favourite.
3. Collect that evidence efficiently. Batch checks when they are independent,
   bounded, and unlikely to perturb the behavior being measured; otherwise
   sequence them deliberately. Read-only is not the same as non-perturbing:
   tracing shifts timing, profiling slows execution, stacktrace sweeps consume
   scheduler time, `:sys` messages interact with the target process, and
   concurrent test commands contend for the database, build directory and
   ports. This matters most for races, where wide observation can make the
   failure disappear.
4. Update the ranking from what was observed, including values that contradict
   the favoured theory.
5. Converge on a sufficiently supported causal explanation — which may involve
   multiple interacting causes, not always a single root cause.

Breadth is an escalation tool, not a standing policy. When a failure is
genuinely gnarly — it survived a plausible fix, reproduces only sometimes,
spans several processes, or the evidence keeps contradicting the current
story — go wide deliberately: enumerate every plausible cause you can defend,
including interactions between them, and design observation runs that
discriminate among many candidates at once. The point of the wide phase is
grounding: do not settle on a root cause until the strongest available causal
evidence supports it — a direct observation when one is obtainable;
converging observations, controlled perturbations and a regression test when
it is not. Elimination of the alternatives you happened to list is not, by
itself, grounding.

What "change deliberately" means for edits:

- an unsupported production fix: avoid;
- a small, reversible, clearly labeled diagnostic experiment: allowed — a tiny
  change behind an existing test is sometimes the cheapest discriminating
  evidence, cheaper than building trace infrastructure around it;
- an evidence-supported correction: proceed;
- several unrelated guessed fixes in one patch: never.

Keep every verification cycle causally interpretable: after the run, you must
be able to say which change produced which change in behaviour.

Keep the reproducer as narrow as possible *without changing the conditions
required to reproduce the failure* — shrinking a concurrency failure to one
file or one process can remove the bug — and keep the *observation* wide.
Narrowing the reproducer is cheap; narrowing what you look at during the run
is how theories survive that should have died.

## Start from the symptom

The table is advisory, not a routing law: pick the cheapest evidence that
discriminates in your specific case. The exception, the failing test and the
source are often already enough — read them first.

| Symptom | Useful observations |
|---|---|
| Deterministic test failure | The full exception and stacktrace; if values are needed, `beam-debug trace <Mod.fun/arity> -- mix test <file>:<line>` for args and return values |
| Flaky / order-dependent | Preserve the failing seed, then `mix test --seed <that seed> --repeat-until-failure 50` |
| Hangs or times out | `beam-debug snapshot --after <ms> -- mix test <file>:<line>` — stacktraces and the blocked-process census show where it is stuck |
| Crashes and restarts | The crash report and the supervisor's state; the callback source once the report points at it |
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
nothing, so there is nothing to clean up and nothing to leave behind. It is
not free, though — tracing and snapshots have runtime cost and can shift
timing; account for that when the symptom is itself timing-sensitive.

```bash
beam-debug trace MyApp.Worker.handle_call/3 -- mix test test/worker_test.exs:42
beam-debug trace :gen_server.call/3 --limit 20 -- mix test test/worker_test.exs
beam-debug trace MyApp.Worker --limit 50 --for 2000 -- mix test test/worker_test.exs
```

`trace` installs a bounded call trace from a probe outside the repository and
reports arguments, return values and exceptions, for local as well as exported
functions, including code you cannot edit. Erlang modules use the `:mod`,
`:mod.fun`, `:mod.fun/arity` form. For modules compiled before the wrapped
task, installation is synchronous — compile, verify the module is loaded and
the pattern matched, only then run the command — so a fast first call cannot
be missed. Modules that only come into existence while the wrapped task runs
(for example, defined inside a test file) get best-effort late-load
attachment, announced up front; either way a target that never loads or
matches nothing fails the run with an explicit diagnostic instead of printing
nothing. Tracing stops at exactly `--limit` events (default 200) and after
`--for` milliseconds if given.

The wrapped command is `mix test` or another Mix task that tolerates being
precompiled first; an explicit `--no-compile` in the wrapped command is
respected. A tracer that existed before the probe is never replaced silently —
the run fails unless you pass `--replace-tracer`.

Its cost is real: keep the target specific. `Mod` with no function traces every
function in the module and will flood a busy run. Prefer `Mod.fun/arity`.

For a hang, a deadlock, or a slow test:

```bash
beam-debug snapshot --after 5000 --names MyApp.Worker,MyApp.Cache -- mix test test/slow_test.exs
beam-debug snapshot --after 5000 --supervisors MyApp.Supervisor -- mix test test/slow_test.exs
```

The watchdog fires at a wall-clock time you choose — measured from the start
of the wrapped task, after compilation — while the system is still running.
Timing is explicit on purpose: ExUnit tears down supervised processes as soon
as a test finishes, so anything that captures *after* the failure finds
nothing left to inspect.

The report contains: full snapshots of the `--names` targets (state, mailbox
sample, stacktrace, links, monitors), children of the `--supervisors` targets,
the busiest mailboxes, the busiest processes by reductions, the largest by
memory, and a census of blocked processes in non-runtime code — waiting,
empty mailbox, executing anything outside the Erlang/Elixir installation
(project or deps) — because a deadlocked process usually has an *empty*
mailbox and would be invisible in a mailbox ranking. The census runs only on
nodes with at most 400 processes (a large Phoenix or distributed node can
exceed that, at which point pass `--names` with your suspects) and prints at
most 20 stack groups, reporting how many it omitted.

Only `--names` targets receive `:sys` system messages and only
`--supervisors` targets are asked for children: either protocol aimed at a
process that does not implement it is slow, noisy, or crashes the callee.
A mailbox observed above 100 messages is reported by length instead of
sampled, because `Process.info(pid, :messages)` copies the entire mailbox
(the queue can still grow between the length check and a sample — nothing in
`Process.info` is atomic across calls).

Inside an IEx session the same observations are available directly:

```elixir
BeamDebug.snapshot(MyApp.Worker)
BeamDebug.stacktraces()          # busiest mailboxes; stacks fetched only for those
BeamDebug.state(MyApp.Worker)
BeamDebug.messages(MyApp.Worker)
BeamDebug.supervisor_children(MyApp.Supervisor)
BeamDebug.trace_calls({MyApp.Worker, :handle_call, 3}, limit: 50)
BeamDebug.stop_calls()
```

`trace_calls` is built on `:erlang.trace/3` and `:erlang.trace_pattern/3`; the
other observations use `:sys.get_state/2`, `:sys.get_status/2` and
`Process.info/2`. Note that `:sys.*` only works on OTP behaviours. An existing
tracer is never replaced silently — pass `replace: true` to take tracing over.

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
2. Re-run the **exact original command and scope** with that seed — same
   files, tags, env and concurrency: `mix test --seed <seed>`. Selecting a
   single file is already narrowing, and can erase a failure that depends on
   another test file, suite order, shared database state or concurrent async
   cases.
3. Confirm it reproduces under those same conditions:
   `mix test --seed <seed> --repeat-until-failure 50`.
4. Only then reduce — files, tags, processes, concurrency — one variable at a
   time, re-checking that the failure survives each reduction.

Do not start with `--seed 0`. It disables order randomization and will often
erase the very order dependency being investigated.

Do not use `--trace` while investigating a concurrency failure. It sets
`--max-cases 1`, which serializes the suite and can hide the interleaving that
produces the bug. `beam-debug test` is a plain `mix test` passthrough for this
reason; `--trace` appears only in `beam-debug pry-test`, where disabling test
timeouts is the point.

Comparing normal concurrency against controlled serialization is a legitimate
*experiment*, but read it precisely: a failure that disappears under
`--max-cases 1` implicates cross-test concurrency; a failure that survives it
may still be an interleaving bug *inside* one test or among application
processes — serialization only removes concurrency between ExUnit cases.

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

## Optional: the evidence journal

`beam-debug note` / `history` / `report` keep a small per-repository JSONL
record of hypotheses and what the evidence did to them. It is optional — use
it for long sessions, complex investigations, or when context compaction may
lose what was already ruled out. Ordinary short debugging does not need a note
per dead theory.

```bash
beam-debug note "cache TTL off by 1000x" --status confirmed --evidence "trace shows ms vs s"
beam-debug history
beam-debug report      # hypothesis summary grouped by status
```

`report` is a hypothesis summary, not a finished write-up: it groups the notes
by confirmed / killed / open.

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

In the final write-up, distinguish explicitly:

- evidence observed;
- hypotheses ruled out, and by what evidence;
- code changed because of that evidence;
- tests actually run;
- anything not verified.
