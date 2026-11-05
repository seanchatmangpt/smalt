defmodule SmaltTest.Courts.OffsetJournalTest do
  use ExUnit.Case, async: false

  alias Smalt.Messaging.OffsetJournal

  @test_dir "tmp/test_offset_journal"

  setup do
    File.rm_rf!(@test_dir)
    File.mkdir_p!(@test_dir)

    # Stop any existing instance
    if Process.whereis(OffsetJournal), do: GenServer.stop(OffsetJournal)

    pid = case OffsetJournal.start_link(data_dir: @test_dir) do
      {:ok, p} -> p
      {:error, {:already_started, p}} -> p
    end
    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf!(@test_dir)
    end)
    {:ok, pid: pid}
  end

  test "commits offsets across multiple dialects and recovers after crash", %{pid: pid} do
    # Leg 1: Commit Kafka offset
    :ok = OffsetJournal.commit(:kafka, "test-group", "test-topic", 0, 100)
    assert {:ok, 100} = OffsetJournal.fetch(:kafka, "test-group", "test-topic", 0)

    # Leg 2: Commit Kinesis offset
    :ok = OffsetJournal.commit(:kinesis, "kinesis-group", "stream-1", 0, 500)
    assert {:ok, 500} = OffsetJournal.fetch(:kinesis, "kinesis-group", "stream-1", 0)

    # Leg 3: Commit GCP PubSub offset
    :ok = OffsetJournal.commit(:pubsub, "sub-group", "topic-sub", 0, 1200)
    assert {:ok, 1200} = OffsetJournal.fetch(:pubsub, "sub-group", "topic-sub", 0)

    # Leg 4: Crash recovery simulation - brutal kill of GenServer and restart
    Process.unlink(pid)
    Process.exit(pid, :kill)
    refute Process.alive?(pid)

    # Verify journal file exists on disk and has data
    journal_path = Path.join(@test_dir, "offsets.journal")
    assert File.exists?(journal_path)
    assert File.stat!(journal_path).size > 0

    # Start new instance pointing to same directory
    {:ok, new_pid} = OffsetJournal.start_link(data_dir: @test_dir)

    # Assert offsets are immediately restored from journal replay
    assert {:ok, 100} = OffsetJournal.fetch(:kafka, "test-group", "test-topic", 0)
    assert {:ok, 500} = OffsetJournal.fetch(:kinesis, "kinesis-group", "stream-1", 0)
    assert {:ok, 1200} = OffsetJournal.fetch(:pubsub, "sub-group", "topic-sub", 0)

    # Assert restore_kafka_offsets restores {{group, topic, partition}, offset}
    kafka_records = OffsetJournal.restore_kafka_offsets()
    assert {{"test-group", "test-topic", 0}, 100} in kafka_records

    GenServer.stop(new_pid)
  end
end
