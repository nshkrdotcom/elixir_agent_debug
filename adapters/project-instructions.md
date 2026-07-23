## Elixir/OTP debugging (project note)

This project uses the `elixir-debug` agent skill and the `beam-debug` command
from elixir-agent-debug. Both are installed **per user**, not per project.

**Agents: never install or upgrade user-level tooling yourself.** If
`beam-debug` is missing, or the version check below fails, stop and ask the
user to install or upgrade elixir-agent-debug. For the human, installation
lives outside this project:

```bash
git clone https://github.com/nshkrdotcom/elixir_agent_debug ~/.local/src/elixir-agent-debug
cd ~/.local/src/elixir-agent-debug && ./install.sh
```

(Upgrading later: `git -C ~/.local/src/elixir-agent-debug pull` and rerun
`./install.sh`.)

Run `beam-debug doctor` before debugging and check its output. Do not
proceed unless it prints **both** a package `version:` line and an
`ok: project floor ...` result. A too-old floor result means the user-level
install needs the upgrade above. If either line is *absent entirely*, the
installation predates project-floor support (pre-1.4.0) and silently ignores
`.beam-debug.toml` — same answer: stop and ask the user to upgrade.

Do not vendor or install project-local hooks, skills, or executables for this
package. The executable, skill and optional Stop hook are user-level by
design: project and user hooks would both fire, a same-named personal skill
overrides a project one anyway, and repository-vendored executables should
not run automatically on other people's machines.
