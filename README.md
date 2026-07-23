<p align="center">
  <img src="assets/elixir_agent_debug.svg" width="200" height="200" alt="elixir_agent_debug logo" />
</p>

<p align="center">
  <a href="https://github.com/nshkrdotcom/elixir_agent_debug"><img src="https://img.shields.io/badge/GitHub-nshkrdotcom%2Felixir__agent__debug-181717?style=flat&logo=github" alt="GitHub Repo" /></a>
  <a href="https://opensource.org/licenses/MIT"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=flat" alt="License: MIT" /></a>
</p>

# elixir_agent_debug

A deliberately small, user-level debugging layer for **Claude Code CLI** and
**Codex CLI** on Ubuntu.

It gives both agents the same evidence-first Elixir/OTP workflow without an MCP
server, daemon, custom agent tree, or required Hex dependency.

The rule it encodes is **explore broadly, observe efficiently, change
deliberately**:

- Match diagnostic breadth to uncertainty: rank several plausible causes when
  the failure is ambiguous, skip the ritual when it is already localized, and
  escalate to a deliberately wide sweep — many defensible hypotheses, one
  observation run that discriminates among them — when the failure is
  genuinely gnarly and grounding on the real cause is the hard part.
- Batch observations when they are independent, bounded and unlikely to
  perturb the behavior being measured — and account for the fact that tracing
  and profiling are not free just because they are read-only.
- For edits: an unsupported production fix is avoided; a small, reversible,
  clearly labeled diagnostic experiment is allowed; an evidence-supported
  correction proceeds; several unrelated guessed fixes in one patch — never.

The discipline binds **mutation**, not diagnostic breadth. Symptom guidance —
deterministic failure, flaky, hangs, crashes and restarts, wrong state,
mailbox growth, slow, memory growth, regression, structural, macro — is
advisory: the agent picks the cheapest discriminating evidence, not a fixed
tool order.

## What gets installed

Common:

- one shared Agent Skill: `elixir-debug`
- one small command: `beam-debug`
- one helper module, loaded only when requested, for live process observation
- two probe files that instrument a run **without editing the repository**
- one deterministic scanner for temporary `# BEAMDBG` markers
- one per-repository evidence journal

Claude-specific:

- the skill is copied to `~/.claude/skills/elixir-debug/`
- a short managed block is added to `~/.claude/CLAUDE.md`

Codex-specific:

- the same skill is copied to `~/.agents/skills/elixir-debug/`
- a short managed block is added to `~/.codex/AGENTS.md`

Optional:

- `./install.sh --hooks` adds the same lightweight `Stop` cleanup guard to
  `~/.claude/settings.json` and `~/.codex/hooks.json`
- the guard asks the agent once to remove newly-added `# BEAMDBG` lines before
  stopping; it deliberately does not create an infinite stop loop

## Install

From the packet:

```bash
unzip elixir-agent-debug-v1.zip
cd elixir-agent-debug-v1
./install.sh --hooks
```

From a Git checkout:

```bash
git clone <this-repo-url> elixir-agent-debug
cd elixir-agent-debug
./install.sh --hooks
```

`--hooks` is the recommended install: it adds the one-shot cleanup guard. Omit
it for an instruction-and-tools-only install that never edits either client's
hook configuration.

Install for only one client:

```bash
./install.sh --claude-only --hooks
./install.sh --codex-only --hooks
```

The installer is idempotent and only owns files or marked sections created by
this package. It refuses to overwrite an unrelated skill or executable with the
same name.

After installation, start a **new CLI session**. Claude can also notice skill
changes live when its personal skills directory already existed, but a new
session is the least surprising verification path.

For Codex hooks, open `/hooks` once and trust the installed hook definition.
Codex intentionally requires review of non-managed command hooks.

## Use

Usually, just ask the agent to debug. The global instruction tells it to load
`elixir-debug` when the task is an Elixir/Erlang debugging task.

You can invoke the skill explicitly:

```text
Claude Code: /elixir-debug
Codex CLI:   $elixir-debug
```

Useful commands:

```bash
beam-debug doctor
beam-debug test test/path_test.exs:42
beam-debug trace MyApp.Worker.handle_call/3 -- mix test test/path_test.exs:42
beam-debug snapshot --after 5000 --names MyApp.Worker -- mix test test/slow_test.exs
beam-debug pry-test test/path_test.exs:42
beam-debug note "worker never receives :tick" --status killed --evidence "trace shows 3 calls"
beam-debug history
beam-debug report
beam-debug iex
beam-debug capture -- mix test test/path_test.exs:42
beam-debug latest
beam-debug scan
beam-debug assert-clean
```

### Observe without editing the repository

`beam-debug trace` installs a bounded call trace from a probe that lives
outside your project. It reports arguments, return values and exceptions for
local as well as exported functions — including code you cannot edit — and
nothing needs cleaning up afterwards:

```bash
beam-debug trace MyApp.Worker.handle_call/3 -- mix test test/worker_test.exs:42
beam-debug trace :gen_server.call/3 --limit 20 -- mix test test/worker_test.exs:42
```

```text
[BEAMDBG] tracing MyApp.Worker.handle_call/3 limit=200 for=0ms matched=1
[BEAMDBG] 16:26:22 #PID<0.144.0> call MyApp.Worker.handle_call/3
           args: [{:bump, 7}, {#PID<0.104.0>, [...]}, %{ticks: 0}]
[BEAMDBG] 16:26:22 #PID<0.144.0> return MyApp.Worker.handle_call/3
           value: {:reply, 7, %{ticks: 7}}
```

For modules compiled before the wrapped task, installation is synchronous: the
probe task compiles the project, verifies the target module is loaded and the
pattern matched at least one function, and only then runs the wrapped command
— a fast first call cannot slip past the tracer. Modules that only come into
existence while the wrapped task runs (defined in a test file, for example)
get best-effort late-load attachment, announced up front. Either way, a target
that never loads or matches nothing fails the run with an explicit diagnostic
instead of producing silence, and wrapped-command exit statuses pass through
untouched.

The wrapped command is `mix test` or another Mix task that tolerates being
precompiled first; an explicit `--no-compile` is respected. A tracer that
existed before the probe is never replaced silently — pass `--replace-tracer`
to take it over deliberately.

Tracing is always bounded: it stops at exactly `--limit` events (default 200)
and after `--for` milliseconds if given. Keep the target specific — a bare
`Mod` traces every function in the module and will flood a busy run. Erlang
modules use the `:mod`, `:mod.fun`, `:mod.fun/arity` form.

`beam-debug snapshot` runs a command with a watchdog that fires at a
wall-clock time you choose — measured from the start of the wrapped task,
after compilation — while the system is still running, and dumps state,
mailbox sample, current stacktrace, links and monitors for the processes you
name:

```bash
beam-debug snapshot --after 2500 --names MyApp.Worker -- mix test test/hang_test.exs
```

```text
-- named: MyApp.Worker
   current_stacktrace: [
  {Process, :sleep, 1, [file: ~c"lib/process.ex", line: 330]},
  {MyApp.Worker, :handle_call, 3, [file: ~c"lib/my_app/worker.ex", line: 18]},
  ...
]
   state: {:error, {:exit, {:timeout, {:sys, :get_state, [#PID<0.142.0>, 500]}}}}
```

That output is the whole point: the stacktrace names the blocking line, and the
`:sys.get_state` timeout is itself evidence — a GenServer busy inside
`handle_call` cannot answer a system message.

Timing is explicit because ExUnit tears down supervised processes as soon as a
test finishes, so anything that captures *after* the failure finds nothing left
to inspect.

Process discovery is explicit for the same reason: only `--names` targets
receive `:sys` system messages, and only `--supervisors` targets are asked for
their children — either protocol aimed at a process that does not implement it
is slow, noisy, or crashes the callee. Everything else is observed through
`Process.info/2` in two passes: a cheap node-wide ranking scan, then
stacktraces only for the small selected groups — busiest mailboxes (`--top`),
busiest by reductions, largest by memory, and a census of blocked processes in
non-runtime code. The census exists because a deadlocked process usually has
an *empty* mailbox: it lists waiting, empty-mailbox processes executing code
outside the Erlang/Elixir installation (the project or its deps), grouped by
identical stack, so the hung process appears even when nothing has a queue. It
runs only on nodes with at most 400 processes and prints at most 20 stack
groups, reporting what it omitted; on larger nodes pass `--names` with your
suspects. A mailbox observed above 100 messages is reported by length instead
of sampled — `Process.info(pid, :messages)` copies the entire mailbox, which
is exactly wrong for the mailbox-growth case (the queue can still grow between
the length check and a sample; nothing in `Process.info` is atomic across
calls).

Inside IEx the same observations are available directly:

```elixir
BeamDebug.snapshot(MyServer)
BeamDebug.stacktraces()      # busiest mailboxes; stacks fetched only for those
BeamDebug.state(MyServer)
BeamDebug.messages(MyServer)
BeamDebug.supervisor_children(MyApp.Supervisor)
BeamDebug.trace_calls({MyServer, :handle_call, 3}, limit: 50)
```

### Inline instrumentation, as a fallback

Still the fastest check for an already-localized data-flow error. Mark every
temporary line and remove it in the same turn:

```elixir
result = expensive_step(input)
IO.inspect(result, label: "BEAMDBG expensive_step") # BEAMDBG
```

```bash
mix test test/my_test.exs:123
beam-debug assert-clean
```

`beam-debug capture -- ...` is optional. It tees output to a per-repository file
under `${XDG_STATE_HOME:-~/.local/state}/beam-debug/` while preserving the
wrapped command's exit status. Do not use it for interactive `IEx.pry`; use
`beam-debug pry-test` instead.

### Concurrency, and why `--trace` is not the default

`beam-debug test` is a plain `mix test` passthrough. It deliberately does **not**
add `--trace`, because `--trace` sets `--max-cases 1`, which serializes the
suite and can hide the very interleaving that produces a race.

`--trace` appears only in `beam-debug pry-test`, where it is correct: it sets
test timeouts to `:infinity`, which is what makes `IEx.pry` usable during a test.

For a flaky test, preserve the seed ExUnit printed for the failing run and
reproduce with it — at the original scope — before changing anything:

```bash
mix test --seed <failing seed>
mix test --seed <failing seed> --repeat-until-failure 50
```

Only after the failure reproduces under the original conditions, narrow one
variable at a time; jumping straight to a single file can erase a failure that
depends on suite order or another test's state. Do not start from `--seed 0`;
it disables order randomization and often erases the order dependency being
investigated.

`beam-debug pry-test` needs a real terminal, so it is a human-assisted path
rather than the principal escalation mechanism. `trace` and `snapshot` are
non-interactive and work anywhere.

### Evidence journal (optional)

```bash
beam-debug note "cache TTL is off by 1000x" --status confirmed
beam-debug note "worker never receives :tick" --status killed --evidence "trace shows 3 calls"
beam-debug history
beam-debug report
```

Entries are JSONL under `${XDG_STATE_HOME:-~/.local/state}/beam-debug/<repo>/`.
The journal is optional: it earns its keep in long sessions, complex
investigations, and across context compaction, where it stops theories that
already died from being re-tested. Ordinary short debugging does not need a
note per rejected idea. `report` prints a hypothesis summary — the notes
grouped by confirmed / killed / open — not a finished write-up.

### Structural or macro theory

Use the built-in tools directly:

```bash
mix xref callers MyApp.SomeModule
mix xref graph --label compile
```

```elixir
expanded = Macro.expand_once(quoted, __ENV__)
Macro.to_string(expanded) |> IO.puts()
```

## What this intentionally does not install

- `recon`
- `observer_cli`
- Sourceror
- StreamData
- an MCP server
- a background node or remote-shell manager
- source-rewriting automation

Those can be valuable, but forcing them into every repository would make the
baseline slower, more invasive, and more brittle. The skill may use them when a
project already has them or when the current problem genuinely requires them.
It must not add a dependency merely because a built-in check feels less novel.

"No dependencies" does not mean "no performance tier": the OTP profilers
(`mix profile.eprof`, `mix profile.cprof`, `mix profile.fprof`),
`mix test --slowest`, `:erlang.memory/1` and `:erlang.system_monitor/2` ship
with the toolchain and the skill uses them directly.

## Cleanup guard semantics

The guard protects the inline-instrumentation fallback. It is no longer the
architectural centre of the package — `trace` and `snapshot` edit nothing and
need no cleanup — but inline `dbg()` remains the right tool often enough that
cheap protection for it is worth keeping.

The scanner looks only at **newly-added lines** in staged/unstaged diffs and at
untracked `.ex`/`.exs` files. It does not block because an old committed file
happens to contain the string `BEAMDBG`.

The optional Stop hook:

- returns a continuation instruction when new markers remain;
- allows the next stop even if markers still remain, while surfacing a warning,
  so a bad condition cannot trap the CLI in a loop;
- never edits source files itself.

The agent remains responsible for removing the exact temporary instrumentation
it introduced.

## Verify the installation

```bash
beam-debug doctor
./tests/smoke.sh
./tests/integration.sh
```

The smoke test checks shell/Python syntax, compilation of the BEAM helper and
both probes when `elixirc` is available, marker detection, CLI argument
validation, journal round-tripping, idempotent install, hook JSON merging, and
uninstall behavior in an isolated temporary home. It also asserts that
`beam-debug test` never gains an implicit `--trace`.

The integration suite generates throwaway Mix projects and drives `trace` and
`snapshot` end to end through the real CLI: a fast first invocation is
captured, clean compiles and recompiles keep the trace, absent targets fail
loudly, `--limit` stops exactly at the limit, reaching the limit releases
ownership for the next trace, `--for` preserves pre-cutoff events, a
test-file-defined module is traced via the late-load path, a pre-existing
tracer is refused without `--replace-tracer` and taken over with it,
`--no-compile` is respected, wrapped exit statuses (pass, test failure,
compile failure, unknown task) pass through both wrappers, snapshotting an
ordinary GenServer does not crash it, a huge mailbox is not copied, a
zero-mailbox blocked process appears in hang diagnostics, and supervisor
children come only from `--supervisors`. CI runs both suites across several
OTP/Elixir combinations; locally they run on the installed toolchain and skip
cleanly when elixir is unavailable.

Two failure modes the implementation specifically engineers around, worth
knowing if you modify it:

- The OTP 28 `:dbg` tracer was observed to stop handling events while
  `mix test` runs, silently losing the whole trace. `trace_calls` therefore
  uses raw `:erlang.trace/3` and `:erlang.trace_pattern/3` with a plain,
  inspectable tracer process instead of `:dbg`.
- Trace messages are delivered asynchronously and `mix test` halts the VM as
  soon as the suite finishes. The probe task flushes right after the wrapped
  task returns — waiting on `:erlang.trace_delivered/1`, then syncing the
  tracer with a message round-trip — with a `System.at_exit` hook as backstop
  for direct `trace_calls/2` use.

## Uninstall

From the source checkout or installed copy:

```bash
./uninstall.sh
```

The uninstaller removes only the managed instruction blocks, exact hook command,
managed skill copies, managed executable symlink, and package directory.

## Design rationale

Both CLIs now support filesystem Agent Skills, so the substantive workflow is
shared. The only unavoidable differences are their user instruction filenames,
skill locations, hook configuration locations, and explicit skill-invocation
syntax. Keeping those differences in a small installer is materially simpler
than shipping separate agents or plugins.

Codex recommends plugins for broader installable distribution, and Claude
plugins can also bundle skills and hooks. For this single local cross-client
workflow, two product-specific plugin packages would add packaging, trust, and
versioning surface without improving the debugging loop. The direct user-skill
install is intentionally the smaller option; a plugin is a future distribution
option, not a runtime requirement.

The workflow constrains mutation rather than diagnostic breadth. An earlier
version required one theory and one check at a time; that suppresses thrashing
but also causes anchoring on the first plausible explanation, serializes checks
that are independent and could have run together, and misrepresents failures
that have several interacting causes. Breadth in hypotheses and in read-only
observation is cheap and is now encouraged; what stays strictly disciplined is
combining unrelated speculative fixes into one uninterpretable patch.

See [`SOURCES.md`](SOURCES.md) for the official documentation used to verify
current paths and hook behavior.
