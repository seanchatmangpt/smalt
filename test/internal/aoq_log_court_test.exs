# v26.11.6 L6 — AoQ durable log face court. Chicago discipline: real
# PartitionLog engine over the shared ETS instance, real JournalSink
# segments on disk, real named-GenServer restart + sealed replay. No mocks.
# In-process (:internal class). Context: solo (in-process log faces).
defmodule SmaltTest.Internal.AoqLogCourtTest do
  use ExUnit.Case, async: false

  @topic Smalt.Aoq.Storage.topic()
  @server Smalt.Aoq.Storage.Server

  # Bounded poll on a real observable (no-sleep doctrine; poll on the
  # supervisor-restarted server pid + restored offsets).
  import SmaltTest.AssertEventually, only: [assert_eventually: 1]

  # -- isolation: snapshot/restore the AoQ topic's rows on the SHARED tables --

  defp snapshot do
    keys =
      :ets.tab2list(:smalt_kafka_batches)
      |> Enum.filter(fn {{t, _p, _b}, _} -> t == @topic end)
      |> Enum.map(fn {k, _} -> k end)

    next =
      :ets.tab2list(:smalt_kafka_next)
      |> Enum.filter(fn {{t, _p}, _} -> t == @topic end)

    %{keys: keys, next: next}
  end

  defp restore(%{keys: keys, next: next}) do
    Enum.each(:ets.tab2list(:smalt_kafka_batches), fn {k, _} ->
      case k do
        {t, _p, _b} when t == @topic -> :ets.delete(:smalt_kafka_batches, k)
        _ -> :ok
      end
    end)

    Enum.each(next, fn kv -> :ets.insert(:smalt_kafka_next, kv) end)

    keys_next =
      :ets.tab2list(:smalt_kafka_next)
      |> Enum.filter(fn {{t, _p}, _} -> t == @topic end)
      |> Enum.map(fn {k, _} -> k end)

    Enum.each(keys_next -- Enum.map(next, fn {k, _} -> k end), fn k ->
      :ets.delete(:smalt_kafka_next, k)
    end)
  end

  setup do
    # full-suite order robustness: an earlier suite segment may have stopped
    # the tree (integration stop/restart tests); the named server re-creates
    # its tables at init, and this court re-ensures them idempotently here.
    Smalt.Messaging.PartitionLog.ensure_tables(
      batches: :smalt_kafka_batches,
      next: :smalt_kafka_next
    )

    snap = snapshot()
    on_exit(fn -> restore(snap) end)
    %{}
  end

  # -- (a) encode -> append -> fetch byte-exact ---------------------------------

  test "append -> fetch payload byte-exact; offsets hwm; typed refusals" do
    p1 = "aoq-court-" <> Integer.to_string(System.unique_integer([:positive]))
    p2 = "aoq-court-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, off1} = Smalt.Aoq.Storage.append(0, p1)
    assert {:ok, off2} = Smalt.Aoq.Storage.append(1, p2)
    assert is_integer(off1) and is_integer(off2)

    {:ok, entries} = Smalt.Aoq.Storage.fetch(@topic, 0)
    payloads = Enum.map(entries, & &1.payload)

    assert p1 in payloads, "append 1 payload not served byte-exact"
    assert p2 in payloads, "append 2 payload not served byte-exact"

    # frame-type byte = partition face; both partitions advanced.
    assert {:ok, offs} = Smalt.Aoq.Storage.offsets(@topic)
    assert is_map(offs) and map_size(offs) >= 1
    assert Enum.all?(Map.values(offs), &is_integer/1)

    # typed refusals
    assert {:error, :unknown_partition} = Smalt.Aoq.Storage.offsets("aoq-nope-topic")
    assert {:error, :unknown_partition} = Smalt.Aoq.Storage.fetch("aoq-nope-topic", 0)
    assert {:error, {:offset_overflow, hwm}} = Smalt.Aoq.Storage.fetch(@topic, 99_999_999)
    assert is_integer(hwm)
    assert {:error, :empty_payload} = Smalt.Aoq.Storage.append(0, <<>>)
    assert {:error, :bad_frame_type} = Smalt.Aoq.Storage.append(256, "x")
  end

  # -- (b) restart + sealed replay restores --------------------------------------

  test "restart with same dir: sealed replay restores payloads byte-exact" do
    payloads = [
      "aoq-replay-a-" <> Integer.to_string(System.unique_integer([:positive])),
      "aoq-replay-b-" <> Integer.to_string(System.unique_integer([:positive])),
      "aoq-replay-c-" <> Integer.to_string(System.unique_integer([:positive]))
    ]

    [a, b, c] = payloads

    appends = [
      Smalt.Aoq.Storage.append(0, a),
      Smalt.Aoq.Storage.append(1, b),
      Smalt.Aoq.Storage.append(0, c)
    ]

    assert Enum.all?(appends, fn r -> match?({:ok, _}, r) end)

    {:ok, before} = Smalt.Aoq.Storage.fetch(@topic, 0)
    offsets_before = Map.new(before, fn e -> {e.payload, e.offset} end)

    # seal the AoQ journal so the restart replays real sealed segments
    assert %{"frames" => _} = Smalt.Storage.JournalSink.seal(Smalt.Aoq.LogSink)

    pid = Process.whereis(@server)
    Process.exit(pid, :kill)

    # bounded poll on the real observable: restarted server + restored log
    assert_eventually(fn ->
      case Process.whereis(@server) do
        nil ->
          false

        restarted when restarted != pid ->
          {:ok, entries} = Smalt.Aoq.Storage.fetch(@topic, 0)
          Enum.all?(payloads, fn p -> p in Enum.map(entries, & &1.payload) end)

        _same_pid ->
          false
      end
    end)

    {:ok, after_entries} = Smalt.Aoq.Storage.fetch(@topic, 0)
    # replay law: each payload keeps its pre-restart offset (serve-order
    # replay reproduces the append-order offsets deterministically)
    assert Enum.all?(payloads, fn p ->
             Map.fetch!(offsets_before, p) == Enum.find_value(after_entries, fn e ->
               if e.payload == p, do: e.offset
             end)
           end)
  end
end
