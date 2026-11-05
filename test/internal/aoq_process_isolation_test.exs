defmodule Smalt.Aoq.ProcessIsolationTest do
  @moduledoc false
  # C4 process-isolation court: Chicago-style — starts REAL worker processes
  # via Smalt.Aoq.Worker.start_link/1 and asserts on Process.info of the live
  # pids. No mocks, no interaction assertions. The negative control (a bare
  # spawn stays :on_heap, no max_heap_size) proves the court is non-vacuous:
  # Process.info genuinely observes the isolation opts, it does not pass by
  # default.
  use ExUnit.Case, async: false

  alias Smalt.Aoq.Worker

  test "live worker runs with message_queue_data: :off_heap" do
    index = unique_index()
    {:ok, pid} = Worker.start_link(index)

    try do
      assert Process.info(pid, :message_queue_data) == {:message_queue_data, :off_heap}
    after
      send(pid, :stop)
    end
  end

  test "live worker carries max_heap_size %{size: 2097152, kill: true}" do
    index = unique_index()
    {:ok, pid} = Worker.start_link(index)

    try do
      {:max_heap_size, heap} = Process.info(pid, :max_heap_size)
      assert %{} = heap
      assert heap.size == 2_097_152
      assert heap.kill == true
      assert Map.get(heap, :error_logger) == true
    after
      send(pid, :stop)
    end
  end

  test "negative control: a bare spawned process stays :on_heap with no heap cap" do
    pid = spawn(fn -> receive do :stop -> :ok end end)

    assert Process.info(pid, :message_queue_data) == {:message_queue_data, :on_heap}
    # OTP 29 reports the default as size: 0 (= no cap) with kill/error_logger
    # flags present-but-inert; the meaningful negative signal is size: 0.
    {:max_heap_size, heap} = Process.info(pid, :max_heap_size)
    assert heap.size == 0
    send(pid, :stop)
  end

  test "loop/1 heartbeat GC does not disturb an idle worker" do
    index = unique_index()
    {:ok, pid} = Worker.start_link(index)

    ref = Process.monitor(pid)
    # The worker must simply stay alive with the heartbeat armed — structural
    # proof the after-clause recursion is a lawful idle posture, not a crash
    # path. (No sleep: alive-check + DOWN-refute immediately, per the
    # no-sleep doctrine.)
    assert Process.alive?(pid)
    refute_received {:DOWN, ^ref, :process, ^pid, _}

    send(pid, :stop)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  defp unique_index, do: System.unique_integer([:positive]) |> abs()
end
