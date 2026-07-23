# Sources and verification notes

Verified 2026-07-19 against current official documentation.

## Claude Code

- User instructions and loading behavior:
  https://code.claude.com/docs/en/memory
- Skills and `~/.claude/skills/<name>/SKILL.md`:
  https://code.claude.com/docs/en/slash-commands
- Hooks, `~/.claude/settings.json`, Stop input/output, and loop protection:
  https://code.claude.com/docs/en/hooks

## Codex CLI

- Global `~/.codex/AGENTS.md`:
  https://learn.chatgpt.com/docs/agent-configuration/agents-md
- Agent Skills and `$HOME/.agents/skills`:
  https://learn.chatgpt.com/docs/build-skills
- Hooks, `~/.codex/hooks.json`, trust review, and Stop behavior:
  https://learn.chatgpt.com/docs/hooks

## Elixir / Erlang

- `mix test --trace` behavior:
  https://hexdocs.pm/mix/Mix.Tasks.Test.html
- `IEx.pry` during tests:
  https://hexdocs.pm/iex/IEx.html
- `Kernel.dbg`:
  https://hexdocs.pm/elixir/Kernel.html#dbg/2
- OTP `:sys` state/status/tracing:
  https://www.erlang.org/doc/apps/stdlib/sys.html
- `mix xref`:
  https://hexdocs.pm/mix/Mix.Tasks.Xref.html
- `Macro.expand_once/2` and `Macro.to_string/1`:
  https://hexdocs.pm/elixir/Macro.html
- `:erlang.trace/3`, `:erlang.trace_pattern/3`, `:erlang.trace_delivered/1`
  (the raw BIFs `trace_calls/2` is built on; `:dbg` is deliberately not used —
  see README "Verify the installation"):
  https://www.erlang.org/doc/apps/erts/erlang.html#trace/3
- Match specifications for trace patterns:
  https://www.erlang.org/doc/apps/erts/match_spec.html
- `Process.info/2` (census, mailbox length, stacktraces):
  https://hexdocs.pm/elixir/Process.html#info/2
- `Supervisor.which_children/1` (explicit `--supervisors` queries only —
  crashes non-supervisor callees):
  https://hexdocs.pm/elixir/Supervisor.html#which_children/1
- Custom Mix tasks (`Mix.Task` behaviour; the probes are `-r`-loaded tasks
  that wrap the requested task):
  https://hexdocs.pm/mix/Mix.Task.html

## Scope decision

`recon`, `observer_cli`, Sourceror, and StreamData are not baseline dependencies.
This is intentional. The package teaches the agent when to use them if already
available, while keeping installation independent of repository dependencies,
OTP distribution setup, and package-version-specific APIs.
