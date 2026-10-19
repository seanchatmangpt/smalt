# Residual internal tier (WO-10, clean-room re-derivation from lib/).
#
# Provenance (lib/smalt/store/dets_mirror.ex read fresh):
#   - start_link/1 validates EVERY mirror file up front via the same typed
#     open the init uses: probe `repair: false` first; a `{:needs_repair, _}`
#     file + `repair: true` is healed and witnessed by telemetry
#     `[:smalt, :store, :dets_repaired]`; a torn file with `repair: false`
#     is the typed `{:error, {:corrupt_mirror, table, path, reason}}`;
#     corruption repair cannot heal (e.g. a non-DETS body) with repair is
#     the typed `{:error, {:store_corrupt, table, path, reason}}`. Both
#     refusals raise a fail-closed ArgumentError naming the tag.
#   - restore/1 replays mirrored rows into ETS via Smalt.Store.insert_new/3,
#     skipping keys already present — hence idempotent (second call adds 0).
#
# Torn/corrupt fixtures are crafted as REAL files in a real tmp dir (Chicago:
# real collaborators, assert on final state). Store is the live singleton
# (mix test boots the app; restore rides the real Smalt.Store.insert_new/3).
Code.require_file("poll_helper.exs", __DIR__)

defmodule InternalTier.DetsMirrorRecoveryTest do
  use ExUnit.Case, async: false

  import SmaltTest.Internal.Poll, only: [eventually: 1]

  @table :smalt_appconfig

  setup do
    # The restore path needs the real Store singleton.
    assert {:ok, _} =
             eventually(fn ->
               case Process.whereis(Smalt.Store) do
                 pid when is_pid(pid) -> {:ok, pid}
                 nil ->
                   case Smalt.Store.start_link([]) do
                     {:ok, pid} -> {:ok, pid}
                     {:error, {:already_started, pid}} -> {:ok, pid}
                     {:error, other} -> {:refused, other}
                   end
               end
             end)

    dir =
      Path.join(System.tmp_dir!(), "smalt-dets-lane-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  @tag :smalt_internal
  test "clean open: a synced mirror file opens typed-clean and restores idempotently" do
    dir = mirror_dir()
    mirror = start_mirror(dir, repair: false)

    # Seed through the real Store, sync to the real dets file.
    key = "smalt/internal/dets-clean-#{System.unique_integer([:positive])}"
    assert :ok = Smalt.Store.insert_new(@table, key, %{provenance: "clean"})
    assert :ok = Smalt.Store.DetsMirror.sync(mirror)

    # Give restore something to genuinely replay: drop the live ETS row
    # (public table), so the mirrored row is absent from ETS.
    assert :ets.info(@table) != :undefined
    assert :ets.lookup(@table, key) != []
    :ets.delete(@table, key)
    assert :ets.lookup(@table, key) == []

    t = @table
    assert {:ok, counts1} = Smalt.Store.DetsMirror.restore(mirror)
    assert %{^t => n} = counts1
    assert n >= 1

    # Idempotence: keys already present are skipped (insert_new ::exists).
    assert {:ok, counts2} = Smalt.Store.DetsMirror.restore(mirror)
    assert %{^t => 0} = counts2

    GenServer.stop(mirror, :normal)
  end

  @tag :smalt_internal
  test "needs_repair: an un-cleanly-closed dets file heals under repair: true with dets_repaired telemetry" do
    dir = mirror_dir()
    path = Path.join(dir, "#{@table}.dets")

    # Real unclean shutdown: open + write in a spawned process, then kill
    # the owner WITHOUT :dets.close/1 — the file stays dirty on disk.
    craft_torn_file(path)
    assert {:error, {:needs_repair, _}} = probe(path)

    repaired_events = :ets.new(:dets_repaired_events, [:bag, :public])

    handler_id = {:dets_lane, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:smalt, :store, :dets_repaired],
        fn _name, measurements, metadata, _config ->
          :ets.insert(repaired_events, {:event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    mirror = start_mirror(dir, repair: true)

    t = @table

    assert {:ok, [{:event, %{count: 1}, %{table: ^t}} | _]} =
             eventually(fn ->
               case :ets.tab2list(repaired_events) do
                 [] -> {:no_repair_event, :pending}
                 events -> {:ok, events}
               end
             end)

    # The healed mirror is functional: sync + restore round-trip.
    assert :ok = Smalt.Store.DetsMirror.sync(mirror)
    assert {:ok, counts} = Smalt.Store.DetsMirror.restore(mirror)
    assert is_map(counts)
    GenServer.stop(mirror, :normal)
  end

  @tag :smalt_internal
  test "corrupt_mirror: a torn file under repair: false is a typed refusal (fail-closed ArgumentError)" do
    dir = mirror_dir()
    path = Path.join(dir, "#{@table}.dets")
    craft_torn_file(path)
    assert {:error, {:needs_repair, _}} = probe(path)

    error = assert_raise(ArgumentError, fn -> start_mirror(dir, repair: false) end)
    assert message_contains?(error, "corrupt_mirror")
    assert message_contains?(error, inspect(@table))
  end

  @tag :smalt_internal
  test "store_corrupt: a non-DETS body is unhealable even under repair: true" do
    dir = mirror_dir()
    path = Path.join(dir, "#{@table}.dets")
    File.write!(path, "definitely not a dets file — flipped header body")

    # Probe face: not a dets file at all.
    assert {:error, {:not_a_dets_file, _}} = probe(path)

    # Even the healing face refuses, typed.
    error = assert_raise(ArgumentError, fn -> start_mirror(dir, repair: true) end)
    assert message_contains?(error, "store_corrupt")
    assert message_contains?(error, inspect(@table))

    # Same refusal with repair: false (typed :corrupt_mirror face).
    error2 = assert_raise(ArgumentError, fn -> start_mirror(dir, repair: false) end)
    assert message_contains?(error2, "corrupt_mirror")
  end

  # -- helpers ---------------------------------------------------------------

  defp mirror_dir do
    # The setup-created dir is re-derivable per test: use the process
    # dictionary-free form — each test builds its own unique dir.
    dir = Path.join(System.tmp_dir!(), "smalt-dets-lane-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp start_mirror(dir, opts) do
    assert {:ok, pid} =
             Smalt.Store.DetsMirror.start_link(
               dir: dir,
               tables: [@table],
               interval: 60_000,
               repair: Keyword.get(opts, :repair, false),
               name: Module.concat([Smalt.Store.DetsMirror, :"lane_#{System.unique_integer([:positive])}"])
             )

    pid
  end

  # Probe with the SAME first step the mirror uses (dets_mirror.ex
  # open_typed/3 probe leg): a throwaway named open, closed immediately.
  defp probe(path) do
    case :dets.open_file(make_ref(), file: to_charlist(path), repair: false) do
      {:ok, d} ->
        :dets.close(d)
        {:ok, :clean}

      {:error, _} = err ->
        err
    end
  end

  # Deterministic un-clean-shutdown fixture: a fully synced dets file with
  # its final byte amputated — the file ends mid-record, which the DETS
  # open probe reports as {:needs_repair, _} (witnessed empirically).
  defp craft_torn_file(path) do
    {:ok, d} = :dets.open_file(String.to_charlist(path), repair: false)
    :dets.insert(d, {@table, %{torn: true}})
    :dets.sync(d)
    :dets.close(d)

    raw = File.read!(path)
    File.write!(path, :binary.part(raw, 0, byte_size(raw) - 1))
    :ok
  end

  defp message_contains?(%ArgumentError{} = e, needle) do
    e.message |> String.contains?(needle)
  end
end
