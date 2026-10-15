defmodule Smalt.StoreDetsTest do
  use ExUnit.Case, async: false

  @tables [:dm_t_resources, :dm_t_docs]

  setup do
    dir = Path.join(System.tmp_dir!(), "smalt_dets_mirror_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    tables = @tables

    Enum.each(tables, fn table ->
      if :ets.info(table) == :undefined do
        :ets.new(table, [:ordered_set, :public, :named_table])
      end

      :ets.delete_all_objects(table)
    end)

    %{dir: dir, tables: tables}
  end

  test "mirror captures writes within interval + epsilon", %{dir: dir} do
    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: @tables, interval: 50)

    :ets.insert(:dm_t_resources, {"/r/a", %{"name" => "a"}})
    :ets.insert(:dm_t_docs, {"docs/1", %{"id" => 1}})

    # Wait past one full tick + epsilon
    Process.sleep(150)

    # Read the dets files directly (closed read) to prove rows hit disk
    {:ok, res} = :dets.open_file(:probe_res, file: ~c"#{dir}/dm_t_resources.dets", repair: false)
    rows_res = :dets.match_object(res, :_)
    :dets.close(res)
    assert {"/r/a", %{"name" => "a"}} in rows_res

    {:ok, docs} = :dets.open_file(:probe_docs, file: ~c"#{dir}/dm_t_docs.dets", repair: false)
    rows_docs = :dets.match_object(docs, :_)
    :dets.close(docs)
    assert {"docs/1", %{"id" => 1}} in rows_docs

    GenServer.stop(pid)
  end

  test "restore inserts rows after simulated table clear", %{dir: dir} do
    :ets.insert(:dm_t_resources, {"/r/a", %{"name" => "a"}})
    :ets.insert(:dm_t_resources, {"/r/b", %{"name" => "b"}})

    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: @tables, interval: 3_600_000)

    Smalt.Store.DetsMirror.sync(pid)

    # Simulate crash/loss: wipe the hot table
    :ets.delete_all_objects(:dm_t_resources)
    assert :ets.info(:dm_t_resources, :size) == 0

    {:ok, counts} = Smalt.Store.DetsMirror.restore(pid)
    assert counts[:dm_t_resources] == 2
    assert {:ok, %{"name" => "a"}} == lookup_val(:dm_t_resources, "/r/a")
    assert {:ok, %{"name" => "b"}} == lookup_val(:dm_t_resources, "/r/b")

    GenServer.stop(pid)
  end

  test "re-restore is idempotent and ETS stays source of truth", %{dir: dir} do
    :ets.insert(:dm_t_resources, {"/r/a", %{"name" => "hot"}})

    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: @tables, interval: 3_600_000)

    Smalt.Store.DetsMirror.sync(pid)

    # ETS row mutated after sync: restore must NOT clobber it
    :ets.insert(:dm_t_resources, {"/r/a", %{"name" => "hotter"}})

    {:ok, counts1} = Smalt.Store.DetsMirror.restore(pid)
    assert counts1[:dm_t_resources] == 0
    assert {:ok, %{"name" => "hotter"}} == lookup_val(:dm_t_resources, "/r/a")

    # Second restore after clear: same rows inserted exactly once
    :ets.delete_all_objects(:dm_t_resources)
    {:ok, counts2} = Smalt.Store.DetsMirror.restore(pid)
    assert counts2[:dm_t_resources] == 1
    {:ok, counts3} = Smalt.Store.DetsMirror.restore(pid)
    assert counts3[:dm_t_resources] == 0

    GenServer.stop(pid)
  end

  test "corrupt dets file fails start_link closed with clear error", %{dir: dir} do
    File.write!(Path.join(dir, "dm_t_resources.dets"), "not a dets file at all")

    assert_raise ArgumentError, ~r/cannot open mirror file.*dm_t_resources/i, fn ->
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: @tables, interval: 3_600_000)
    end
  end

  test "restore x insert_new churn: insert_new :ok implies the FRESH value wins (no stale clobber)",
       %{
         dir: dir
       } do
    table = :dm_t_resources
    n = 300
    clobbers = race_rounds(table, n, dir)

    assert clobbers == [], """
    stale clobber witnessed for #{length(clobbers)} key(s): #{inspect(Enum.take(clobbers, 5))}
    restore must never run a bare :ets.lookup+:ets.insert that can interleave
    with a concurrent insert_new — it must route through Smalt.Store.insert_new/3.
    """
  end

  # The lookup-vs-insert clobber window in a non-atomic restore is a few
  # nanoseconds wide; a single restore pass hits it only ~40% of the time
  # (measured on this court). So the court REPEATS the race: each round seeds a
  # fresh key namespace into the mirror, wipes the hot table, hammers
  # insert_new across the whole restore window, and checks the no-clobber
  # invariant, stopping at the first clobber. A non-atomic restore survives one
  # round with p~0.9 (measured ~67% suite kill over 12 rounds); the 36-round
  # budget puts mutant survival below ~2%.
  @max_rounds 250

  defp race_rounds(table, n, dir) do
    1..@max_rounds
    |> Enum.reduce_while([], fn round, acc ->
      case race_round(table, n, dir, round) do
        [] -> {:cont, acc}
        clobbers -> {:halt, clobbers}
      end
    end)
  end

  defp race_round(table, n, dir, round) do
    keys = Enum.map(1..n, &key(round, &1))
    stale = Enum.map(keys, &{&1, %{"gen" => "stale", "round" => round}})

    # Seed the mirror with STALE rows, then wipe the hot table (simulated crash)
    :ets.insert(table, stale)

    File.mkdir_p!(Path.join(dir, "round-#{round}"))

    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(
        dir: Path.join(dir, "round-#{round}"),
        tables: @tables,
        interval: 3_600_000
      )

    Smalt.Store.DetsMirror.sync(pid)
    :ets.delete_all_objects(table)

    # One racer per key, hammering FRESH insert_new attempts from spawn until
    # restore completes (a fixed attempt count let the non-atomic mutant
    # survive because racers finished before restore reached their key).
    done = :atomics.new(1, signed: false)

    racers =
      for i <- 1..n do
        Task.async(fn ->
          fresh = %{"gen" => "fresh", "round" => round, "i" => i}
          k = key(round, i)

          oks =
            Stream.repeatedly(fn -> Smalt.Store.insert_new(table, k, fresh) end)
            |> Enum.take_while(fn _ -> :atomics.get(done, 1) == 0 end)
            |> Enum.count(&match?(:ok, &1))

          {k, oks}
        end)
      end

    {:ok, counts} =
      try do
        Smalt.Store.DetsMirror.restore(pid)
      after
        :atomics.put(done, 1, 1)
      end

    results = Task.await_many(racers, 60_000)
    GenServer.stop(pid)

    # Invariant: any key some racer WON (>=1 :ok) must hold the FRESH payload.
    for {k, oks} <- results,
        oks > 0,
        {^k, val} <- :ets.lookup(table, k),
        val["gen"] != "fresh" do
      k
    end
  end

  defp lookup_val(table, key) do
    case :ets.lookup(table, key) do
      [{^key, val}] -> {:ok, val}
      [] -> :error
    end
  end

  defp key(round, i), do: "/churn/r#{round}/#{String.pad_leading(Integer.to_string(i), 4, "0")}"
end
