defmodule BeamDebug do
  @moduledoc """
  Tiny IEx-only helpers for observing a live OTP process.

  Load with:

      iex -r path/to/beam_debug.exs -S mix
      iex -r path/to/beam_debug.exs -S mix test --trace path/to/test.exs:LINE

  This file is not compiled into the application and adds no project dependency.
  """

  def state(target, timeout \\ 5_000), do: :sys.get_state(target, timeout)

  def status(target, timeout \\ 5_000), do: :sys.get_status(target, timeout)

  def info(target) do
    target
    |> pid!()
    |> Process.info()
  end

  def messages(target) do
    target
    |> pid!()
    |> Process.info(:messages)
  end

  @doc """
  Enable `:sys` event tracing for one process, wait for `duration_ms`, and
  disable tracing even if the wait is interrupted.
  """
  def trace(target, duration_ms \\ 3_000)
      when is_integer(duration_ms) and duration_ms >= 0 do
    :sys.trace(target, true)

    try do
      Process.sleep(duration_ms)
    after
      :sys.trace(target, false)
    end

    :ok
  end

  def stop_trace(target), do: :sys.trace(target, false)

  def pid!(target) when is_pid(target), do: target

  def pid!(target) do
    case GenServer.whereis(target) do
      pid when is_pid(pid) -> pid
      nil -> raise ArgumentError, "no live process found for #{inspect(target)}"
    end
  end
end
