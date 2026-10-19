defmodule Smalt.StoreDetsGrowthTest do
  @moduledoc """
  Bounded-growth census for the DetsMirror union write path (WRAP_LEDGER park).

  `sync_all/1` used a bare `:dets.insert(dets_file, :ets.tab2list(table))` —
  an upsert-by-key union. Falsifiers proven here:

    1. Distinct-key growth: delete a key from ETS, sync, and the mirror still
       holds the row. Over time the mirror is the set of ALL keys ever seen,
       not the live set — unbounded, and restore resurrects deleted rows.
    2. Same-key-set idempotence: repeated syncs over an unchanged key set must
       not multiply rows.

  Fence: mirror size must equal live ETS size after every sync (mirror is a
  projection of the live table, not a historical union).
  """

  use ExUnit.Case, async: false

  @table :dm_growth_t

  setup do
    dir = Path.join(System.tmp_dir!(), "smalt_dets_growth_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn ->
      File.rm_rf!(dir)
    end)

    if :ets.info(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table])
    end

    :ets.delete_all_objects(@table)

    {:ok, pid} =
      Smalt.Store.DetsMirror.start_link(dir: dir, tables: [@table], interval: 3_600_000)

    %{dir: dir, pid: pid}
  end

  defp dets_rows(dir) do
    {:ok, d} = :dets.open_file(:growth_probe, file: ~c"#{dir}/#{@table}.dets", repair: false)
    n = :dets.info(d, :size)
    keys = MapSet.new(:dets.match_object(d, :_), fn {k, _} -> k end)
    :dets.close(d)
    {n, keys}
  end

  test "census: deleted keys leave the mirror (row count tracks live keys)", %{dir: dir, pid: pid} do
    n = 200
    keys = Enum.map(1..n, &"/growth/#{String.pad_leading(Integer.to_string(&1), 4, "0")}")

    :ets.insert(@table, Enum.map(keys, &{&1, %{"i" => &1}}))
    Smalt.Store.DetsMirror.sync(pid)
    {after_sync, _} = dets_rows(dir)
    assert after_sync == n

    # Delete half the live keys, sync again: the mirror must shrink to the
    # live set. Pre-fix union behavior pins it at n (stale rows leak forever).
    Enum.each(Enum.take(keys, div(n, 2)), &:ets.delete(@table, &1))
    assert :ets.info(@table, :size) == n - div(n, 2)

    Smalt.Store.DetsMirror.sync(pid)
    {after_delete, mirror_keys} = dets_rows(dir)

    live_keys = MapSet.new(:ets.tab2list(@table), fn {k, _} -> k end)

    assert after_delete == n - div(n, 2), """
    mirror row count #{after_delete} != live key count #{n - div(n, 2)} after delete+sync:
    #{after_delete - (n - div(n, 2))} stale row(s) leaked — the union write path is unbounded.
    """

    assert MapSet.equal?(mirror_keys, live_keys), "mirror is not a projection of the live set"

    # A restore after the deletes must not resurrect deleted keys.
    :ets.delete_all_objects(@table)
    {:ok, counts} = Smalt.Store.DetsMirror.restore(pid)
    assert counts[@table] == n - div(n, 2)
    assert :ets.info(@table, :size) == n - div(n, 2)
  end

  test "census: union over the SAME key set repeatedly does not multiply rows", %{
    dir: dir,
    pid: pid
  } do
    keys = Enum.map(1..50, &"/idem/#{&1}")
    :ets.insert(@table, Enum.map(keys, &{&1, %{"v" => &1}}))

    sizes =
      for _ <- 1..5 do
        Smalt.Store.DetsMirror.sync(pid)
        {n, _} = dets_rows(dir)
        n
      end

    assert Enum.uniq(sizes) == [50], "row multiplication across syncs: #{inspect(sizes)}"
  end
end
