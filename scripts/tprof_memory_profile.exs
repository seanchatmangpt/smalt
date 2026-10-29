# tprof_memory_profile.exs — AR-OBS-03 memory fence profiler (v26.10.21).
#
# Profiles ONE real cosmos put_doc (engine path, 288-byte payload) via
# `tprof:profile(fun, #{type => call_memory, report => return})` and prints a
# single OBS03 JSON line with the summed allocated words across the call tree.
# Run under mix (self-booted, ephemeral; no shared substrate):
#   MIX_BUILD_ROOT=_build-obsfence mix run scripts/tprof_memory_profile.exs
#
# Note (VAL-OBS receipt docs/jira/v26.10.21/receipts/val-ar-obs.md): under
# `mix run` the tprof ebin (tools-*/ebin) is NOT on the mix code path — add it
# manually below.

root = List.to_string(:code.root_dir())

tp_bin =
  case Path.wildcard(Path.join(root, "lib/tools-*/ebin")) do
    [bin | _] -> bin
    [] -> raise("tprof unavailable: no tools-*/ebin under " <> root)
  end

true = :code.add_path(String.to_charlist(tp_bin))

case Smalt.Store.start_link() do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

db = "memgate"
coll = "c1"
_ = Smalt.DataPlane.Cosmos.create_db(db)
_ = Smalt.DataPlane.Cosmos.create_collection(db, coll, %{"partitionKey" => %{"paths" => ["/pk"]}})
body = %{"id" => "d1", "pk" => "a", "payload" => String.duplicate("x", 256)}
headers = %{"x-ms-documentdb-partitionkey" => "[\"a\"]"}

# Warm-up create then un-profiled put so ETS/collection metadata allocation
# does not pollute the profiled transaction.
_ = Smalt.DataPlane.Cosmos.create_doc(db, coll, body, headers)
pre = Smalt.DataPlane.Cosmos.put_doc(db, coll, "d1", body, headers)

{:ok, 200, _body, _resp} = pre

prof = fn ->
  _ = Smalt.DataPlane.Cosmos.put_doc(db, coll, "d1", body, headers)
  :ok
end

{:ok, {:call_memory, results}} = :tprof.profile(prof, %{type: :call_memory, report: :return})

total = Enum.reduce(results, 0, fn {_m, _f, alloc, _a}, acc -> alloc + acc end)
top = results |> Enum.sort_by(fn {_, _, a, _} -> -a end) |> Enum.take(5)

{:ok, j} =
  Jason.encode(%{
    otp: to_string(:erlang.system_info(:otp_release)),
    rows: length(results),
    alloc_words: total,
    top:
      Enum.map(top, fn {m, f, ar, allocs} ->
        %{mfa: inspect({m, f, ar}), alloc_words: Enum.sum(Enum.map(allocs, fn {_, _c, w} -> w end))}
      end)
  })

IO.puts("OBS03 " <> j)
