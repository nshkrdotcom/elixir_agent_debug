defmodule BeamDebug do
  @moduledoc """
  Tiny IEx-and-probe helpers for observing a live BEAM system.

  Load with:

      iex -r path/to/beam_debug.exs -S mix
      iex -r path/to/beam_debug.exs -S mix test --trace path/to/test.exs:LINE

  This file is not compiled into the application and adds no project dependency.
  Every observation is defensive: a target that is not an OTP behaviour, is not
  alive, or does not answer a system message returns an error tuple instead of
  blocking the caller.
  """

  @default_timeout 500

  # --- single-process observation -------------------------------------------

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
  Current stacktrace of one process. The first thing to look at when something
  hangs: it shows where the process is actually blocked.
  """
  def stacktrace(target) do
    case Process.info(pid!(target), :current_stacktrace) do
      {:current_stacktrace, stack} -> stack
      nil -> {:error, :not_alive}
    end
  end

  @doc """
  Everything cheap that is knowable about one process, with no call that can
  block the caller for longer than `timeout`.
  """
  def snapshot(target, timeout \\ @default_timeout) do
    case resolve(target) do
      {:ok, pid} ->
        keys = [
          :registered_name,
          :status,
          :message_queue_len,
          :current_stacktrace,
          :links,
          :monitors,
          :monitored_by,
          :memory,
          :dictionary
        ]

        info = Process.info(pid, keys) || []

        %{
          target: target,
          pid: pid,
          alive: Process.alive?(pid),
          registered_name: info[:registered_name],
          status: info[:status],
          message_queue_len: info[:message_queue_len],
          messages: sample_messages(pid),
          current_stacktrace: info[:current_stacktrace],
          links: info[:links],
          monitors: info[:monitors],
          monitored_by: info[:monitored_by],
          memory: info[:memory],
          initial_call: initial_call(info[:dictionary]),
          state: safe(fn -> :sys.get_state(pid, timeout) end),
          children: safe_children(pid, timeout)
        }

      {:error, reason} ->
        %{target: target, error: reason}
    end
  end

  # --- whole-system observation ---------------------------------------------

  @doc """
  Current stacktraces for every live process, busiest mailbox first. This is the
  single highest-value observation for a hang or a deadlock.
  """
  def stacktraces(limit \\ 25) do
    Process.list()
    |> Enum.map(fn pid ->
      info = Process.info(pid, [:registered_name, :message_queue_len, :current_stacktrace])

      %{
        pid: pid,
        name: info[:registered_name],
        message_queue_len: info[:message_queue_len] || 0,
        current_stacktrace: info[:current_stacktrace]
      }
    end)
    |> Enum.sort_by(& &1.message_queue_len, :desc)
    |> Enum.take(limit)
  end

  @doc """
  Cheap, always-safe view of one process. Reads `Process.info/2` only: it sends
  no system message, so it cannot hang, cannot be refused, and cannot provoke a
  reply from a process that does not speak OTP.
  """
  def brief(pid) when is_pid(pid) do
    keys = [
      :registered_name,
      :status,
      :message_queue_len,
      :current_stacktrace,
      :memory,
      :dictionary
    ]

    case Process.info(pid, keys) do
      nil ->
        %{pid: pid, alive: false}

      info ->
        %{
          pid: pid,
          alive: true,
          registered_name: info[:registered_name],
          status: info[:status],
          message_queue_len: info[:message_queue_len],
          current_stacktrace: info[:current_stacktrace],
          memory: info[:memory],
          initial_call: initial_call(info[:dictionary])
        }
    end
  end

  @doc """
  Print a snapshot report.

  Process discovery is explicit on purpose. Only the processes you name get the
  full treatment, because `:sys.get_state/2` and `Supervisor.which_children/1`
  send system messages: aimed at a process that does not implement OTP they are
  slow, noisy in the log, and tell you nothing. Everything discovered by `top`
  gets the cheap `Process.info/2` view instead, which is safe for any process,
  including the VM's own.
  """
  def report(names \\ [], top \\ 10, device \\ :stderr) do
    named = Enum.map(names, &snapshot/1)
    named_pids = named |> Enum.map(& &1[:pid]) |> Enum.reject(&is_nil/1) |> MapSet.new()

    # A zero-length mailbox ranks no higher than any other zero-length mailbox,
    # so listing them just buries the report in idle VM processes.
    busiest =
      Process.list()
      |> Enum.reject(&MapSet.member?(named_pids, &1))
      |> Enum.map(&brief/1)
      |> Enum.filter(&(&1.alive and (&1[:message_queue_len] || 0) > 0))
      |> Enum.sort_by(& &1.message_queue_len, :desc)
      |> Enum.take(top)

    IO.puts(device, "\n=== BEAMDBG snapshot ===")
    IO.puts(device, "node: #{inspect(node())}  processes: #{length(Process.list())}")
    IO.puts(device, "memory: #{inspect(:erlang.memory([:total, :processes, :binary, :ets]))}")

    Enum.each(named, fn entry ->
      IO.puts(device, "\n-- named: #{inspect(entry[:target])}")
      # One inspect per field: a long stacktrace must not consume the budget
      # that the process state needs.
      Enum.each(entry, fn {key, value} ->
        IO.puts(
          device,
          "   #{key}: #{inspect(value, pretty: true, limit: 100, printable_limit: 4096)}"
        )
      end)
    end)

    if busiest == [] do
      IO.puts(device, "\n-- no process has a non-empty mailbox")
    else
      IO.puts(device, "\n-- busiest processes by mailbox length (top #{top})")

      Enum.each(busiest, fn entry ->
        IO.puts(device, inspect(entry, pretty: true, limit: 50, printable_limit: 2048))
      end)
    end

    IO.puts(device, "=== end BEAMDBG snapshot ===\n")
    :ok
  end

  # --- tracing ---------------------------------------------------------------

  @doc """
  Enable `:sys` event tracing for one OTP behaviour process, wait for
  `duration_ms`, and disable tracing even if the wait is interrupted.

  Only works for OTP behaviours. Use `trace_calls/2` for arbitrary functions.
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

  @doc """
  Bounded `:dbg` call trace of an MFA, including arguments, return values and
  exceptions. Works on local and exported functions and on code you cannot edit.

  Always bounded: tracing stops after `:limit` events (default 200) and, if
  given, after `:for` milliseconds. Call `stop_calls/0` to stop early.

      BeamDebug.trace_calls({MyApp.Worker, :handle_call, 3}, limit: 50)
      BeamDebug.trace_calls(MyApp.Worker)
  """
  def trace_calls(target, options \\ []) do
    limit = Keyword.get(options, :limit, 200)
    duration = Keyword.get(options, :for, 0)
    device = Keyword.get(options, :device, :stderr)
    {module, function, arity} = normalize_mfa(target)

    case ensure_dbg() do
      :ok ->
        stop_calls()
        {:ok, _} = :dbg.tracer(:process, {tracer_handler(limit, device), 0})
        {:ok, _} = :dbg.p(:all, [:c, :timestamp])

        matched = :dbg.tpl(module, function, arity, [{:_, [], [{:exception_trace}]}])

        IO.puts(
          device,
          "[BEAMDBG] tracing #{inspect(module)}.#{function}/#{arity} " <>
            "limit=#{limit} for=#{duration}ms matched=#{inspect(matched)}"
        )

        if duration > 0 do
          spawn(fn ->
            Process.sleep(duration)
            stop_calls()
            IO.puts(device, "[BEAMDBG] trace window elapsed; tracing stopped")
          end)
        end

        # Trace messages are delivered asynchronously, and `mix test` halts the
        # VM as soon as the suite finishes. Without this hook a fast test loses
        # every trace event it produced.
        System.at_exit(fn _ -> flush_trace() end)

        :ok

      {:error, reason} ->
        IO.puts(device, "[BEAMDBG] cannot trace: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Wait until every trace message already generated has been delivered to the
  tracer *and* handled by it.

  Trace delivery is asynchronous. `mix test` halts the VM the moment the suite
  finishes, so a fast test would otherwise produce a matched trace and print
  nothing at all.
  """
  def flush_trace(timeout \\ 2_000) do
    if Process.whereis(:dbg) do
      reference = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, _, ^reference} -> :ok
      after
        timeout -> :ok
      end

      drain_tracer(timeout)
    end

    :ok
  end

  defp drain_tracer(remaining) when remaining <= 0, do: :ok

  defp drain_tracer(remaining) do
    with {:ok, tracer} <- safe(fn -> :dbg.get_tracer() end) |> unwrap(),
         true <- is_pid(tracer),
         {:message_queue_len, length} when length > 0 <-
           Process.info(tracer, :message_queue_len) do
      Process.sleep(10)
      drain_tracer(remaining - 10)
    else
      _ -> :ok
    end
  end

  defp unwrap({:ok, {:ok, tracer}}), do: {:ok, tracer}
  defp unwrap(_), do: :error

  def stop_calls do
    # :dbg.stop_clear/0 is deprecated and removed in recent OTP; :dbg.stop/0 is
    # present across versions. apply/3 keeps the deprecation warning out of the
    # compile output on the versions where both still exist.
    if function_exported?(:dbg, :stop_clear, 0) do
      apply(:dbg, :stop_clear, [])
    else
      apply(:dbg, :stop, [])
    end

    :ok
  end

  @doc """
  Make sure `:dbg` is usable.

  Mix prunes unused OTP applications from the code path, so `runtime_tools` is
  frequently absent by the time a probe wants to install a trace even though it
  was reachable at boot. Re-add its ebin directory rather than failing.
  """
  def ensure_dbg do
    cond do
      Code.ensure_loaded?(:dbg) ->
        :ok

      true ->
        case :code.lib_dir(:runtime_tools) do
          {:error, _} ->
            {:error, :runtime_tools_unavailable}

          dir ->
            :code.add_patha(:filename.join(dir, ~c"ebin"))
            if Code.ensure_loaded?(:dbg), do: :ok, else: {:error, :runtime_tools_unavailable}
        end
    end
  end

  # --- internals -------------------------------------------------------------

  defp tracer_handler(limit, device) do
    fn message, count ->
      cond do
        count < limit ->
          IO.puts(device, "[BEAMDBG] " <> format_trace(message))
          count + 1

        count == limit ->
          IO.puts(device, "[BEAMDBG] trace limit #{limit} reached; stopping tracing")
          # Never stop dbg from inside the tracer process itself: it would wait
          # on a reply the tracer cannot deliver while it is in this callback.
          spawn(fn -> stop_calls() end)
          count + 1

        true ->
          count + 1
      end
    end
  end

  defp format_trace({:trace_ts, pid, :call, {module, function, args}, timestamp}) do
    "#{stamp(timestamp)} #{inspect(pid)} call #{Exception.format_mfa(module, function, length(args))}" <>
      "\n           args: #{inspect(args, limit: 25, printable_limit: 2048)}"
  end

  defp format_trace({:trace_ts, pid, :return_from, {module, function, arity}, value, timestamp}) do
    "#{stamp(timestamp)} #{inspect(pid)} return #{Exception.format_mfa(module, function, arity)}" <>
      "\n           value: #{inspect(value, limit: 25, printable_limit: 2048)}"
  end

  defp format_trace({:trace_ts, pid, :exception_from, {module, function, arity}, value, timestamp}) do
    "#{stamp(timestamp)} #{inspect(pid)} raise #{Exception.format_mfa(module, function, arity)}" <>
      "\n           reason: #{inspect(value, limit: 25, printable_limit: 2048)}"
  end

  defp format_trace(other), do: inspect(other, limit: 25, printable_limit: 2048)

  defp stamp(timestamp) do
    {_, {hour, minute, second}} = :calendar.now_to_local_time(timestamp)
    :io_lib.format("~2..0B:~2..0B:~2..0B", [hour, minute, second]) |> to_string()
  end

  defp normalize_mfa({module, function, arity}), do: {module, function, arity}
  defp normalize_mfa({module, function}), do: {module, function, :_}
  defp normalize_mfa(module) when is_atom(module), do: {module, :_, :_}

  @doc """
  Parse "Mod", "Mod.fun" or "Mod.fun/arity" into an MFA pattern where the
  unspecified parts are `:_`.
  """
  def parse_target(text) when is_binary(text) do
    {text, arity} =
      case String.split(text, "/", parts: 2) do
        [head, arity] -> {head, String.to_integer(arity)}
        [head] -> {head, :_}
      end

    parts = String.split(text, ".")

    {module_parts, function} =
      case List.last(parts) do
        <<first, _::binary>> = last when first >= ?a and first <= ?z ->
          {Enum.drop(parts, -1), String.to_atom(last)}

        _ ->
          {parts, :_}
      end

    {Module.concat(module_parts), function, arity}
  end

  defp sample_messages(pid) do
    case Process.info(pid, :messages) do
      {:messages, messages} -> Enum.take(messages, 10)
      nil -> nil
    end
  end

  defp initial_call(dictionary) when is_list(dictionary) do
    Keyword.get(dictionary, :"$initial_call")
  end

  defp initial_call(_), do: nil

  # Asking a non-supervisor for its children makes the *callee* crash, which
  # would take a linked caller with it. Run it in an unlinked, monitored process
  # so an unsuitable target degrades to an error tuple.
  defp safe_children(pid, timeout) do
    parent = self()
    reference = make_ref()

    {child, monitor} =
      spawn_monitor(fn -> send(parent, {reference, Supervisor.which_children(pid)}) end)

    receive do
      {^reference, children} ->
        Process.demonitor(monitor, [:flush])
        {:ok, children}

      {:DOWN, ^monitor, :process, ^child, reason} ->
        {:error, reason}
    after
      timeout ->
        Process.exit(child, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :timeout}
    end
  end

  defp safe(function) do
    try do
      {:ok, function.()}
    catch
      kind, reason -> {:error, {kind, reason}}
    end
  end

  defp resolve(target) do
    cond do
      is_pid(target) -> if Process.alive?(target), do: {:ok, target}, else: {:error, :not_alive}
      true -> case GenServer.whereis(target) do
                pid when is_pid(pid) -> {:ok, pid}
                _ -> {:error, :no_such_process}
              end
    end
  end

  def pid!(target) when is_pid(target), do: target

  def pid!(target) do
    case GenServer.whereis(target) do
      pid when is_pid(pid) -> pid
      nil -> raise ArgumentError, "no live process found for #{inspect(target)}"
    end
  end
end
