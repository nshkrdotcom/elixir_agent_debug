# Watchdog snapshot probe. Loaded by `beam-debug snapshot`, never by the
# project.
#
# Capture timing is explicit rather than clever: ExUnit tears down supervised
# processes as soon as a test finishes, so an after-the-fact hook would find
# nothing left to inspect. This probe therefore fires at a wall-clock time you
# choose, while the system is still running. That makes it the right tool for a
# hang, a deadlock, or a slow test, and the wrong tool for a fast deterministic
# failure -- use a trace or an inline check for those.

defmodule BeamDebugSnapshotProbe do
  def start do
    after_ms = integer_env("BEAM_DEBUG_SNAPSHOT_AFTER", 5_000)
    top = integer_env("BEAM_DEBUG_SNAPSHOT_TOP", 10)
    names = parse_names(System.get_env("BEAM_DEBUG_SNAPSHOT_NAMES"))

    spawn(fn ->
      Process.sleep(after_ms)

      IO.puts(
        :stderr,
        "[BEAMDBG] snapshot watchdog firing after #{after_ms}ms " <>
          "(names: #{inspect(names)}, top: #{top})"
      )

      BeamDebug.report(names, top)
    end)

    :ok
  end

  defp parse_names(nil), do: []
  defp parse_names(""), do: []

  defp parse_names(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(fn name ->
      case name do
        <<first, _::binary>> when first >= ?A and first <= ?Z -> Module.concat([name])
        _ -> String.to_atom(name)
      end
    end)
  end

  defp integer_env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  end
end

BeamDebugSnapshotProbe.start()
