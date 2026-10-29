defmodule Smalt.Impl25.SelectiveDrainTest do
  @moduledoc """
  IMPL-25 Chicago court (Armstrong tenet 5, selective drain): the LRO
  Notifier coalesces duplicate `{:due_check, op_id}` messages under a burst.

  Real collaborators only — the real supervised `Smalt.ArmGateway.LRO.Notifier`
  and `Smalt.ArmGateway.LRO.Sweeper` (single terminal writer) process a real
  10k-message flood on the real `:smalt_operations` store; assertions are on
  final state (waiter woken with the terminal record, store terminal, queue
  drained), verified by bounded poll (`SmaltTest.Internal.Poll`), never a
  sleep.

  Poll staging law (witnessed flake F-impl25-1): the waiter-wake message is
  one-shot and is consumed by the receiving poll, so it is polled ALONE
  (stage 1); the monotone observations (store terminal, queue drained) are
  polled separately afterwards (stage 2). A conjunctive poll whose first
  clause consumes the message can lose it when a later clause fails at that
  instant.
  """

  use ExUnit.Case, async: false

  Code.require_file("poll_helper.exs", __DIR__)

  alias Smalt.ArmGateway.LRO.Notifier
  alias Smalt.Store

  @flood 10_000

  setup do
    pid = GenServer.whereis(Notifier)
    assert pid, "LRO Notifier must be running (app self-boots under mix test)"
    {:ok, pid: pid}
  end

  defp in_progress_record(op) do
    %{
      "id" => "/subscriptions/00000000-0000-0000-0000-000000000000/operations/#{op}",
      "name" => op,
      "status" => "InProgress",
      "startTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "endTime" => nil,
      "resourceId" =>
        "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Smalt/impls/impl25",
      "startedAtMs" => System.system_time(:millisecond) - 60_000,
      "delayMs" => 0
    }
  end

  # One-shot receive: consumes the wake message iff present. ONLY safe as the
  # sole condition of its own bounded poll (see module doc).
  defp await_terminal(op) do
    receive do
      {:lro_terminal, ^op, record} -> {:ok, record}
    after
      0 -> :none
    end
  end

  defp qlen(notifier) do
    case :erlang.process_info(notifier, :message_queue_len) do
      {:message_queue_len, n} -> n
      nil -> :dead
    end
  end

  test "10k due-check burst on one op converges to terminal with the queue drained" do
    op = "impl25-drain-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    :ok = Store.put(:smalt_operations, op, in_progress_record(op))

    assert {:ok, ref, nil} = Notifier.register(op, nil)

    # Real burst: 10k duplicate due-check messages into the live Notifier
    # mailbox, after the registration's own one-shot timer.
    notifier = GenServer.whereis(Notifier)
    for _ <- 1..@flood, do: send(notifier, {:due_check, op})

    # Stage 1 (consuming, sole condition): the waiter wakes on the terminal
    # signal — routed through the real Notifier -> Sweeper single-writer path.
    assert {:ok, record} =
             SmaltTest.Internal.Poll.eventually(
               fn -> await_terminal(op) end,
               timeout_ms: 10_000
             )

    # Stage 2 (non-consuming, monotone): store terminal + queue fully drained.
    assert {:ok, stored} =
             SmaltTest.Internal.Poll.eventually(
               fn ->
                 case Store.get(:smalt_operations, op) do
                   {:ok, %{"status" => s}} when is_binary(s) and s != "InProgress" ->
                     if qlen(notifier) == 0, do: {:ok, s}, else: :continue

                   _ ->
                     :continue
                 end
               end,
               timeout_ms: 10_000
             )

    assert record["name"] == op
    assert is_binary(record["status"]) and record["status"] != "InProgress"
    assert is_binary(stored)

    # the waiter entry was retired by the wake path: unregister is a typed
    # no-op (:ok) rather than a crash — the registry converged, not wedged.
    assert :ok = Notifier.unregister(op, ref)
  end

  test "drain is selective: a different op's due-check survives the flood and still wakes its waiter" do
    op = "impl25-drain-a-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    other = "impl25-drain-b-" <> Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    :ok = Store.put(:smalt_operations, op, in_progress_record(op))
    :ok = Store.put(:smalt_operations, other, in_progress_record(other))

    assert {:ok, _ref_a, nil} = Notifier.register(op, nil)
    assert {:ok, _ref_b, nil} = Notifier.register(other, nil)

    notifier = GenServer.whereis(Notifier)
    for _ <- 1..@flood, do: send(notifier, {:due_check, op})
    # exactly ONE message for the other op inside the flood window
    send(notifier, {:due_check, other})

    # Stage 1 (consuming, one condition at a time): BOTH waiters wake — the
    # 10k a-flood was drained as duplicates, and b's lone check was NOT.
    assert {:ok, a_rec} =
             SmaltTest.Internal.Poll.eventually(fn -> await_terminal(op) end,
               timeout_ms: 10_000
             )

    assert {:ok, b_rec} =
             SmaltTest.Internal.Poll.eventually(fn -> await_terminal(other) end,
               timeout_ms: 10_000
             )

    # Stage 2 (non-consuming): queue fully drained.
    assert {:ok, :drained} =
             SmaltTest.Internal.Poll.eventually(
               fn ->
                 if qlen(notifier) == 0, do: {:ok, :drained}, else: :continue
               end,
               timeout_ms: 10_000
             )

    assert a_rec["name"] == op and is_binary(a_rec["status"])
    assert b_rec["name"] == other and is_binary(b_rec["status"])
  end
end
