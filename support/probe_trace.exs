# Bounded :dbg call-trace probe. Loaded by `beam-debug trace` via
# `elixir -r ... -S mix beam_debug.trace <task> <args>`, never by the project.
# It lives outside the source tree so no repository file is edited and nothing
# has to be cleaned up afterwards.
#
# Installation is synchronous on purpose: the task compiles the project first,
# verifies the target module is loaded and the pattern matched at least one
# function, and only then runs the wrapped Mix task. The wrapped code therefore
# cannot invoke the target before the trace exists, and a recompile cannot
# replace already-traced code. The one exception is a module that only comes
# into existence while the wrapped task runs (for example a module defined in a
# test file); that falls back to a poller, and if the module never appears the
# run fails with an explicit diagnostic instead of exiting silently.

defmodule Mix.Tasks.BeamDebug.Trace do
  use Mix.Task

  @moduledoc false
  @poll_ms 25
  @outcome_key {__MODULE__, :outcome}

  @impl true
  def run([]) do
    Mix.raise("beam_debug.trace: missing a mix task to wrap (e.g. `test`)")
  end

  def run([wrapped | args]) do
    target =
      case System.get_env("BEAM_DEBUG_TRACE_TARGET") do
        value when is_binary(value) and value != "" -> value
        _ -> Mix.raise("beam_debug.trace: BEAM_DEBUG_TRACE_TARGET is not set")
      end

    limit = int_env("BEAM_DEBUG_TRACE_LIMIT", 200)
    duration = int_env("BEAM_DEBUG_TRACE_FOR", 0)

    Mix.Task.run("compile", [])

    {module, _function, _arity} = mfa = BeamDebug.parse_target(target)

    if Code.ensure_loaded?(module) do
      install!(mfa, target, limit, duration)
    else
      watch_for_late_load(mfa, target, limit, duration)
    end

    Mix.Task.run(wrapped, args)

    # Flush while the io system is still healthy: waiting until at_exit can
    # lose events, because the VM halts while the tty server may still be
    # sitting on the tracer's writes.
    BeamDebug.flush_trace()

    if Process.whereis(:dbg) do
      BeamDebug.stop_calls()
    end

    :ok
  end

  defp install!(mfa, target, limit, duration) do
    case BeamDebug.trace_calls(mfa, limit: limit, for: duration, replace: true) do
      {:ok, matched} when matched > 0 ->
        :ok

      {:ok, 0} ->
        Mix.raise(
          "beam_debug.trace: #{target} matched no functions; check the function name and arity"
        )

      {:error, reason} ->
        Mix.raise("beam_debug.trace: cannot trace #{target}: #{inspect(reason)}")
    end
  end

  # The module is not part of the compiled project (most likely defined by a
  # file the wrapped task loads later, such as a test file). Watch for it, but
  # never let the run end in silence: if the trace was not installed by VM
  # shutdown, say so and fail.
  defp watch_for_late_load(mfa, target, limit, duration) do
    IO.puts(
      :stderr,
      "[BEAMDBG] #{target}: module not loaded after compile; watching for a late load"
    )

    :persistent_term.put(@outcome_key, :pending)
    spawn(fn -> poll(mfa, target, limit, duration) end)

    System.at_exit(fn _status ->
      case :persistent_term.get(@outcome_key, :installed) do
        :installed ->
          :ok

        :pending ->
          IO.puts(
            :stderr,
            "[BEAMDBG] FAILED: #{target} was never loaded; no trace was installed"
          )

          exit({:shutdown, 1})

        {:failed, reason} ->
          IO.puts(:stderr, "[BEAMDBG] FAILED: could not trace #{target}: #{inspect(reason)}")
          exit({:shutdown, 1})
      end
    end)
  end

  defp poll({module, _, _} = mfa, target, limit, duration) do
    if Code.ensure_loaded?(module) do
      case BeamDebug.trace_calls(mfa, limit: limit, for: duration, replace: true) do
        {:ok, matched} when matched > 0 ->
          :persistent_term.put(@outcome_key, :installed)

        {:ok, 0} ->
          :persistent_term.put(@outcome_key, {:failed, :matched_no_functions})

        {:error, reason} ->
          :persistent_term.put(@outcome_key, {:failed, reason})
      end
    else
      Process.sleep(@poll_ms)
      poll(mfa, target, limit, duration)
    end
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
          _ -> Mix.raise("beam_debug.trace: #{name} must be an integer, got: #{value}")
        end
    end
  end
end
