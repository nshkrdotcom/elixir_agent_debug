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

## Scope decision

`recon`, `observer_cli`, Sourceror, and StreamData are not baseline dependencies.
This is intentional. The package teaches the agent when to use them if already
available, while keeping installation independent of repository dependencies,
OTP distribution setup, and package-version-specific APIs.
