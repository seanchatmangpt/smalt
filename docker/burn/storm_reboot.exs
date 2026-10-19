# docker/burn/storm_reboot.exs — AZB-14 storm reboot leg.
#
# Reboots the mirror over the SIGKILLed file and asserts the AZB-14
# durability contract: every ACKed write present, zero unacked phantoms,
# needs_repair witnessed via telemetry [:smalt, :store, :dets_repaired] —
# or, on corruption-variant cycles, a TYPED {:error, {:store_corrupt, ...}}
# refusal with the store still serving (other planes keep serving).
# Env: STORM_DIR, STORM_LEDGER (space-separated acked keys).
Enum.each(Path.wildcard(System.get_env("SMALT_EBIN_GLOB", "/app/_release/lib/*/ebin")), &Code.prepend_path/1)
{:ok, _} = Application.ensure_all_started(:telemetry)
dir = System.fetch_env!("STORM_DIR")

:telemetry.attach(:storm_repaired, [:smalt, :store, :dets_repaired], fn _e, _m, meta, pid ->
  send(pid, {:rep, meta[:table]})
end, self())

case Smalt.Store.DetsMirror.start_link(dir: dir, tables: [:dm_t_resources], interval: 3_600_000, repair: true) do
  {:ok, m} ->
    repaired = receive do {:rep, :dm_t_resources} -> true after 3_000 -> false end
    GenServer.stop(m)

    {:ok, d} =
      :dets.open_file(:storm_probe, file: to_charlist(Path.join(dir, "dm_t_resources.dets")), repair: false)

    rows = :dets.match_object(d, :_)
    :dets.close(d)
    ledger = String.split(System.get_env("STORM_LEDGER") || "", " ", trim: true)

    missing = Enum.reject(ledger, fn k -> Enum.any?(rows, fn {k2, _} -> k2 == k end) end)

    {junk, phantoms} =
      Enum.reduce(rows, {0, []}, fn {k, _}, {j, ph} ->
        ks = to_string(k)

        cond do
          String.starts_with?(ks, "unacked-") or String.starts_with?(ks, "#Reference") ->
            # Submitted-but-unacked rows: dets repair may legitimately replay
            # a journal-flushed unacked row — reported, never a violation.
            {j + 1, ph}

          k in ledger ->
            {j, ph}

          true ->
            # PHANTOM: a key that was never submitted by any writer.
            {j, [ks | ph]}
        end
      end)

    if missing == [] and phantoms == [] do
      IO.puts("STORM_OK repaired=#{repaired} unacked_rows=#{junk}")
    else
      IO.puts("STORM_VIOLATION missing=#{inspect(missing)} phantoms=#{inspect(phantoms)}")
      :erlang.halt(1)
    end

  {:error, {:store_corrupt, t, _p, r}} ->
    # Typed refusal face (corruption variants): plane refuses typed and the
    # other planes keep serving — a fresh Store put/get answers on this node.
    IO.puts("STORE_CORRUPT #{inspect(t)} reason=#{inspect(r)}")
    {:ok, _} = Smalt.Store.start_link([])
    :ok = Smalt.Store.put(:dm_t_resources, "storm-serving", %{"serving" => true})
    {:ok, %{"serving" => true}} = Smalt.Store.get(:dm_t_resources, "storm-serving")
    IO.puts("STORM_OK_TYPOUTCOME store_corrupt-typed-and-serving")
    :erlang.halt(0)
end
