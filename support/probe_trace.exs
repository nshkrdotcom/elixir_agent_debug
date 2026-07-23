# Bounded :dbg call-trace probe. Loaded by `beam-debug trace`, never by the
# project. It lives outside the source tree so no repository file is edited and
# nothing has to be cleaned up afterwards.
#
# This file is loaded before Mix has compiled and loaded the project, so the
# target module usually does not exist yet. The probe therefore waits, in a
# detached process, until the module is loadable before installing the trace.

defmodule BeamDebugTraceProbe do
  @poll_ms 25

  def start do
    target = System.get_env("BEAM_DEBUG_TRACE_TARGET")

    # Load :dbg now, while the boot code path is still complete. Mix prunes
    # unused OTP applications once the project starts, and runtime_tools is one
    # of the first to go.
    BeamDebug.ensure_dbg()

    if is_binary(target) and target != "" do
      limit = integer_env("BEAM_DEBUG_TRACE_LIMIT", 200)
      duration = integer_env("BEAM_DEBUG_TRACE_FOR", 0)
      deadline = integer_env("BEAM_DEBUG_TRACE_DEADLINE", 60_000)
      mfa = BeamDebug.parse_target(target)

      spawn(fn -> wait_and_install(mfa, limit, duration, deadline) end)
    end

    :ok
  end

  defp wait_and_install({module, _, _} = mfa, limit, duration, remaining) do
    cond do
      Code.ensure_loaded?(module) ->
        BeamDebug.trace_calls(mfa, limit: limit, for: duration)

      remaining <= 0 ->
        IO.puts(
          :stderr,
          "[BEAMDBG] gave up waiting for #{inspect(module)} to load; no trace installed"
        )

      true ->
        Process.sleep(@poll_ms)
        wait_and_install(mfa, limit, duration, remaining - @poll_ms)
    end
  end

  defp integer_env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end
end

BeamDebugTraceProbe.start()
