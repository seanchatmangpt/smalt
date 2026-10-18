defmodule Smalt.ArmGateway.LRO do
  @moduledoc """
  Long-running-operation (LRO) seam for the ARM gateway.

  Store-backed (`:smalt_operations` via `Smalt.Store`) operation records with a
  configurable completion delay (`Application.get_env(:smalt, :lro_delay_ms, 0)`).
  `start_op/1` persists an InProgress record carrying `startedAtMs` + `delayMs`.
  Since the v26.10.18 one-writer redesign (`rewrite-drafts/
  lib-redesign-wasm-lro.md` Part 2) convergence is OWNED, not emergent:
  `Smalt.ArmGateway.LRO.Sweeper` is the SINGLE terminal writer (the only
  flip-path invoker of the public `evaluate/2` / `fail_closed/2`), the read
  path (`get_op/1`) is a reader that ROUTES its persistence through the
  writer, and the sweeper publishes each terminal through
  `Smalt.ArmGateway.LRO.Notifier` so `await/3` waiters wake on the explicit
  signal. A due InProgress record renders terminal on the first poll (wire
  contract unchanged: 202 + Retry-After until the delay elapses, then 200);
  an InProgress record missing its scheduling fields (only reachable via
  direct writes to the public ETS table — see `evaluate/1`) fails closed at
  read time, never wedged; the same holds for any record whose "status"
  member is missing or not a binary (lens-10: fail-closed at read).
  There is no process-lifetime coupling: completion is a pure function of the
  stored record and the clock, so an operation started from a short-lived
  Bandit request process still flips on a later poll. The terminal flip is
  ALSO driven at rest by the sweeper's periodic pass, so an operation never
  polled still reaches terminal in the store.

  The router exposes GET `/subscriptions/:sub/operations/:op_id`, and 202
  responses carry `Azure-AsyncOperation`, `Location` and `Retry-After` headers.
  """

  alias Smalt.Store

  @lro_await_msg :lro_terminal

  @doc """
  Starts an operation for `resource_id` (a full ARM id). Returns the operation
  record with status "InProgress".
  """
  def start_op(resource_id) do
    op_id = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    sub = subscription_of(resource_id)
    delay = Application.get_env(:smalt, :lro_delay_ms, 0)

    # Fail closed on config: a non-integer :lro_delay_ms would mint records
    # that route to the incomplete-record Failed terminal at first poll —
    # every operation in the deployment silently fails (lens-9 cycle-7).
    if not is_integer(delay) do
      raise ArgumentError,
            ":smalt :lro_delay_ms must be an integer (milliseconds), got: #{inspect(delay)}"
    end

    record = %{
      "id" => "/subscriptions/#{sub}/operations/#{op_id}",
      "name" => op_id,
      "status" => "InProgress",
      "startTime" => now_iso(),
      "endTime" => nil,
      "resourceId" => resource_id,
      "startedAtMs" => System.system_time(:millisecond),
      "delayMs" => delay
    }

    :ok = Store.put(:smalt_operations, op_id, record)
    record
  end

  @doc """
  Returns `{:ok, record}` | `:error` for an operation id.

  Since the v26.10.18 one-writer redesign (`rewrite-drafts/
  lib-redesign-wasm-lro.md` Part 2) this is a PURE READER on the wire-record
  path: it never calls `Store.put` itself. A due InProgress record and a
  malformed record each compute their terminal VIEW in memory and route the
  persistence through the SINGLE terminal writer — a synchronous call to
  `Smalt.ArmGateway.LRO.Sweeper` (`{:flip_due, key}` / `{:fail_closed, key,
  record}`), the only process that invokes `evaluate/2` / `fail_closed/2` on
  the flip path. The sweeper's reply (the persisted terminal) is returned;
  if the sweeper is down, the computed VIEW is returned instead (fail-safe,
  disclosed: store convergence then waits for the next sweep pass / writer
  restart, bounded by the sweep interval).
  """
  def get_op(op_id) do
    case Store.get(:smalt_operations, op_id) do
      {:ok, %{"status" => "InProgress"} = record} -> {:ok, evaluate_via_writer(record, op_id)}
      # A binary status that is not InProgress is a terminal vocabulary (the
      # router's default-terminal principle: anything not InProgress renders
      # 200) — pass through untouched, never rewrite an externally-authored
      # terminal.
      {:ok, %{"status" => status} = record} when is_binary(status) -> {:ok, record}
      # Missing or non-binary "status": a malformed record no in-codebase
      # writer can produce (start_op/1 and evaluate/2 always write a binary
      # status). It would otherwise sit at rest forever, never evaluated, and
      # poll 200 with NO status member — the mirror of the lens-8 livelock
      # (lens-10 cycle-2, measured). Fail closed via the single writer
      # (bypassing the scheduling clause, which could otherwise return a
      # status-less record unchanged during its delay window).
      {:ok, record} when is_map(record) -> {:ok, fail_closed_via_writer(record, op_id)}
      # A NON-MAP record (list/integer/... under an operations key — only
      # reachable via a direct external write) previously crashed the poll
      # with BadMapError (wire 500-forever, lens-10 cycle-3, measured — same
      # class as the lens-9 cycle-6 crash face). Fail closed on a fresh
      # minimal terminal via the single writer: the store converges to the
      # typed Failed record, and the terminal's malformed/absent "id" makes
      # it 404 (OperationNotFound) through the subscription-scoped poll —
      # deny-by-default, never a 500.
      {:ok, _non_map_record} -> {:ok, fail_closed_via_writer(%{}, op_id)}
      other -> other
    end
  end

  @doc """
  As `get_op/1`, but additionally verifies the operation record belongs to
  `expected_sub` (the `:sub` segment of the polling URL). A cross-subscription
  poll of another subscription's operation id returns `:error` (404
  OperationNotFound), never the foreign record.
  """
  def get_op(op_id, expected_sub) do
    case get_op(op_id) do
      {:ok, record} ->
        if scoped?(record, expected_sub), do: {:ok, record}, else: :error

      # Deny by default: a record whose id is missing or not a well-formed
      # subscription-scoped id does not PROVE ownership, so it is never
      # returned across a subscription-scoped poll (lens-9 cycle-5 — the old
      # `other -> other` leaked malformed records to foreign subscribers).
      _ ->
        :error
    end
  end

  @doc """
  Pure ownership predicate: does `record`'s `id` prove it belongs to
  `expected_sub` (the `:sub` segment of the polling URL)? A missing or
  malformed id never proves ownership. Shared by `get_op/2` and the
  Notifier's deny-by-default awaiter registration.
  """
  def scoped?(record, expected_sub)

  def scoped?(%{"id" => "/subscriptions/" <> rest}, expected_sub) do
    case String.split(rest, "/") do
      [^expected_sub | _] -> true
      _ -> false
    end
  end

  def scoped?(_, _), do: false

  @doc """
  Pure clock predicate: is this InProgress record's delay fully elapsed?
  Malformed scheduling fields are NOT due (they route to `fail_closed/2`
  through the writer instead). Used by the Notifier's due-check timer.
  """
  def due?(%{"startedAtMs" => started, "delayMs" => delay})
      when is_integer(started) and is_integer(delay) do
    System.system_time(:millisecond) - started >= delay
  end

  def due?(_), do: false

  @doc """
  Waits for `op_id` to reach a terminal status. Store-first: a terminal
  VIEW returns immediately. Otherwise the caller registers as a monitored
  waiter with `Smalt.ArmGateway.LRO.Notifier` and blocks on the explicit
  terminal signal; on notifier-down (or a registration race) it falls back
  to bounded store polling — the signal layer is an optimization, never
  correctness.

  Returns:

    - `{:ok, record}` — the terminal record (Succeeded or Failed vocabulary)
    - `{:error, :timeout}` — typed timeout at `timeout` ms
    - `:error` — unknown op id, or (with `expected_sub`) ownership not
      proven — deny-by-default, matching `get_op/2`

  The `expected_sub` clause (`await/3`) mirrors `get_op/2`: a
  cross-subscription await is refused WITHOUT registering any waiter.
  """
  def await(op_id, timeout \\ 5_000) when is_integer(timeout) and timeout >= 0 do
    do_await(op_id, nil, timeout)
  end

  def await(op_id, expected_sub, timeout) when is_binary(expected_sub) do
    do_await(op_id, expected_sub, timeout)
  end

  defp do_await(op_id, expected_sub, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    # Store-first fast path (also routes any due/malformed persistence
    # through the single writer).
    case get_scoped(op_id, expected_sub) do
      {:ok, %{"status" => status} = record} when is_binary(status) and status != "InProgress" ->
        {:ok, record}

      {:ok, _in_progress_view} ->
        await_registered(op_id, expected_sub, deadline)

      # :error (not found / denied) — deny-by-default, no waiter.
      :error ->
        :error
    end
  end

  defp await_registered(op_id, expected_sub, deadline) do
    notifier_pid = Process.whereis(Smalt.ArmGateway.LRO.Notifier)

    mref =
      case notifier_pid do
        nil -> nil
        pid -> Process.monitor(pid)
      end

    case Smalt.ArmGateway.LRO.Notifier.register(op_id, expected_sub) do
      {:ok, _ref, {:terminal, record}} ->
        demonitor_notifier(mref)
        {:ok, record}

      {:ok, ref, nil} ->
        await_loop(op_id, ref, mref, expected_sub, deadline)

      {:error, :notifier_down} ->
        fallback_loop(op_id, expected_sub, deadline)

      {:error, _deny_or_missing} ->
        demonitor_notifier(mref)
        :error
    end
  end

  defp await_loop(op_id, ref, mref, expected_sub, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      remaining <= 0 ->
        cleanup_waiter(op_id, ref, mref)
        {:error, :timeout}

      true ->
        receive do
          {@lro_await_msg, ^op_id, record} ->
            demonitor_notifier(mref)
            {:ok, record}

          {:DOWN, ^mref, :process, _pid, _reason} ->
            # Notifier died mid-await: fail-safe, fall back to bounded store
            # polling. A late terminal signal (racing the DOWN) is still
            # accepted by the fallback loop's receive clause.
            fallback_loop(op_id, expected_sub, deadline)
        after
          remaining ->
            cleanup_waiter(op_id, ref, mref)
            {:error, :timeout}
        end
    end
  end

  # Scoped-or-unscoped read used by await: nil sub -> unscoped get_op/1.
  defp get_scoped(op_id, nil), do: get_op(op_id)

  defp get_scoped(op_id, expected_sub), do: get_op(op_id, expected_sub)

  # Bounded store-poll fallback (notifier-down fail-safe). Runtime-owned
  # timing via `receive after` with the remaining budget, capped at 50ms per
  # pass — never `Process.sleep`.
  defp fallback_loop(op_id, expected_sub, deadline) do
    case get_scoped(op_id, expected_sub) do
      {:ok, %{"status" => status} = record} when is_binary(status) and status != "InProgress" ->
        {:ok, record}

      _ ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          {:error, :timeout}
        else
          receive do
            {@lro_await_msg, ^op_id, record} -> {:ok, record}
          after
            min(remaining, 50) -> fallback_loop(op_id, expected_sub, deadline)
          end
        end
    end
  end

  defp cleanup_waiter(op_id, ref, mref) do
    demonitor_notifier(mref)
    Smalt.ArmGateway.LRO.Notifier.unregister(op_id, ref)
    :ok
  end

  defp demonitor_notifier(nil), do: :ok
  defp demonitor_notifier(mref), do: Process.demonitor(mref, [:flush])

  # -- single-writer routing (read path never persists) --------------------------

  @writer_call_timeout_ms 5_000

  # Due InProgress record: ask the SINGLE terminal writer to persist the
  # flip; return its persisted terminal. On an unreachable/timeout writer,
  # return the computed view without persisting (disclosed fail-safe).
  defp evaluate_via_writer(record, op_id) do
    sched_valid? = is_integer(record["startedAtMs"]) and is_integer(record["delayMs"])

    cond do
      sched_valid? and due?(record) ->
        case writer_call({:flip_due, op_id}) do
          {:ok, terminal} -> terminal
          _ -> view_only_evaluate(record)
        end

      sched_valid? ->
        # Not yet due: InProgress view, untouched.
        record

      true ->
        # Malformed scheduling fields (missing/non-integer): fail closed via
        # the single writer — never return the InProgress record unchanged
        # (lens-8/9/10 fail-closed vocabulary).
        fail_closed_via_writer(record, op_id)
      end
  end

  defp fail_closed_via_writer(record, op_id) do
    case writer_call({:fail_closed, op_id, record}) do
      {:ok, terminal} -> terminal
      _ -> view_only_fail_closed(op_id)
    end
  end

  defp writer_call(req) do
    try do
      GenServer.call(Smalt.ArmGateway.LRO.Sweeper, req, @writer_call_timeout_ms)
    catch
      :exit, _ -> :writer_down
    end
  end

  # In-memory terminal views — computed with the SAME vocabulary the writer
  # persists, minus the store write.
  defp view_only_evaluate(record) do
    record
    |> Map.delete("startedAtMs")
    |> Map.delete("delayMs")
    |> Map.put("status", "Succeeded")
    |> Map.put("endTime", now_iso())
  end

  defp view_only_fail_closed(op_id) do
    %{
      "name" => op_id,
      "status" => "Failed",
      "endTime" => now_iso(),
      "error" => %{
        "code" => "OperationRecordIncomplete",
        "message" =>
          "The operation record is missing or has malformed control fields " <>
            "(status/startedAtMs/delayMs) and cannot be evaluated; the operation was failed " <>
            "instead of wedging in InProgress."
      }
    }
  end

  @doc """
  Pure function of the record + clock: flips the status to Succeeded when the
  delay has fully elapsed and persists the terminal record. A record missing
  or carrying malformed scheduling fields routes to `fail_closed/2` instead.

  PUBLIC precisely so the background sweeper (`Smalt.ArmGateway.LRO.Sweeper`)
  and the lazy poll path call the SAME function and cannot diverge: a swept
  record and a polled record converge to the identical persisted terminal.
  The terminal is persisted under the STORE KEY the caller used (`op_id`),
  never `record["name"]` — in the mint path the two are identical, but an
  incomplete record can lack "name", and persisting under nil re-livelocks
  the polled key (lens-9 cycle-2, measured).
  """
  def evaluate(
        %{"startedAtMs" => started, "delayMs" => delay} = record,
        op_id
      )
      when is_integer(started) and is_integer(delay) do
    if System.system_time(:millisecond) - started >= delay do
      record =
        record
        |> Map.delete("startedAtMs")
        |> Map.delete("delayMs")
        |> Map.put("status", "Succeeded")
        |> Map.put("endTime", now_iso())

      :ok = Store.put(:smalt_operations, op_id, record)
      record
    else
      record
    end
  end

  # A record missing scheduling fields (livelock face, lens-8 fence (13)) OR
  # carrying malformed ones (non-integer startedAtMs/delayMs — the naive
  # clause raised ArithmeticError on every poll, a wire 500-forever crash
  # face, lens-9 cycle-6) can only come from outside the mint path —
  # Store.put/3 is a single atomic :ets.insert of the whole record and
  # start_op/1 always writes both fields as integers, so no in-codebase
  # writer can produce these shapes (lens-9 cycle-1 root cause). They must
  # still terminate: flip to Failed with a typed error member and persist the
  # terminal record. Real Azure operations never wedge in InProgress and a
  # poll never 500s.
  def evaluate(record, op_id) do
    fail_closed(record, op_id)
  end

  @doc """
  The persisted Failed terminal for ANY malformed record shape, regardless of
  which control field is missing or malformed (missing scheduling fields,
  non-integer scheduling fields, missing/non-binary status, non-map records).
  Always persists under the store key the caller used, always repairs "name",
  always carries the typed error member. `get_op/1`'s malformed-status and
  non-map branches, `evaluate/2`'s fallback clause, AND the sweeper all route
  here, so no external-write shape wedges (lens-10 cycle-2 — a status-less
  record previously sat at rest forever and polled 200 with NO status member,
  the mirror of the lens-8 livelock).
  """
  def fail_closed(record, op_id) do
    record =
      record
      |> Map.put("name", op_id)
      |> Map.put("status", "Failed")
      |> Map.put("endTime", now_iso())
      |> Map.put("error", %{
        "code" => "OperationRecordIncomplete",
        "message" =>
          "The operation record is missing or has malformed control fields " <>
            "(status/startedAtMs/delayMs) and cannot be evaluated; the operation was failed " <>
            "instead of wedging in InProgress."
      })

    :ok = Store.put(:smalt_operations, op_id, record)
    record
  end

  defp subscription_of("/subscriptions/" <> rest) do
    [sub | _] = String.split(rest, "/")
    sub
  end

  defp subscription_of(_), do: "00000000-0000-0000-0000-000000000000"

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
