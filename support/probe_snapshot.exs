# Watchdog snapshot probe. Loaded by `beam-debug snapshot` via
# `elixir -r ... -S mix beam_debug.snapshot <task> <args>`, never by the
# project.
#
# Capture timing is explicit rather than clever: ExUnit tears down supervised
# processes as soon as a test finishes, so an after-the-fact hook would find
# nothing left to inspect. The watchdog fires at a wall-clock time you choose,
# measured from the start of the wrapped task (compilation happens first and
# does not count), while the system is still running. That makes it the right
# tool for a hang, a deadlock, or a slow test, and the wrong tool for a fast
# deterministic failure -- use a trace or an inline check for those.
#
# Process discovery is explicit: only --names targets receive :sys system
# messages, and only --supervisors targets are asked for their children, since
# either aimed at a process that does not implement the protocol is slow,
# noisy, or crashes the callee. Everything else is observed via Process.info.

defmodule Mix.Tasks.BeamDebug.Snapshot do
  use Mix.Task

  @moduledoc false

  @impl true
  def run([]) do
    Mix.raise("beam_debug.snapshot: missing a mix task to wrap (e.g. `test`)")
  end

  def run([wrapped | args]) do
    after_ms = int_env("BEAM_DEBUG_SNAPSHOT_AFTER", 5_000)
    top = int_env("BEAM_DEBUG_SNAPSHOT_TOP", 10)
    names = BeamDebug.parse_names(System.get_env("BEAM_DEBUG_SNAPSHOT_NAMES"))
    supervisors = BeamDebug.parse_names(System.get_env("BEAM_DEBUG_SNAPSHOT_SUPERVISORS"))

    Mix.Task.run("compile", [])

    spawn(fn ->
      Process.sleep(after_ms)

      IO.puts(
        :stderr,
        "[BEAMDBG] snapshot watchdog firing after #{after_ms}ms " <>
          "(names: #{inspect(names)}, supervisors: #{inspect(supervisors)}, top: #{top})"
      )

      BeamDebug.report(names, top: top, supervisors: supervisors)
    end)

    Mix.Task.run(wrapped, args)
  end

  defp int_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      "" ->
        default

      value ->
        case Integer.parse(value) do
          {parsed, ""} -> parsed
          _ -> Mix.raise("beam_debug.snapshot: #{name} must be an integer, got: #{value}")
        end
    end
  end
end
