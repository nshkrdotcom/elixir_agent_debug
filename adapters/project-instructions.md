## Elixir/OTP debugging (project note)

This project uses the `elixir-debug` agent skill and the `beam-debug` command
from elixir-agent-debug. Both are installed **per user**, not per project — if
`beam-debug` is not on PATH, install it first:

```bash
git clone https://github.com/nshkrdotcom/elixir_agent_debug
cd elixir_agent_debug && ./install.sh
```

Run `beam-debug doctor` before debugging and check its output. Do not
proceed unless it prints **both** a package `version:` line and an
`ok: project floor ...` result. A too-old floor result means upgrade the
user-level install (pull the latest and rerun `./install.sh`). If either
line is *absent entirely*, the installation predates project-floor support
(pre-1.4.0) and silently ignores `.beam-debug.toml` — it must be upgraded
the same way before debugging here.

Do not vendor or install project-local hooks, skills, or executables for this
package. The executable, skill and optional Stop hook are user-level by
design: project and user hooks would both fire, a same-named personal skill
overrides a project one anyway, and repository-vendored executables should
not run automatically on other people's machines.
