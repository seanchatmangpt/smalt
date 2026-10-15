defmodule Smalt.ArmGateway.LRO do
  @moduledoc """
  Long-running-operation (LRO) seam for the ARM gateway.

  Store-backed (`:smalt_operations` via `Smalt.Store`) operation records with a
  configurable completion delay (`Application.get_env(:smalt, :lro_delay_ms, 0)`).
  `start_op/1` persists an InProgress record carrying `startedAtMs` + `delayMs`;
  `get_op/1` lazily evaluates completion — when the wall clock has passed
  `startedAtMs + delayMs` the record is flipped to Succeeded and persisted.
  There is no timer process and no process-lifetime coupling: completion is a
  pure function of the stored record and the clock, so an operation started from
  a short-lived Bandit request process still flips on a later poll.

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

    record = %{
      "id" => "/subscriptions/#{sub}/operations/#{op_id}",
      "name" => op_id,
      "status" => "InProgress",
      "startTime" => now_iso(),
      "endTime" => nil,
      "resourceId" => resource_id,
      "startedAtMs" => System.system_time(:millisecond),
      "delayMs" => Application.get_env(:smalt, :lro_delay_ms, 0)
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
      {:ok, %{"status" => "InProgress"} = record} -> {:ok, evaluate(record)}
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

      other ->
        other
    end
  end

  # Pure function of the record + clock: flips the status when the delay has
  # fully elapsed and persists the terminal record.
  defp evaluate(%{"startedAtMs" => started, "delayMs" => delay} = record) do
    if System.system_time(:millisecond) - started >= delay do
      record =
        record
        |> Map.delete("startedAtMs")
        |> Map.delete("delayMs")
        |> Map.put("status", "Succeeded")
        |> Map.put("endTime", now_iso())

      :ok = Store.put(:smalt_operations, record["name"], record)
      record
    else
      record
    end
  end

  # A record missing scheduling fields (e.g. hand-seeded) is already terminal.
  defp evaluate(record), do: record

  defp subscription_of("/subscriptions/" <> rest) do
    [sub | _] = String.split(rest, "/")
    sub
  end

  defp subscription_of(_), do: "00000000-0000-0000-0000-000000000000"

  defp now_iso do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end
end
