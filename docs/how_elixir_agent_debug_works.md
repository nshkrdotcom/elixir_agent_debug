# How `elixir_agent_debug` Works

## The simple explanation

`elixir_agent_debug` gives an AI coding agent a disciplined way to debug Elixir, Erlang, and OTP systems.

Without this package, an agent may read an error, guess at a cause, edit some code, rerun a test, and repeat. That can work for obvious bugs, but it often produces shallow reasoning, speculative fixes, repeated dead ends, or changes that accidentally hide the original problem.

This package teaches and equips the agent to work more like a careful human debugger:

1. Understand the symptom.
2. Consider plausible causes.
3. Decide what evidence would distinguish those causes.
4. Inspect the running system or failing test.
5. Update the theory from the evidence.
6. Make a focused change only when the evidence supports it.
7. Run the narrowest useful verification.
8. Remove any temporary instrumentation it introduced.

The core idea is:

> **Explore broadly, observe efficiently, change deliberately.**

## Is it fully agentic?

For ordinary debugging work, **yes, it is intended to operate without the user directing each step**.

You can normally tell the agent something like:

> Debug this failing Elixir test.

or:

> Find out why this GenServer hangs.

The agent should then choose and run the appropriate debugging workflow itself.

You generally do not need to tell it:

* which theories to consider;
* which source files to inspect;
* when to trace a function;
* when to inspect process state;
* how to preserve a failing test seed;
* when to add a temporary `dbg`;
* how to clean that instrumentation up;
* which narrow regression test to run afterward.

The package provides both the **reasoning process** and the **tools** needed to do those things.

It is not completely autonomous in every possible situation. Human involvement is still appropriate when:

* a tool must be installed or upgraded at the user level;
* the agent needs credentials, production access, or a remote shell;
* an interactive `IEx.pry` session requires a human-operated terminal;
* replacing an existing BEAM tracer could disrupt another debugging session;
* the correct product behavior is ambiguous rather than technically incorrect;
* the proposed fix requires a consequential architectural or business decision.

Those are permission or judgment boundaries, not normal debugging steps.

## What the package actually adds

The system has two main parts.

### 1. A debugging discipline

The `elixir-debug` skill tells the agent how to reason through a problem.

The agent is instructed not to treat the first plausible explanation as the answer. For a non-obvious problem, it should consider multiple credible causes and ask:

> What observation would make one explanation more likely and another less likely?

That distinction matters. A weak debugging check merely confirms what the agent already suspects. A useful check changes the ranking of the possible causes.

For example, suppose a GenServer call times out. Plausible causes might include:

* the GenServer is stuck inside a callback;
* the process crashed and restarted;
* the caller is using the wrong registered name;
* the server is waiting on another process;
* its mailbox is overloaded;
* the test changed timing or supervision behavior.

Instead of immediately rewriting the callback, the agent can inspect the process state, stacktrace, mailbox length, supervisor relationship, and call flow. The result tells it which theory is actually supported.

### 2. Practical debugging tools

The `beam-debug` command gives the agent ways to inspect a running BEAM system without first editing the application.

The main tools are:

* **Call tracing** for function arguments, returns, and exceptions.
* **Timed snapshots** of process state, stacktraces, mailboxes, memory, links, monitors, and supervisors.
* **Normal test execution** that does not silently serialize concurrent tests.
* **Interactive IEx support** when a real terminal is available.
* **Temporary marker ownership** when inline `dbg`, `IO.inspect`, or logging is genuinely the fastest option.
* **An optional evidence journal** for long investigations.

These tools live outside the application and do not become project dependencies.

## What happens during a typical debugging task

A normal agentic debugging session should look roughly like this.

### Step 1: Read the existing evidence

The agent first reads:

* the complete error;
* the stacktrace;
* the failing test;
* the relevant source;
* recent changes, when relevant.

Many failures are already localized at this point. A compile error or an explicit pattern-match failure may not require a large investigation.

The system does not force ceremony when the defect is obvious.

### Step 2: Form and rank plausible explanations

For a genuinely unclear problem, the agent identifies several defensible possibilities.

It does not need to write a large formal report before acting, but its investigation should reflect more than one possible story.

For example:

* wrong input entered the function;
* correct input was transformed incorrectly;
* the function was never called;
* the call occurred in a different process;
* state changed earlier than expected;
* a race made the behavior order-dependent.

### Step 3: Choose discriminating evidence

The agent asks what observation would separate those explanations.

Examples:

* Trace the function to see whether it is called and with which arguments.
* Capture a process snapshot while the test is hanging.
* Inspect GenServer state before and after a message.
* Preserve and replay the exact ExUnit seed.
* Compare normal concurrency with deliberate serialization.
* Inspect the supervisor tree after a crash.
* Measure reductions, memory, or mailbox growth.
* Use `mix xref` to determine who calls or compile-depends on a module.

### Step 4: Observe the actual system

The agent runs the cheapest useful observation.

It should prefer observation that does not edit source.

For example:

```bash
beam-debug trace MyApp.Worker.handle_call/3 -- mix test test/worker_test.exs:42
```

This can show:

* whether the callback ran;
* the message it received;
* the caller information;
* the previous state;
* the returned reply and new state;
* any exception raised.

For a hang:

```bash
beam-debug snapshot --after 2000 --names MyApp.Worker -- mix test test/hang_test.exs:42
```

This can show:

* the current stacktrace;
* whether the process is alive;
* whether it is waiting or running;
* its state, when it can answer;
* mailbox length and a bounded sample;
* links, monitors, and memory;
* blocked processes elsewhere in the system.

### Step 5: Update the theory

The agent should explicitly change its understanding based on what it observed.

For example:

> The trace proves the request reaches `handle_call/3` with the expected payload. The incorrect value already exists in the GenServer state, so the request parsing theory is ruled out. The investigation should move to the earlier state update.

This is the important part of the system. Tools alone do not create rigorous debugging. The agent must use the output to eliminate, confirm, or revise explanations.

### Step 6: Make a focused change

Once the evidence supports a cause, the agent makes the smallest appropriate correction.

It should avoid combining several unrelated speculative fixes into one patch.

A good change should have a clear relationship to the evidence:

> The snapshot showed the worker permanently blocked in `GenServer.call/3` while holding the only process capable of replying. The change removes that circular synchronous call.

### Step 7: Verify narrowly

The agent first runs the smallest test that can prove the correction.

It should not automatically run the entire suite after every small observation or edit.

Broader tests are appropriate when the change has broader risk, but they are not a substitute for a focused regression test.

### Step 8: Report what was and was not proven

The final response should distinguish:

* evidence actually observed;
* theories ruled out;
* the supported cause;
* code changed because of that evidence;
* tests actually run;
* anything still unverified.

That prevents a plausible narrative from being presented as a confirmed diagnosis.

## Debugging workflows the system supports

### Deterministic test failure

For an ordinary repeatable failure, the agent usually:

1. Reads the full exception and stacktrace.
2. Reads the failing test and implementation.
3. Determines whether the problem is already localized.
4. Traces a specific function if runtime values are unclear.
5. Fixes the supported defect.
6. Runs the focused test.

Example:

```bash
beam-debug trace MyApp.Parser.normalize/1 -- mix test test/parser_test.exs:84
```

### Wrong data or unexpected control flow

The agent can trace a function and observe:

* calls;
* arguments;
* return values;
* exceptions;
* local as well as exported functions.

This is useful when the code looks correct statically but the runtime values are not what the agent expects.

### GenServer or Agent state problems

The agent can capture a named process during the failing run:

```bash
beam-debug snapshot \
  --after 1500 \
  --names MyApp.Worker \
  -- mix test test/worker_test.exs:42
```

This can expose:

* unexpected state;
* a busy callback;
* a system-message timeout;
* an overloaded mailbox;
* a dead process;
* the wrong registered process;
* links or monitors that explain lifecycle behavior.

### Hangs and deadlocks

A timed snapshot can inspect the system while it is still stuck.

The report looks beyond busy mailboxes. Deadlocked processes often have empty mailboxes, so the tool also searches for waiting processes executing application or dependency code.

This helps reveal situations such as:

* two GenServers synchronously waiting on one another;
* a process blocked in a receive that can never match;
* a test waiting on a task that is waiting on the test process;
* a process stuck in file, network, or database work;
* a supervisor child blocked during startup.

### Crashes and supervision behavior

The agent should combine:

* the crash report;
* process state when available;
* supervisor children;
* restart behavior;
* the callback source implicated by the report.

The system discourages blindly changing supervisor strategy before proving why the process failed or restarted.

### Flaky and order-dependent tests

The agent should preserve the failing ExUnit seed and reproduce the original conditions before narrowing anything.

Typical flow:

```bash
mix test --seed <failing-seed>
mix test --seed <failing-seed> --repeat-until-failure 50
```

It should preserve:

* original test scope;
* concurrency;
* tags;
* environment;
* database behavior;
* relevant external processes.

It should not immediately reduce the run to one file if doing so could remove the interaction that causes the failure.

It should also avoid `--trace` during concurrency investigations because ExUnit’s trace mode serializes test cases and may hide the bug.

### Performance problems

The skill can guide the agent through:

* `mix test --slowest`;
* `mix profile.eprof`;
* `mix profile.cprof`;
* `mix profile.fprof`;
* reduction deltas;
* process memory;
* mailbox growth;
* binary memory;
* scheduler activity.

The agent should first identify where time or memory is actually spent, rather than optimizing whichever code looks expensive.

### Structural and dependency questions

The workflow includes built-in tools such as:

```bash
mix xref callers MyApp.SomeModule
mix xref graph --label compile
```

These help answer:

* who calls this module;
* why changing this file recompiles many others;
* whether an unexpected dependency exists;
* whether a behavior is generated by macros or compile-time code.

### Macro-generated behavior

When source behavior comes from macros, the agent can inspect expansion rather than reasoning only from the original source:

```elixir
expanded = Macro.expand_once(quoted, __ENV__)
Macro.to_string(expanded) |> IO.puts()
```

### Temporary inline instrumentation

Sometimes a temporary `dbg`, `IO.inspect`, or log statement is still the fastest way to inspect one localized pipeline.

The system allows this, but makes it accountable.

Before adding a temporary line, the agent runs:

```bash
beam-debug begin
```

It receives a unique token and marks every temporary line with it:

```elixir
result = normalize(input)
IO.inspect(result, label: "normalized") # BEAMDBG:ab12cd34
```

When finished, it runs:

```bash
beam-debug end ab12cd34
```

The command verifies that the agent’s own instrumentation is gone, including markers accidentally committed during the investigation.

If the optional Stop hook is installed, it checks the same session-owned token when the agent finishes. It does not scan the repository indiscriminately, touch another agent’s markers, or edit files itself.

## What the optional Stop hook adds

The Stop hook is a cleanup reminder, not the debugging engine.

It activates only when the current agent session explicitly ran `beam-debug begin`.

When that session tries to finish:

* no owned temporary markers remain: nothing happens;
* owned markers remain: the hook lists their exact locations and asks once for cleanup;
* another agent owns markers: they are ignored;
* the session never used inline instrumentation: the hook is inert;
* hook metadata or internal processing fails: the session is allowed to stop;
* the hook has already asked once: it does not create a loop;
* the hook never edits source code.

The result is automatic protection against forgotten temporary probes without turning the hook into a global repository police mechanism.

## What the evidence journal is for

Long debugging sessions can lose track of what has already been tested, especially after conversation compaction or handoff.

The optional journal lets the agent record hypotheses:

```bash
beam-debug note \
  "cache TTL is interpreted as milliseconds" \
  --status confirmed \
  --evidence "trace shows 30 passed where 30000 is expected"
```

Statuses are:

* `open`;
* `confirmed`;
* `killed`.

The journal can later show which explanations remain plausible and which were already disproved.

It is useful for difficult investigations, but it is not required for every small bug.

## What this system does not do

It does not:

* autonomously install or upgrade user-level tooling;
* add dependencies to the project;
* run a background debugging daemon;
* rewrite source automatically;
* guarantee that every bug can be diagnosed without judgment;
* replace application-specific observability;
* safely attach to production systems without appropriate access and care;
* make tracing free of timing or performance effects;
* determine product intent when the desired behavior is ambiguous.

It gives the agent a rigorous process and a practical observation toolkit. It does not remove the need for engineering judgment.

## What the human experience should be

In the common case, the user experience is intentionally simple:

1. Ask the agent to debug a problem.
2. Let the agent investigate.
3. Review the diagnosis, change, and verification.

You should expect the agent to explain:

* what it initially considered;
* what it inspected;
* what the runtime evidence showed;
* which explanations were eliminated;
* why the final change follows from the evidence;
* which tests were run.

You should not have to manually coach it through basic debugging discipline such as:

> Form a theory, inspect the state, compare the evidence, revise the theory, and only then change the code.

That discipline is the main reason this package exists.

## The practical value

The package is not primarily valuable because it adds a trace command or a snapshot command. Those are supporting mechanisms.

Its main value is that it changes the agent’s default debugging behavior from:

> Guess, edit, and rerun.

to:

> Form plausible explanations, collect discriminating evidence, update the explanation, make a supported change, and verify it.

That is ordinary debugging discipline, but agents do not always apply it reliably without explicit structure.

`elixir_agent_debug` makes that structure part of the environment.
