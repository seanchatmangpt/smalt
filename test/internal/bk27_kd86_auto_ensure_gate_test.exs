# KD-COVERS: KD-86 — send-path auto-ensure gate (BK-27 fix/verify lane).
#
# Chicago discipline: real ETS store, real QueueStore server, real enqueue
# pipeline. No mocks. The falsifier is the gate itself:
#
#   flag off (default)  → enqueue to a never-created queue answers
#                         {:error, :messaging_entity_not_found} and the
#                         entity row is NOT created (no silent creation).
#   flag on             → legacy emulator convenience restored: the enqueue
#                         succeeds and the entity row IS created.
#
# Wire face: verification/ts/kd86.probe.cjs (amqp:not-found detach) and the
# workspace court (servicebus_dataplane.test.ts test 07, SDK-typed
# MessagingEntityNotFoundError).
defmodule InternalTier.Bk27Kd86AutoEnsureGateTest do
  use ExUnit.Case, async: false

  alias Smalt.Amqp.QueueStore

  test "KD-86: flag off (default) refuses send to never-created queue, no silent creation" do
    Application.put_env(:smalt, :sb_auto_ensure, false)

    name = "kd86-refused-#{System.system_time()}"
    assert {:error, :messaging_entity_not_found} = QueueStore.enqueue(name, "x")
    assert :error = QueueStore.queue_info(name)
  end

  test "KD-86: flag on restores auto-create-on-send" do
    Application.put_env(:smalt, :sb_auto_ensure, true)

    name = "kd86-auto-#{System.system_time()}"
    assert {:ok, _} = QueueStore.enqueue(name, "x")
    assert {:ok, _info} = QueueStore.queue_info(name)
  after
    Application.put_env(:smalt, :sb_auto_ensure, false)
  end

  test "KD-86: send to an ARM-created queue is unaffected by the gate" do
    Application.put_env(:smalt, :sb_auto_ensure, false)

    name = "kd86-arm-q-#{System.system_time()}"
    assert {:ok, _} = QueueStore.ensure_queue(name)
    assert {:ok, _seq} = QueueStore.enqueue(name, "x")
  after
    Application.put_env(:smalt, :sb_auto_ensure, false)
  end
end
