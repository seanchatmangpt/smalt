defmodule Smalt.ArmGateway.LRO do
  @moduledoc """
  Long-running-operation (LRO) seam for the ARM gateway.

  Store-backed (`:smalt_operations` via `Smalt.Store`) operation records with a
  configurable completion delay (`Application.get_env(:smalt, :lro_delay_ms, 0)`).
  `start_op/1` persists an InProgress record carrying `startedAtMs` + `delayMs`;
  `get_op/1` lazily evaluates completion — when the wall clock has passed
  `startedAtMs + delayMs` the record is flipped to Succeeded and persisted.
  An InProgress record missing its scheduling fields (only reachable via
  direct writes to the public ETS table — see `evaluate/1`) is flipped to
  Failed at read time, never wedged; the same holds for any record whose
  "status" member is missing or not a binary (lens-10: fail-closed at read).
  There is no process-lifetime coupling: completion is a pure function of the
  stored record and the clock, so an operation started from a short-lived
  Bandit request process still flips on a later poll. Since v26.10.14 the
  terminal flip is ALSO driven at rest by `Smalt.ArmGateway.LRO.Sweeper`
  (periodic; same shared `evaluate/2`/`fail_closed/2` functions), so an
  operation never polled still reaches terminal in the store.

  The router exposes GET `/subscriptions/:sub/operations/:op_id`, and 202
  responses carry `Azure-AsyncOperation`, `Location` and `Retry-After` headers.
  """

  alias Smalt.Store

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
  Returns `{:ok, record}` | `:error` for an operation id. Evaluation is lazy:
  an InProgress record whose delay has elapsed is flipped to Succeeded (and
  persisted) at read time.
  """
  def get_op(op_id) do
    case Store.get(:smalt_operations, op_id) do
      {:ok, %{"status" => "InProgress"} = record} -> {:ok, evaluate(record, op_id)}

      # A binary status that is not InProgress is a terminal vocabulary (the
      # router's default-terminal principle: anything not InProgress renders
      # 200) — pass through untouched, never rewrite an externally-authored
      # terminal.
      {:ok, %{"status" => status} = record} when is_binary(status) -> {:ok, record}

      # Missing or non-binary "status": a malformed record no in-codebase
      # writer can produce (start_op/1 and evaluate/2 always write a binary
      # status). It would otherwise sit at rest forever, never evaluated, and
      # poll 200 with NO status member — the mirror of the lens-8 livelock
      # (lens-10 cycle-2, measured). Fail closed DIRECTLY (bypassing the
      # scheduling clause, which could otherwise return a status-less record
      # unchanged during its delay window).
      {:ok, record} when is_map(record) -> {:ok, fail_closed(record, op_id)}

      # A NON-MAP record (list/integer/... under an operations key — only
      # reachable via a direct external write) previously crashed the poll
      # with BadMapError (wire 500-forever, lens-10 cycle-3, measured — same
      # class as the lens-9 cycle-6 crash face). Fail closed on a fresh
      # minimal terminal: the store converges to the typed Failed record, and
      # the terminal's malformed/absent "id" makes it 404 (OperationNotFound)
      # through the subscription-scoped poll — deny-by-default, never a 500.
      {:ok, _non_map_record} -> {:ok, fail_closed(%{}, op_id)}

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
      {:ok, %{"id" => "/subscriptions/" <> rest} = record} ->
        case String.split(rest, "/") do
          [^expected_sub | _] -> {:ok, record}
          _ -> :error
        end

      # Deny by default: a record whose id is missing or not a well-formed
      # subscription-scoped id does not PROVE ownership, so it is never
      # returned across a subscription-scoped poll (lens-9 cycle-5 — the old
      # `other -> other` leaked malformed records to foreign subscribers).
      _ ->
        :error
    end
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
