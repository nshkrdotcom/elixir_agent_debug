---
name: elixir-debug
description: Evidence-first debugging for Elixir, Erlang, OTP, ExUnit, GenServer, supervision, process state, message flow, races, macros, and failing BEAM tests. Use when diagnosing unexpected behavior or test failures in an Elixir/Erlang repository.
---

# Elixir/OTP evidence-first debugging

Use a tight theory -> check -> observe -> revise loop. Do not construct a chain
of speculative edits when the running system can answer the question cheaply.

## Non-negotiable loop

1. State one theory in one line and the exact observation expected if it is true.
2. Choose the cheapest empirical check that can confirm or kill it.
3. Run that check before writing a fix.
4. Read the actual output, including values that contradict the theory.
5. Confirm, revise, or escalate one tier.
6. Make at most one theorized code change before the next empirical check.
7. Remove temporary instrumentation before completing the turn.

Keep the reproducer narrow: one test file, one line, one process, one function,
or one message path. Do not repeatedly run a broad suite while the failure is
still localizable.

## Default fast path: temporary inline evidence

For an ordinary code-path or failing-test question, prefer a temporary inline
`dbg/1`, `IO.inspect/2`, or `Logger.debug/2` when it is the fastest way to put
observed values in the same command output the agent is already reading.

Every temporary source line must contain the literal marker `# BEAMDBG`:

```elixir
value = step(input)
IO.inspect(value, label: "BEAMDBG step result") # BEAMDBG
```

For pipelines, prefer `dbg()` because it shows each stage:

```elixir
input
|> normalize()
|> dbg() # BEAMDBG
|> persist()
```

Run the narrowest command immediately. Inspect its output before another edit.
Remove the marked line as soon as it confirms or kills the theory. Do not leave
instrumentation “for later” or “just in case.”

Use normal commands directly when inline output is sufficient. Use
`beam-debug capture -- <command>` only when preserving a log helps. Do not pipe
an interactive pry session through capture.

## Escalate when the theory is about live OTP state

Do not infer GenServer/Agent state, mailbox contents, or supervision behavior
from surrounding code when the process is available.

Use a pry point when the failing test already reaches the relevant process:

```elixir
require IEx; IEx.pry() # BEAMDBG
```

Run it with:

```bash
beam-debug itest path/to/test.exs:LINE
```

Inside IEx, prefer direct observations:

```elixir
BeamDebug.state(ServerName)
BeamDebug.status(ServerName)
BeamDebug.info(ServerName)
BeamDebug.messages(ServerName)
BeamDebug.trace(ServerName, 3_000)
```

The underlying built-ins are `:sys.get_state/1,2`, `:sys.get_status/1,2`,
`:sys.trace/2,3`, and `Process.info/1,2`.

Use `:sys.trace` for one process and a short bounded window. Always turn it off.
The helper's bounded form does that in an `after` block.

For an already-running named node, attaching a second IEx shell can be useful,
but do not build distributed-node setup merely to inspect a short unit test.
A pry point is usually cheaper for tests.

## Escalate when the theory is structural

Before editing based on “who calls this” or compile coupling, use actual xref
output:

```bash
mix xref callers MyApp.Module
mix xref graph --label compile
```

For macro-generated behavior, inspect expansion rather than reasoning only from
the macro definition:

```elixir
expanded = Macro.expand_once(quoted_ast, __ENV__)
Macro.to_string(expanded) |> IO.puts()
```

## Optional tools, not baseline requirements

Use `recon`, `observer_cli`, Sourceror, or StreamData when they are already
available and fit the confirmed problem:

- `recon` for bounded call tracing on the same live node;
- `observer_cli` for process/supervision/mailbox resource questions;
- Sourceror when source-level AST insertion/removal is truly warranted;
- StreamData after one example confirms the theory and a property needs broad
  validation.

Do not add one of these dependencies merely to avoid a simple inline check.
Do not create a separate Mix invocation and expect it to trace another node.

## Before completing

Run:

```bash
beam-debug assert-clean
git diff --check
```

Then run the narrowest relevant regression test. Run broader tests only when
scope and risk justify them.

In the final report, distinguish:

- evidence observed;
- code changed because of that evidence;
- tests actually run;
- anything not verified.
