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

The default fast path is still the boring one that works:

1. State one theory and the observation that would confirm or kill it.
2. Add one temporary inline `dbg/1`, `IO.inspect/2`, or `Logger.debug/2` when
   that is the cheapest check.
3. Mark temporary source instrumentation with `# BEAMDBG`.
4. Run the narrowest reproducer and read the actual output.
5. Confirm or revise before another speculative edit.
6. Remove the instrumentation and run `beam-debug assert-clean`.

When the question is specifically about OTP state, process messages, a blocked
caller, or macro/call structure, the installed skill escalates to `:sys.*`,
`IEx.pry`, `Kernel.dbg`, `mix xref`, or macro expansion instead of guessing.

## What gets installed

Common:

- one shared Agent Skill: `elixir-debug`
- one small command: `beam-debug`
- one IEx helper module loaded only when requested
- one deterministic scanner for temporary `# BEAMDBG` markers

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
beam-debug itest test/path_test.exs:42
beam-debug iex
beam-debug capture -- mix test test/path_test.exs:42
beam-debug latest
beam-debug scan
beam-debug assert-clean
```

### Normal fast loop

Use normal inline output. No wrapper is required:

```elixir
result = expensive_step(input)
IO.inspect(result, label: "BEAMDBG expensive_step") # BEAMDBG
```

```bash
mix test test/my_test.exs:123 --trace
beam-debug assert-clean
```

`beam-debug capture -- ...` is optional. It tees output to a per-repository file
under `${XDG_STATE_HOME:-~/.local/state}/beam-debug/` while preserving the
wrapped command's exit status. Do not use it for interactive `IEx.pry`; use
`beam-debug itest` instead.

### Live OTP state or message flow

Add `require IEx; IEx.pry()` at the narrow point, mark it, and run:

```elixir
require IEx; IEx.pry() # BEAMDBG
```

```bash
beam-debug itest test/path_test.exs:42
```

Inside IEx:

```elixir
BeamDebug.state(MyServer)
BeamDebug.status(MyServer)
BeamDebug.info(MyServer)
BeamDebug.messages(MyServer)
BeamDebug.trace(MyServer, 3_000)
```

`beam-debug itest` runs `iex -S mix test --trace` and preloads the helper.
Trace mode is intentional: ExUnit sets test timeout to `:infinity`, which makes
`IEx.pry` usable during tests.

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

## What v1 intentionally does not install

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

## Cleanup guard semantics

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
```

The smoke test checks shell/Python syntax, marker detection, idempotent install,
hook JSON merging, and uninstall behavior in an isolated temporary home.

This packet was built in an environment without Erlang/Elixir, so the included
IEx helper could not be compiled here. It uses only stable standard-library
calls and is intentionally tiny; run this once on the target server:

```bash
elixir ~/.local/share/elixir-agent-debug/support/beam_debug.exs
```

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
install is intentionally the smaller v1; a plugin is a future distribution
option, not a runtime requirement.

See [`SOURCES.md`](SOURCES.md) for the official documentation used to verify
current paths and hook behavior.
