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

  # At most this many distinct stack groups are printed by the census, largest
  # first; the number of omitted groups is reported, never silently dropped.
  @census_max_groups 20

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
  copies the entire mailbox. The check and the fetch are separate
  `Process.info/2` calls, so a queue can still grow in between — the guarantee
  is that a mailbox *observed* above the threshold is never fetched.

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
  non-runtime processes — waiting, empty mailbox, executing code outside the
  Erlang/Elixir installation — because a deadlocked process usually has an
  *empty* mailbox). The census runs only on nodes with at most
  #{@census_max_processes} processes and prints at most #{@census_max_groups}
  stack groups, reporting what it omitted.

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

  # Above this tracer queue length the trace is aborted outright: the target
  # is generating events far faster than they can be printed, and draining the
  # backlog would only deepen the perturbation it is meant to observe.
  @overload_threshold 10_000

  @session_key {BeamDebug, :session}

  @doc """
  Bounded call trace of an MFA, including arguments, return values and
  exceptions. Works on local and exported functions and on code you cannot edit.

  Built directly on `:erlang.trace/3` and `:erlang.trace_pattern/3` with a
  plain tracer process — not on `:dbg`, whose OTP 28 tracer has been observed
  to stop handling events while `mix test` runs, silently losing the trace.

  `:limit` (default 200) bounds *output*: exactly that many events are
  printed, tracing is disabled at the source the moment event N is processed,
  and anything already queued past the limit is discarded rather than drained.
  A busy target can still queue events faster than they print; above an
  internal queue threshold the trace aborts with an explicit
  `trace overloaded` warning instead of exhausting the VM. `:for` additionally
  stops the trace after that many milliseconds, preserving events generated
  before the cutoff. Call `stop_calls/0` to stop early.

  Every trace is one session with a unique identity. Duration expiry, limit
  completion and explicit stops all act on that session only: a stale timer or
  a late cleanup from an earlier trace can never stop a newer one.

  Designed for one caller at a time: the ownership claim is not atomic, so
  starting traces concurrently from several processes in the same VM is
  unsupported and can race. Sequential use — including from different
  processes — is fine; `beam-debug trace` runs each trace in its own VM and
  never hits this.

  Setup is transactional: `limit`, `for` and the target arity are validated
  first, and if installation fails partway the flags already set are removed,
  the tracer is terminated, and the session is erased before the error
  returns. Returns `{:ok, matched}` where `matched` is the number of functions
  the pattern matched — zero means the target exists but nothing will ever be
  traced, and the session is cleaned up immediately.

  If an existing tracer is detected — BeamDebug's own, a running `:dbg`
  server, a legacy raw tracer on `:new_processes`, or raw tracing attached to
  any existing process — it is left untouched and
  `{:error, :tracer_already_running}` is returned. Pass `replace: true` to
  deliberately take tracing over; the takeover stops the foreign tracer once,
  up front, and ordinary shutdown afterwards touches only BeamDebug-owned
  state. Isolated trace sessions created via the `:trace` module cannot be
  detected.

      BeamDebug.trace_calls({MyApp.Worker, :handle_call, 3}, limit: 50)
      BeamDebug.trace_calls(MyApp.Worker)
  """
  def trace_calls(target, options \\ []) do
    limit = Keyword.get(options, :limit, 200)
    duration = Keyword.get(options, :for, 0)
    device = Keyword.get(options, :device, :stderr)
    replace = Keyword.get(options, :replace, false)
    overload = Keyword.get(options, :overload_threshold, @overload_threshold)

    result =
      with :ok <- validate_options(limit, duration, overload),
           {:ok, pattern} <- validate_target(target),
           :ok <- claim_tracer(replace, device) do
        install_trace(pattern, limit, duration, device, overload)
      end

    case result do
      {:ok, _} = ok ->
        ok

      {:error, reason} = error ->
        IO.puts(device, "[BEAMDBG] cannot trace: #{inspect(reason)}")
        error
    end
  end

  defp validate_options(limit, duration, overload) do
    cond do
      not (is_integer(limit) and limit >= 1) -> {:error, {:invalid_limit, limit}}
      not (is_integer(duration) and duration >= 0) -> {:error, {:invalid_duration, duration}}
      not (is_integer(overload) and overload >= 1) -> {:error, {:invalid_overload_threshold, overload}}
      true -> :ok
    end
  end

  defp validate_target(target) do
    case safe(fn -> normalize_mfa(target) end) do
      {:ok, {module, function, arity}}
      when is_atom(module) and is_atom(function) and
             (arity == :_ or (is_integer(arity) and arity >= 0)) ->
        {:ok, {module, function, arity}}

      _ ->
        {:error, {:invalid_target, target}}
    end
  end

  # Either returns a complete live session or leaves the VM exactly as it
  # found it: any failure after the flags start going in rolls them back,
  # kills the new tracer and erases the session before the error returns.
  defp install_trace(pattern, limit, duration, device, overload) do
    id = make_ref()

    tracer =
      spawn(fn ->
        tracer_loop(
          %{id: id, pattern: pattern, limit: limit, device: device, overload: overload},
          0
        )
      end)

    # Ownership goes in before the flags so a concurrent trace_calls sees the
    # claim; the rollback below removes it if installation fails.
    :persistent_term.put(@session_key, %{id: id, tracer: tracer, pattern: pattern, device: device})

    case safe(fn ->
           :erlang.trace(:all, true, [:call, :timestamp, {:tracer, tracer}])
           :erlang.trace_pattern(pattern, [{:_, [], [{:exception_trace}]}], [:local])
         end) do
      {:ok, matched} ->
        {module, function, arity} = pattern

        IO.puts(
          device,
          "[BEAMDBG] tracing #{inspect(module)}.#{function}/#{arity} " <>
            "limit=#{limit} for=#{duration}ms matched=#{matched}"
        )

        if matched == 0 do
          # A pattern that matched nothing will never produce an event, and a
          # reloaded module would need a fresh pattern anyway: leave no dead
          # session behind that would block the next trace.
          stop_session(id)
        else
          if duration > 0 do
            # The timer targets this session's own tracer. If the session is
            # stopped first the tracer is dead and the message goes nowhere —
            # a stale window can never stop a trace it did not start.
            Process.send_after(tracer, {:beamdbg_window_elapsed, id}, duration)
          end

          # Trace messages are delivered asynchronously, and `mix test` halts
          # the VM as soon as the suite finishes. Without this hook a fast test
          # loses every trace event it produced. The probe task also stops the
          # session right after the wrapped task returns, which is earlier and
          # safer — this hook is the backstop for direct trace_calls/2 use.
          System.at_exit(fn _ -> flush_trace() end)
        end

        {:ok, matched}

      {:error, reason} ->
        safe(fn -> :erlang.trace_pattern(pattern, false, [:local]) end)
        safe(fn -> :erlang.trace(:all, false, [:call, :timestamp]) end)
        Process.exit(tracer, :kill)
        release_session(id)
        {:error, {:trace_setup_failed, reason}}
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
    with %{tracer: tracer} <- current_session(),
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

  @doc """
  Ordered graceful shutdown of the *current* trace session, safe to call from
  any process at any time: disable the pattern and trace flags, wait for
  already-generated trace messages to be delivered, sync the tracer so they
  are printed, stop the tracer, erase ownership state.

  Scoped strictly to BeamDebug-owned state: a `:dbg` session or foreign
  tracer is never stopped here — foreign tracers are only ever stopped by an
  explicit `replace: true` takeover, at takeover time. No-op when no session
  is live.
  """
  def stop_calls(timeout \\ 2_000) do
    case current_session() do
      %{id: id} -> stop_session(id, timeout)
      _ -> :ok
    end
  end

  # Stop one specific session. A no-op when that session is no longer
  # current, so duration expiry, limit completion and late cleanups can never
  # stop a trace they did not start.
  defp stop_session(id, timeout \\ 2_000) do
    case current_session() do
      %{id: ^id, pattern: pattern, tracer: tracer} = session ->
        disable_tracing(pattern)

        if is_pid(tracer) and Process.alive?(tracer) do
          reference = :erlang.trace_delivered(:all)

          receive do
            {:trace_delivered, _, ^reference} -> :ok
          after
            timeout -> :ok
          end

          sync = make_ref()
          send(tracer, {:beamdbg_sync, self(), sync})

          receive do
            {^sync, :ok} -> :ok
          after
            timeout -> :ok
          end

          # Ownership is released below, so a still-running tracer must not
          # outlive this call: it could otherwise keep printing stale events
          # into a successor trace's output. Confirm the exit; kill on
          # timeout (possible when the io device is wedged and the syncs
          # above timed out with the stop message stuck behind the backlog).
          monitor = Process.monitor(tracer)
          send(tracer, :beamdbg_stop)

          receive do
            {:DOWN, ^monitor, :process, ^tracer, _reason} -> :ok
          after
            timeout ->
              Process.exit(tracer, :kill)
              Process.demonitor(monitor, [:flush])

              IO.puts(
                Map.get(session, :device, :stderr),
                "[BEAMDBG] tracer did not stop in time and was killed; " <>
                  "trailing trace output may have been discarded"
              )
          end
        end

        release_session(id)
        :ok

      _ ->
        :ok
    end
  end

  defp current_session, do: :persistent_term.get(@session_key, nil)

  defp current_session_id do
    case current_session() do
      %{id: id} -> id
      _ -> nil
    end
  end

  # Erase ownership only if this session still holds it: a newer session's
  # state must never be erased by an older session's cleanup.
  defp release_session(id) do
    case current_session() do
      %{id: ^id} -> :persistent_term.erase(@session_key)
      _ -> :ok
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
  # ones executing non-runtime code (anything outside the Erlang/Elixir
  # installation — the project and its deps), grouped by identical stack.
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
              stack -> if non_runtime_stack?(stack, prefixes), do: [{pid, info, stack}], else: []
            end
          end)
          |> Enum.group_by(fn {_, _, stack} -> stack end)
          |> Enum.sort_by(fn {_, entries} -> length(entries) end, :desc)

        if groups == [] do
          IO.puts(device, "\n-- no blocked process is executing non-runtime code")
        else
          IO.puts(device, "\n-- blocked processes in non-runtime code (waiting, empty mailbox)")

          groups
          |> Enum.take(@census_max_groups)
          |> Enum.each(fn {stack, entries} ->
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

          omitted = length(groups) - @census_max_groups

          if omitted > 0 do
            IO.puts(device, "   ... #{omitted} more stack group(s) omitted")
          end
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

  defp non_runtime_stack?(stack, prefixes) do
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

  # Detects our own tracer, a running :dbg server, legacy raw tracers set on
  # :new_processes, and raw tracing attached to selected existing processes.
  # Isolated trace sessions (:trace.session_create) are invisible to all of
  # these and cannot be detected.
  defp claim_tracer(replace, device) do
    session = current_session()
    ours_alive? = match?(%{tracer: tracer} when is_pid(tracer), session) and Process.alive?(session.tracer)
    dbg_running? = Process.whereis(:dbg) != nil

    cond do
      not ours_alive? and not dbg_running? and foreign_tracer() == nil ->
        # A session whose tracer died uncleanly must not block forever; its
        # trace flags disappeared with the tracer.
        if session != nil, do: release_session(session.id)
        :ok

      replace ->
        # Takeover is the one authorized moment to stop foreign tracing, and
        # everything stopped here is announced. Ordinary shutdown afterwards
        # cleans up only BeamDebug-owned state.
        if session != nil, do: stop_session(session.id)

        if dbg_running? do
          IO.puts(device, "[BEAMDBG] replace: stopping the running :dbg session")
          stop_dbg()
        end

        # The legacy trace API has no tracer-scoped disable, so clearing the
        # flags a foreign raw tracer left behind is necessarily global. That
        # is exactly what --replace-tracer authorizes.
        safe(fn -> :erlang.trace(:all, false, [:call, :timestamp]) end)
        :ok

      true ->
        {:error, :tracer_already_running}
    end
  end

  defp stop_dbg do
    # :dbg.stop_clear/0 is deprecated and removed in recent OTP; :dbg.stop/0
    # is present across versions. apply/3 keeps the deprecation warning out
    # of the compile output on the versions where both still exist.
    if function_exported?(:dbg, :stop_clear, 0) do
      apply(:dbg, :stop_clear, [])
    else
      apply(:dbg, :stop, [])
    end
  end

  defp foreign_tracer do
    case safe(fn -> :erlang.trace_info(:new_processes, :tracer) end) do
      {:ok, {:tracer, tracer}} when tracer != [] -> tracer
      _ -> foreign_pid_tracer()
    end
  end

  # Raw call tracing can be attached to selected existing PIDs without
  # touching :new_processes. Detect it, because our shutdown's
  # trace(:all, false) would silently wipe such a trace — the legacy API has
  # no tracer-scoped disable — so coexistence is impossible and the honest
  # options are refusing or an authorized takeover.
  defp foreign_pid_tracer do
    Enum.find_value(Process.list(), fn pid ->
      case safe(fn -> :erlang.trace_info(pid, :tracer) end) do
        {:ok, {:tracer, tracer}} when tracer != [] -> tracer
        _ -> nil
      end
    end)
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
  #
  # Two distinct shutdowns live here. Duration expiry is graceful: events
  # generated before the cutoff are already ahead of the timer message in the
  # mailbox, so they print before tracing is disabled and the loop keeps
  # serving syncs until stopped. Limit and overload are immediate: tracing is
  # disabled at the source and the process exits, discarding whatever queued
  # past the point of usefulness — draining a flood of events that would
  # never be printed only costs memory and shutdown latency.
  defp tracer_loop(
         %{id: id, pattern: pattern, limit: limit, device: device, overload: overload} = state,
         count
       ) do
    receive do
      {:beamdbg_sync, from, reference} ->
        send(from, {reference, :ok})
        tracer_loop(state, count)

      :beamdbg_stop ->
        :ok

      {:beamdbg_window_elapsed, ^id} ->
        if current_session_id() == id, do: disable_tracing(pattern)
        IO.puts(device, "[BEAMDBG] trace window elapsed; tracing stopped")
        spawn(fn -> stop_session(id) end)
        tracer_loop(state, count)

      message when elem(message, 0) in [:trace_ts, :trace] ->
        new_count = count + 1

        if new_count <= limit do
          IO.puts(device, "[BEAMDBG] " <> format_trace(message))
        end

        {:message_queue_len, queued} = Process.info(self(), :message_queue_len)

        cond do
          queued > overload ->
            if current_session_id() == id, do: disable_tracing(pattern)

            IO.puts(
              device,
              "[BEAMDBG] trace overloaded: #{queued} events queued (> #{overload}); " <>
                "tracing aborted, queued events discarded — use a narrower target"
            )

            release_session(id)
            :ok

          new_count == limit ->
            if current_session_id() == id, do: disable_tracing(pattern)
            IO.puts(device, "[BEAMDBG] trace limit #{limit} reached; stopping tracing")
            release_session(id)
            :ok

          true ->
            tracer_loop(state, new_count)
        end

      _other ->
        tracer_loop(state, count)
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
      [head, arity] ->
        case Integer.parse(arity) do
          {value, ""} when value >= 0 ->
            {head, value}

          _ ->
            raise ArgumentError,
                  "arity must be a nonnegative integer, got: #{inspect(arity)}"
        end

      [head] ->
        {head, :_}
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
