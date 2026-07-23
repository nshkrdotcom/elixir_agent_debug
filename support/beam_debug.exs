defmodule BeamDebug do
  @moduledoc """
  Tiny IEx-and-probe helpers for observing a live BEAM system.

  Load with:

      iex -r path/to/beam_debug.exs -S mix
      iex -r path/to/beam_debug.exs -S mix test --trace path/to/test.exs:LINE

  This file is not compiled into the application and adds no project dependency.

  `snapshot/2` and `report/2` are defensive: a target that is not an OTP
  behaviour, is not alive, or does not answer a system message yields an error
  value instead of blocking or crashing the caller. The thin wrappers `state/2`,
  `status/2`, `info/1`, `messages/1` and `stacktrace/1` are direct calls and can
  raise or exit exactly like the underlying `:sys` and `Process` functions.
  """

  @default_timeout 500

  # `Process.info(pid, :messages)` copies the entire mailbox before anything
  # can sample it; there is no bounded native mailbox sample. Above this queue
  # length the mailbox is reported by length only, never materialized.
  @mailbox_sample_threshold 100
  @mailbox_sample_size 10

  # Above this process count the whole-node blocked-process census is skipped
  # (with an explicit note) instead of fetching stacktraces node-wide.
  @census_max_processes 400

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

  The mailbox is sampled only when the queue is at most
  #{@mailbox_sample_threshold} messages long; a longer queue is reported as
  `{:omitted, {:mailbox_too_large, length}}` because fetching `:messages`
  copies the entire mailbox.

  Sends `:sys.get_state/2` (answered by OTP behaviours only) but never the
  supervisor protocol: use `supervisor_children/2` explicitly for supervisors.
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
          :memory
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
          initial_call: initial_call(pid),
          state: safe(fn -> :sys.get_state(pid, timeout) end)
        }

      {:error, reason} ->
        %{target: target, error: reason}
    end
  end

  @doc """
  Children of an explicitly named supervisor.

  Aim this only at actual supervisors. The supervisor protocol crashes a
  non-supervisor *callee*, which is why `snapshot/2` never sends it implicitly.
  The query runs from an unlinked helper process, so a wrong target degrades to
  `{:error, reason}` for the caller — but the target itself may still crash.
  """
  def supervisor_children(target, timeout \\ 5_000) do
    case resolve(target) do
      {:ok, pid} -> isolated_call(fn -> Supervisor.which_children(pid) end, timeout)
      {:error, reason} -> {:error, reason}
    end
  end

  # --- whole-system observation ---------------------------------------------

  @doc """
  Current stacktraces for the `limit` processes with the busiest mailboxes.

  Two passes: a cheap `Process.info/2` scan ranks every process by queue
  length, then stacktraces are fetched only for the selected few.
  """
  def stacktraces(limit \\ 25) do
    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:registered_name, :message_queue_len]) do
        nil ->
          []

        info ->
          [%{pid: pid, name: info[:registered_name], message_queue_len: info[:message_queue_len] || 0}]
      end
    end)
    |> Enum.sort_by(& &1.message_queue_len, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn entry ->
      Map.put(entry, :current_stacktrace, current_stack(entry.pid))
    end)
  end

  @doc """
  Cheap, always-safe view of one process. Reads `Process.info/2` only: it sends
  no system message, so it cannot hang, cannot be refused, and cannot provoke a
  reply from a process that does not speak OTP. Does not fetch the stacktrace
  or the process dictionary; `initial_call` is the raw spawn MFA, which is
  `:proc_lib.init_p/5` for OTP-compliant processes.
  """
  def brief(pid) when is_pid(pid) do
    keys = [
      :registered_name,
      :status,
      :message_queue_len,
      :memory,
      :reductions,
      :current_function,
      :initial_call
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
          memory: info[:memory],
          reductions: info[:reductions],
          current_function: info[:current_function],
          initial_call: info[:initial_call]
        }
    end
  end

  @doc """
  Print a snapshot report.

  Only explicitly named processes are sent system messages (`:sys.get_state/2`),
  and only processes named in `supervisors:` are sent the supervisor protocol —
  aimed at a process that does not implement them those calls are slow, noisy,
  and can crash the callee. Everything else is observed through `Process.info/2`
  in two passes: a cheap node-wide scan first, stacktraces only for the small
  ranked groups that the scan selects (busiest mailboxes, busiest schedulers,
  largest memory, and — when the node is small enough — a census of blocked
  application processes, because a deadlocked process usually has an *empty*
  mailbox).

  Options: `top:` (mailbox group size, default 10), `supervisors:` (names to
  query with `supervisor_children/2`), `device:` (default `:stderr`).
  """
  def report(names \\ [], opts \\ []) when is_list(names) and is_list(opts) do
    top = Keyword.get(opts, :top, 10)
    device = Keyword.get(opts, :device, :stderr)
    supervisors = Keyword.get(opts, :supervisors, [])

    named = Enum.map(names, &snapshot/1)
    named_pids = named |> Enum.map(& &1[:pid]) |> Enum.reject(&is_nil/1) |> MapSet.new()

    scan = census_scan()
    deltas = reductions_delta(scan)

    IO.puts(device, "\n=== BEAMDBG snapshot ===")
    IO.puts(device, "node: #{inspect(node())}  processes: #{length(scan)}")
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

    Enum.each(supervisors, fn name ->
      IO.puts(device, "\n-- supervisor: #{inspect(name)}")

      case supervisor_children(name) do
        {:ok, children} ->
          Enum.each(children, fn child ->
            IO.puts(device, "   #{inspect(child, pretty: true, limit: 50)}")
          end)

        {:error, reason} ->
          IO.puts(device, "   error: #{inspect(reason, limit: 20)}")
      end
    end)

    interesting = Enum.reject(scan, fn {pid, _} -> pid == self() or MapSet.member?(named_pids, pid) end)

    print_busiest(device, interesting, top)
    print_busy_schedulers(device, interesting, deltas)
    print_largest_memory(device, interesting)
    print_blocked_census(device, interesting, length(scan))

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
  Bounded call trace of an MFA, including arguments, return values and
  exceptions. Works on local and exported functions and on code you cannot edit.

  Built directly on `:erlang.trace/3` and `:erlang.trace_pattern/3` with a
  plain tracer process — not on `:dbg`, whose OTP 28 tracer has been observed
  to stop handling events while `mix test` runs, silently losing the trace.

  Always bounded: tracing stops at exactly `:limit` events (default 200) and,
  if given, after `:for` milliseconds. Call `stop_calls/0` to stop early.

  Returns `{:ok, matched}` where `matched` is the number of functions the
  pattern matched — zero means the target exists but nothing will ever be
  traced. If a tracer (ours or a `:dbg` session) already exists it is left
  untouched and `{:error, :tracer_already_running}` is returned; pass
  `replace: true` to deliberately take tracing over.

      BeamDebug.trace_calls({MyApp.Worker, :handle_call, 3}, limit: 50)
      BeamDebug.trace_calls(MyApp.Worker)
  """
  def trace_calls(target, options \\ []) do
    limit = Keyword.get(options, :limit, 200)
    duration = Keyword.get(options, :for, 0)
    device = Keyword.get(options, :device, :stderr)
    replace = Keyword.get(options, :replace, false)
    {module, function, arity} = normalize_mfa(target)
    pattern = {module, function, arity}

    case claim_tracer(replace) do
      :ok ->
        tracer = spawn(fn -> tracer_loop(pattern, limit, device, 0) end)
        :persistent_term.put({BeamDebug, :tracer}, tracer)
        :persistent_term.put({BeamDebug, :trace_pattern}, pattern)

        :erlang.trace(:all, true, [:call, :timestamp, {:tracer, tracer}])
        matched = :erlang.trace_pattern(pattern, [{:_, [], [{:exception_trace}]}], [:local])

        IO.puts(
          device,
          "[BEAMDBG] tracing #{inspect(module)}.#{function}/#{arity} " <>
            "limit=#{limit} for=#{duration}ms matched=#{matched}"
        )

        if duration > 0 do
          spawn(fn ->
            Process.sleep(duration)
            stop_calls()
            IO.puts(device, "[BEAMDBG] trace window elapsed; tracing stopped")
          end)
        end

        # Trace messages are delivered asynchronously, and `mix test` halts
        # the VM as soon as the suite finishes. Without this hook a fast test
        # loses every trace event it produced. The probe task also flushes
        # right after the wrapped task returns, which is earlier and safer —
        # this hook is the backstop for direct trace_calls/2 use.
        System.at_exit(fn _ -> flush_trace() end)

        {:ok, matched}

      {:error, reason} ->
        IO.puts(device, "[BEAMDBG] cannot trace: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Wait until every trace message already generated has been delivered to the
  tracer *and* printed by it.

  Trace delivery is asynchronous. `mix test` halts the VM the moment the suite
  finishes, so a fast test would otherwise produce a matched trace and print
  nothing at all.
  """
  def flush_trace(timeout \\ 2_000) do
    with tracer when is_pid(tracer) <- :persistent_term.get({BeamDebug, :tracer}, nil),
         true <- Process.alive?(tracer) do
      reference = :erlang.trace_delivered(:all)

      receive do
        {:trace_delivered, _, ^reference} -> :ok
      after
        timeout -> :ok
      end

      # The tracer serves its mailbox in order, so a sync reply proves every
      # trace message delivered before it has been formatted and written out.
      sync = make_ref()
      send(tracer, {:beamdbg_sync, self(), sync})

      receive do
        {^sync, :ok} -> :ok
      after
        timeout -> :ok
      end
    else
      _ -> :ok
    end

    :ok
  end

  def stop_calls do
    case :persistent_term.get({BeamDebug, :trace_pattern}, nil) do
      {_, _, _} = pattern ->
        disable_tracing(pattern)
        :persistent_term.erase({BeamDebug, :trace_pattern})

      _ ->
        :ok
    end

    case :persistent_term.get({BeamDebug, :tracer}, nil) do
      tracer when is_pid(tracer) ->
        if Process.alive?(tracer), do: send(tracer, :beamdbg_stop)
        :persistent_term.erase({BeamDebug, :tracer})

      _ ->
        :ok
    end

    # Also clear a :dbg session when taking over from one (replace: true).
    if Process.whereis(:dbg) do
      # :dbg.stop_clear/0 is deprecated and removed in recent OTP; :dbg.stop/0
      # is present across versions. apply/3 keeps the deprecation warning out
      # of the compile output on the versions where both still exist.
      if function_exported?(:dbg, :stop_clear, 0) do
        apply(:dbg, :stop_clear, [])
      else
        apply(:dbg, :stop, [])
      end
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

  # --- report sections --------------------------------------------------------

  defp print_busiest(device, scan, top) do
    busiest =
      scan
      |> Enum.filter(fn {_, info} -> (info.message_queue_len || 0) > 0 end)
      |> Enum.sort_by(fn {_, info} -> info.message_queue_len end, :desc)
      |> Enum.take(top)

    if busiest == [] do
      IO.puts(device, "\n-- no process has a non-empty mailbox")
    else
      IO.puts(device, "\n-- busiest processes by mailbox length (top #{top})")

      Enum.each(busiest, fn {pid, info} ->
        entry = info |> Map.put(:pid, pid) |> Map.put(:current_stacktrace, current_stack(pid))
        IO.puts(device, inspect(entry, pretty: true, limit: 50, printable_limit: 2048))
      end)
    end
  end

  defp print_busy_schedulers(device, scan, deltas) do
    busy =
      scan
      |> Enum.map(fn {pid, info} -> {pid, info, Map.get(deltas, pid, 0)} end)
      |> Enum.filter(fn {_, _, delta} -> delta > 0 end)
      |> Enum.sort_by(fn {_, _, delta} -> delta end, :desc)
      |> Enum.take(5)

    if busy != [] do
      IO.puts(device, "\n-- busiest processes by reductions (~100ms interval)")

      Enum.each(busy, fn {pid, info, delta} ->
        IO.puts(
          device,
          "   #{inspect(pid)} #{format_name(info)} +#{delta} " <>
            "in #{inspect(info.current_function)}"
        )
      end)
    end
  end

  defp print_largest_memory(device, scan) do
    largest =
      scan
      |> Enum.sort_by(fn {_, info} -> info.memory || 0 end, :desc)
      |> Enum.take(5)

    IO.puts(device, "\n-- largest processes by memory")

    Enum.each(largest, fn {pid, info} ->
      IO.puts(
        device,
        "   #{inspect(pid)} #{format_name(info)} #{info.memory} bytes, " <>
          "queue #{info.message_queue_len}, #{inspect(info.current_function)}"
      )
    end)
  end

  # A blocked process usually has an *empty* mailbox, so ranking by queue
  # length alone can omit the one process a hang investigation needs. On a
  # small node: fetch stacks for waiting, empty-mailbox processes and keep the
  # ones executing application code, grouped by identical stack.
  defp print_blocked_census(device, scan, total) do
    cond do
      total > @census_max_processes ->
        IO.puts(
          device,
          "\n-- blocked-process census skipped: #{total} processes " <>
            "(> #{@census_max_processes}); pass --names to inspect suspects directly"
        )

      true ->
        prefixes = system_path_prefixes()

        groups =
          scan
          |> Enum.filter(fn {_, info} ->
            info.status == :waiting and (info.message_queue_len || 0) == 0
          end)
          |> Enum.flat_map(fn {pid, info} ->
            case current_stack(pid) do
              nil -> []
              stack -> if app_stack?(stack, prefixes), do: [{pid, info, stack}], else: []
            end
          end)
          |> Enum.group_by(fn {_, _, stack} -> stack end)

        if groups == %{} do
          IO.puts(device, "\n-- no blocked process is executing application code")
        else
          IO.puts(device, "\n-- blocked application processes (waiting, empty mailbox)")

          Enum.each(groups, fn {stack, entries} ->
            names =
              entries
              |> Enum.take(3)
              |> Enum.map(fn {pid, info, _} -> "#{inspect(pid)} #{format_name(info)}" end)
              |> Enum.join(", ")

            IO.puts(device, "   #{length(entries)} process(es): #{names}")

            stack
            |> Enum.take(10)
            |> Enum.each(fn frame ->
              IO.puts(device, "      #{Exception.format_stacktrace_entry(frame)}")
            end)
          end)
        end
    end
  end

  defp census_scan do
    keys = [
      :registered_name,
      :status,
      :message_queue_len,
      :memory,
      :reductions,
      :current_function,
      :initial_call
    ]

    Enum.flat_map(Process.list(), fn pid ->
      case Process.info(pid, keys) do
        nil -> []
        info -> [{pid, Map.new(info)}]
      end
    end)
  end

  defp reductions_delta(scan, interval \\ 100) do
    Process.sleep(interval)

    Map.new(
      Enum.flat_map(scan, fn {pid, info} ->
        case Process.info(pid, :reductions) do
          {:reductions, count} -> [{pid, count - (info.reductions || 0)}]
          nil -> []
        end
      end)
    )
  end

  defp current_stack(pid) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stack} -> stack
      nil -> nil
    end
  end

  defp format_name(%{registered_name: name}) when is_atom(name) and name != nil,
    do: inspect(name)

  defp format_name(_), do: "(unnamed)"

  defp app_stack?(stack, prefixes) do
    Enum.any?(stack, fn
      {module, _f, _a, _location} -> not system_module?(module, prefixes)
      _ -> false
    end)
  end

  # Our own tooling counts as system: the probe task waiting on the wrapped
  # Mix task would otherwise show up in every census.
  @tooling_modules [BeamDebug, Mix.Tasks.BeamDebug.Trace, Mix.Tasks.BeamDebug.Snapshot]

  defp system_module?(module, prefixes) do
    module in @tooling_modules or
      case :code.which(module) do
        :preloaded ->
          true

        path when is_list(path) ->
          path = to_string(path)
          Enum.any?(prefixes, &String.starts_with?(path, &1))

        _ ->
          false
      end
  end

  defp system_path_prefixes do
    erlang_root = to_string(:code.root_dir())

    elixir_root =
      case :code.lib_dir(:elixir) do
        {:error, _} -> nil
        dir -> dir |> to_string() |> Path.dirname()
      end

    Enum.reject([erlang_root, elixir_root], &is_nil/1)
  end

  # --- internals -------------------------------------------------------------

  defp claim_tracer(replace) do
    ours = :persistent_term.get({BeamDebug, :tracer}, nil)
    ours_alive? = is_pid(ours) and Process.alive?(ours)
    dbg_running? = Process.whereis(:dbg) != nil

    cond do
      not ours_alive? and not dbg_running? ->
        :ok

      replace ->
        stop_calls()
        :ok

      true ->
        {:error, :tracer_already_running}
    end
  end

  defp disable_tracing(pattern) do
    safe(fn ->
      :erlang.trace_pattern(pattern, false, [:local])
      :erlang.trace(:all, false, [:call, :timestamp])
    end)

    :ok
  end

  # A plain spawned process, deliberately not a :dbg tracer: it may print, be
  # inspected, and keep serving its mailbox in order, so a sync round-trip
  # proves everything delivered before it has been written out.
  defp tracer_loop(pattern, limit, device, count) do
    receive do
      {:beamdbg_sync, from, reference} ->
        send(from, {reference, :ok})
        tracer_loop(pattern, limit, device, count)

      :beamdbg_stop ->
        :ok

      message when elem(message, 0) in [:trace_ts, :trace] ->
        new_count = count + 1

        if new_count <= limit do
          IO.puts(device, "[BEAMDBG] " <> format_trace(message))
        end

        if new_count == limit do
          IO.puts(device, "[BEAMDBG] trace limit #{limit} reached; stopping tracing")
          disable_tracing(pattern)
        end

        tracer_loop(pattern, limit, device, new_count)

      _other ->
        tracer_loop(pattern, limit, device, count)
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
  Parse a trace target into an MFA pattern where unspecified parts are `:_`.

  Elixir: `"Mod"`, `"Mod.fun"`, `"Mod.fun/arity"`.
  Erlang: `":mod"`, `":mod.fun"`, `":mod.fun/arity"`.
  """
  def parse_target(":" <> rest) when byte_size(rest) > 0 do
    {name, arity} = split_arity(rest)

    case String.split(name, ".") do
      [module] ->
        {String.to_atom(module), :_, arity}

      parts ->
        module = parts |> Enum.drop(-1) |> Enum.join(".") |> String.to_atom()
        {module, parts |> List.last() |> String.to_atom(), arity}
    end
  end

  def parse_target(text) when is_binary(text) do
    {text, arity} = split_arity(text)
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

  defp split_arity(text) do
    case String.split(text, "/", parts: 2) do
      [head, arity] -> {head, String.to_integer(arity)}
      [head] -> {head, :_}
    end
  end

  @doc """
  Parse a comma-separated list of registered names: Elixir aliases
  (`MyApp.Worker`), plain atoms (`my_name`) and explicit Erlang atoms
  (`:my_name`).
  """
  def parse_names(nil), do: []
  def parse_names(""), do: []

  def parse_names(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_name/1)
  end

  defp parse_name(":" <> name), do: String.to_atom(name)

  defp parse_name(<<first, _::binary>> = name) when first >= ?A and first <= ?Z,
    do: Module.concat([name])

  defp parse_name(name), do: String.to_atom(name)

  defp sample_messages(pid) do
    case Process.info(pid, :message_queue_len) do
      nil ->
        nil

      {:message_queue_len, length} when length <= @mailbox_sample_threshold ->
        case Process.info(pid, :messages) do
          {:messages, messages} -> Enum.take(messages, @mailbox_sample_size)
          nil -> nil
        end

      {:message_queue_len, length} ->
        {:omitted, {:mailbox_too_large, length}}
    end
  end

  # For one explicitly named process the dictionary read behind
  # translate_initial_call is cheap and yields the real callback module rather
  # than :proc_lib.init_p/5.
  defp initial_call(pid) do
    case safe(fn -> :proc_lib.translate_initial_call(pid) end) do
      {:ok, mfa} -> mfa
      {:error, _} -> nil
    end
  end

  # Run a call that can crash its *callee* (and therefore the caller, via the
  # call exit) in an unlinked, monitored process so an unsuitable target
  # degrades to an error tuple.
  defp isolated_call(fun, timeout) do
    parent = self()
    reference = make_ref()

    {child, monitor} = spawn_monitor(fn -> send(parent, {reference, fun.()}) end)

    receive do
      {^reference, result} ->
        Process.demonitor(monitor, [:flush])
        {:ok, result}

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
