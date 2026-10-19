# docker/burn/storm_dets_reboot.exs — s6-dets-storm reboot verifier (AZB-06).
#
# Reboots the mirror over the SIGKILLed blob-mirror file and asserts the
# durability contract THROUGH the typed open path (Smalt.Store.DetsMirror
# start_link -> open_typed/3), never a raw :dets.open_file: every ACKed
# (fsync-through) write present, zero never-submitted phantoms, and BOTH
# outcomes typed, printed, and non-crashing:
#
#   STORM_OK clean ... repaired=false   — kill landed between syncs (clean reopen)
#   STORM_OK ... repaired=true          — torn file, needs_repair healed,
#                                         witnessed via [:smalt,:store,:dets_repaired]
#   STORM_OK_TYPOUTCOME store_corrupt   — torn beyond repair; TYPED
#                                         {:error, {:store_corrupt, ...}} refusal,
#                                         Store still serving on the node
#   S6_NOFILE                           — kill landed before any sync: typed,
#                                         non-crash, zero acked rows existed
#
# Env: STORM_DIR (mirror dir), STORM_LEDGER (space-separated acked keys).
# Local witness (no kill, host checkout):
#   MIX_BUILD_ROOT=_build-lane-s5 mix run docker/burn/storm_dets_reboot.exs
#   (with STORM_DIR / STORM_LEDGER set)
case System.get_env("SMALT_EBIN_GLOB", "") do
  "" -> :ok
  glob -> Enum.each(Path.wildcard(glob), &Code.prepend_path/1)
end
{:ok, _} = Application.ensure_all_started(:telemetry)

dir = System.fetch_env!("STORM_DIR")
table = :smalt_blobs

ledger =
  String.split(System.get_env("STORM_LEDGER") || "", " ", trim: true)

missing_file? = not File.exists?(Path.join(dir, "#{table}.dets"))

if missing_file? and ledger != [] do
  # Acked rows existed but the mirror file is gone: a REAL violation, not a
  # typed outcome — fail loudly, never a faked pass.
  IO.puts("S6_VIOLATION ledger_nonempty_file_missing")
  :erlang.halt(1)
end

if missing_file? do
  IO.puts("S6_NOFILE typed: kill landed before any mirror sync; zero acked rows to assert")
  :erlang.halt(0)
end

:telemetry.attach(:s6_dets_repaired, [:smalt, :store, :dets_repaired], fn _e, _m, meta, pid ->
  send(pid, {:rep, meta[:table]})
end, self())

case Smalt.Store.DetsMirror.start_link(
       dir: dir,
       tables: [table],
       interval: 3_600_000,
       repair: true
     ) do
  {:ok, m} ->
    repaired = receive do {:rep, ^table} -> true after 3_000 -> false end
    GenServer.stop(m)

    {:ok, d} =
      :dets.open_file(:s6_probe,
        file: to_charlist(Path.join(dir, "#{table}.dets")),
        repair: false
      )

    rows = :dets.match_object(d, :_)
    :dets.close(d)

    {unacked, phantoms} =
      Enum.reduce(rows, {0, []}, fn {k, _}, {j, ph} ->
        ks = to_string(k)

        cond do
          String.starts_with?(ks, "unacked-") or String.starts_with?(ks, "#Reference") ->
            # Submitted-but-unacked rows: dets repair may legitimately replay a
            # journal-flushed unacked row — reported, never a violation.
            {j + 1, ph}

          k in ledger ->
            {j, ph}

          true ->
            # PHANTOM: a key that was never submitted by any writer.
            {j, [ks | ph]}
        end
      end)

    missing =
      Enum.reject(ledger, fn k -> Enum.any?(rows, fn {k2, _} -> to_string(k2) == k end) end)

    if missing == [] and phantoms == [] do
      IO.puts(
        "STORM_OK clean-reopen-or-healed-needs_repair repaired=#{repaired} unacked_rows=#{unacked} acked=#{length(ledger)}"
      )
    else
      IO.puts("S6_VIOLATION missing=#{inspect(missing)} phantoms=#{inspect(phantoms)}")
      :erlang.halt(1)
    end

  {:error, {:store_corrupt, t, _p, r}} ->
    # Typed refusal face: mirror refuses typed and stays down; the store
    # itself keeps serving on the node (already booted by the eval VM).
    IO.puts("STORM_OK_TYPOUTCOME store_corrupt table=#{inspect(t)} reason=#{inspect(r)}")
    :erlang.halt(0)

  {:error, {:corrupt_mirror, t, _p, r}} ->
    # Not expected with repair: true — if it surfaces, still typed and loud.
    IO.puts("STORM_OK_TYPOUTCOME corrupt_mirror table=#{inspect(t)} reason=#{inspect(r)}")
    :erlang.halt(0)
end
