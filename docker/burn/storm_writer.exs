# docker/burn/storm_writer.exs — AZB-14 storm writer VM (real SIGKILL subject).
#
# Writes 10 ACKed blob-mirror rows (fsync per write; each ACK on stdout is the
# client-side ledger), then junk unsynced rows, then an unacked stream until
# the storm's kill -9 lands. Env: STORM_DIR, STORM_CYCLE, STORM_JUNK.
#
# Durability contract under test: acked (fsynced) rows MUST survive the
# SIGKILL; unacked rows MUST be gone after the repair reboot (zero phantoms).
Enum.each(Path.wildcard(System.get_env("SMALT_EBIN_GLOB", "/app/_release/lib/*/ebin")), &Code.prepend_path/1)
dir = System.fetch_env!("STORM_DIR")
cycle = System.fetch_env!("STORM_CYCLE") |> String.to_integer()
junk = System.fetch_env!("STORM_JUNK") |> String.to_integer()

path = Path.join(dir, "dm_t_resources.dets")
{:ok, d} = :dets.open_file(:azb14_writer, file: to_charlist(path))

for i <- 1..10 do
  key = "storm-#{cycle}-ack-#{i}"
  :dets.insert(d, {key, %{"n" => i, "cycle" => cycle}})
  :ok = :dets.sync(d)
  IO.puts("ACK #{key}")
end

for _ <- 1..junk do
  :dets.insert(d, {inspect(make_ref()), 0})
end

IO.puts("ACKS_DONE")
IO.puts("JUNK_N #{junk}")

# Unacked stream: unsynced rows until the SIGKILL lands (bounded in time by
# the storm's kill, not by a sleep).
stream = fn f, n ->
  :dets.insert(d, {"unacked-#{n}", n})
  f.(f, n + 1)
end

stream.(stream, 1)
