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

  defp lookup_val(table, key) do
    case :ets.lookup(table, key) do
      [{^key, val}] -> {:ok, val}
      [] -> :error
    end
  end
end
