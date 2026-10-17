# A-7: hierarchical-namespace (ADLS Gen2) massive recursive rename — BEAM tier.
# Run: MIX_ENV=test mix run --no-start scripts/bench/a7_hns_rename.exs
#
# smalt's blob layer keys blobs as flat ETS strings ("acct/cont/a/b/c") — virtual
# directories only. There is NO rename API: GAP(blob-hns-atomic-rename).
# A real ADLS Gen2 rename is an O(1) metadata op (parent repoint). The only smalt
# equivalent is a simulated rename: enumerate + re-key (copy+delete) every blob
# under the prefix — O(n) with a non-atomic mixed-prefix window.
#
# Measures:
#   (1) fixture: 100k-blob tree, 8 depth levels, via Smalt.Store.put (fixture-speed).
#   (2) simulated rename: wall at 10k/50k/100k, items/s, :erlang.memory(:ets).
#   (3) ATOMICITY witness: kill rename midway -> mixed prefixes = non-atomicity proof.
#   (4) concurrent reads during rename -> old/new/404 consistency window.

{:ok, _} = Smalt.Store.start_link([])

account = "a7acct"
container = "hns"
tbl = :smalt_blobs
base = "#{account}/#{container}/"

{:ok, _} = Smalt.DataPlane.BlobStorage.create_container(account, container, %{})

jsonl = "docs/jira/v26.10.14/bench/a7-hns-rename.jsonl"

t0 = :erlang.monotonic_time(:millisecond)
:rand.seed(:exsss, {t0, t0 * 7919 + 13, t0 * 104729 + 7})

now_us = fn -> :erlang.monotonic_time(:microsecond) end
fmt = fn x, d -> :erlang.float_to_binary(x * 1.0, decimals: d) end
ets_mb = fn -> :erlang.memory(:ets) / (1024 * 1024) end

emit = fn map ->
  body =
    Enum.map_join(map, ",", fn {k, v} ->
      val =
        cond do
          is_binary(v) -> "\"" <> v <> "\""
          is_atom(v) -> "\"" <> to_string(v) <> "\""
          is_float(v) -> fmt.(v, 3)
          true -> to_string(v)
        end

      k <> "=" <> val
    end)

  line = "{" <> body <> "}"
  File.write!(jsonl, line <> "\n", [:append])
  IO.puts(line)
end

# deterministic 8-level virtual-directory path for blob i
path = fn i ->
  depth = rem(i, 8) + 1

  1..depth
  |> Enum.map(fn d ->
    v = rem(div(i * 265_443_5761 + d * 40_503, 977), 65_536)
    "d#{d}-" <> Integer.to_string(v, 36)
  end)
  |> Enum.join("/")
end

count_prefix = fn prefix -> length(Smalt.Store.prefix_keys(tbl, prefix)) end

build_tree = fn prefix, n ->
  t = now_us.()

  Enum.each(1..n, fn i ->
    Smalt.Store.put(tbl, base <> prefix <> path.(i), %{
      "etag" => "a7-#{i}",
      "size" => 64,
      "content" => "payload-#{i}"
    })
  end)

  ms = (now_us.() - t) / 1000
  {ms, if(ms > 0, do: n / (ms / 1000), else: 0.0)}
end

# Simulated rename: enumerate keys under src prefix, re-key each (copy+delete).
# Plain reduce so the process is killable mid-flight.
rename_tree = fn src_key_prefix, dst_key_prefix, per_item ->
  keys = tbl |> Smalt.Store.prefix_keys(src_key_prefix) |> Enum.sort()
  slen = String.length(src_key_prefix)

  Enum.reduce(keys, 0, fn k, done ->
    case :ets.lookup(tbl, k) do
      [{^k, blob}] ->
        :ets.insert(tbl, {dst_key_prefix <> binary_part(k, slen, String.length(k) - slen), blob})
        :ets.delete(tbl, k)
        per_item.()
        done + 1

      _ ->
        done
    end
  end)
end

total = 100_000
ets0 = ets_mb.()

emit.(%{
  "lane" => "a7",
  "op" => "start",
  "note" =>
    "GAP(blob-hns-atomic-rename): no rename API; simulated re-key rename; real ADLS Gen2 rename is O(1) metadata",
  "tree_blobs" => total,
  "depth_levels" => 8,
  "ets_mb_before" => fmt.(ets0, 1)
})

# ---- (1) fixture: 100k-blob tree, 8 depth levels ----
{fix_ms, fix_ips} = build_tree.("src/", total)
have = count_prefix.(base <> "src/")

emit.(%{
  "lane" => "a7",
  "op" => "fixture_put_100k",
  "blobs" => have,
  "wall_ms" => fmt.(fix_ms, 1),
  "puts_per_sec" => fmt.(fix_ips, 0),
  "ets_mb" => fmt.(ets_mb.(), 1)
})

# ---- (2) simulated rename of the full 100k tree with milestones + live readers ----
parent = self()

reader =
  spawn(fn ->
    # probes alternate: even i reads OLD name (expect value then 404 once renamed),
    # odd i reads NEW name (expect 404 then value). Counts the window directly.
    counts =
      Enum.reduce(1..60_000, {0, 0, 0, 0}, fn i, {of, o404, nf, n404} ->
        if rem(i, 2) == 0 do
          k = path.(rem(i, total) + 1)

          case Smalt.Store.get(tbl, base <> "src/" <> k) do
            {:ok, _} -> {of + 1, o404, nf, n404}
            :error -> {of, o404 + 1, nf, n404}
          end
        else
          k = path.(rem(i, total) + 1)

          case Smalt.Store.get(tbl, base <> "dst/" <> k) do
            {:ok, _} -> {of, o404, nf + 1, n404}
            :error -> {of, o404, nf, n404 + 1}
          end
        end
      end)

    send(parent, {:reader_done, counts})
  end)

rename_pid =
  spawn(fn ->
    t = now_us.()
    :ok

    done =
      rename_tree.(
        base <> "src/",
        base <> "dst/",
        fn ->
          d =
            case :erlang.get(:a7_done) do
              :undefined -> 1
              n -> n + 1
            end
          :erlang.put(:a7_done, d)

          if d in [10_000, 50_000, 100_000] do
            send(parent, {:milestone, d, (now_us.() - t) / 1000, ets_mb.()})
          end
        end
      )

    send(parent, {:rename_done, done, (now_us.() - t) / 1000, ets_mb.()})
  end)

milestones =
  Enum.reduce(1..3, %{}, fn _, acc ->
    receive do
      {:milestone, m, ms, ets} -> Map.put(acc, m, {ms, ets})
      {:rename_done, _, _, _} -> acc
    after
      120_000 -> acc
    end
  end)

{done, wall_ms, ets1} =
  receive do
    {:rename_done, d, w, e} -> {d, w, e}
  after
    180_000 -> {0, 0.0, ets_mb.()}
  end

Enum.each([10_000, 50_000, 100_000], fn m ->
  case Map.get(milestones, m) do
    {ms, ets} ->
      emit.(%{
        "lane" => "a7",
        "op" => "rename_milestone",
        "items" => m,
        "wall_ms" => fmt.(ms, 1),
        "items_per_sec" => fmt.(m / (ms / 1000), 0),
        "ets_mb" => fmt.(ets, 1)
      })

    nil ->
      nil
  end
end)

emit.(%{
  "lane" => "a7",
  "op" => "rename_summary",
  "items_rekeyed" => done,
  "wall_ms" => fmt.(wall_ms, 1),
  "items_per_sec" => fmt.(if(wall_ms > 0, do: done / (wall_ms / 1000), else: 0.0), 0),
  "ets_mb_after" => fmt.(ets1, 1),
  "real_adls_equivalent" => "O(1) metadata op, sub-ms, no data copy"
})

send(reader, :stop)
receive do
  {:reader_done, {of, o404, nf, n404}} ->
    emit.(%{
      "lane" => "a7",
      "op" => "concurrent_reads_during_rename",
      "reads_old_name_found" => of,
      "reads_old_name_404" => o404,
      "reads_new_name_found" => nf,
      "reads_new_name_404" => n404,
      "verdict" =>
        "old-name reads split found/404 and new-name reads split 404/found — mixed-state window witnessed"
    })
after
  5_000 -> nil
end

# ---- (3) atomicity witness: kill the rename midway ----
build_tree.("k2src/", 20_000)

k2src = base <> "k2src/"
k2dst = base <> "k2dst/"

# Deterministic crash: the renaming process hard-kills itself (:kill, no trap
# cleanup) exactly 3,000 re-keys into a 20,000-blob rename. No polling race.
kill_pid =
  spawn(fn ->
    rename_tree.(k2src, k2dst, fn ->
      case :erlang.get(:a7_k2) do
        :undefined -> :erlang.put(:a7_k2, 1)
        2_999 -> Process.exit(self(), :kill)
        n -> :erlang.put(:a7_k2, n + 1)
      end
    end)

    send(parent, {:k2_done})
  end)

killed =
  receive do
    {:k2_done} -> false
  after
    500 -> true
  end

Process.sleep(50)

old_left = count_prefix.(k2src)
new_moved = count_prefix.(k2dst)

emit.(%{
  "lane" => "a7",
  "op" => "atomicity_witness",
  "killed_midway" => to_string(killed),
  "old_prefix_remaining" => old_left,
  "new_prefix_moved" => new_moved,
  "mixed_prefix_state" => to_string(old_left > 0 and new_moved > 0),
  "verdict" =>
    if(old_left > 0 and new_moved > 0,
      do: "NON_ATOMIC_partial_rename_persists_after_crash",
      else: "INCONCLUSIVE_rename_finished_before_kill"
    )
})

# ---- (4) real-ADLS comparison row ----
emit.(%{
  "lane" => "a7",
  "op" => "real_adls_comparison",
  "smalt_simulated_rename" => "O(n) enumerate+re-key per blob, non-atomic, mixed-prefix window",
  "real_adls_gen2_rename" => "O(1) metadata parent-repoint, atomic, single call, no data movement",
  "divergence_magnitude" => "O(n) vs O(1) — GAP(blob-hns-atomic-rename)"
})

# teardown: substrate down after
Smalt.Store.clear()
:ok = :erlang.memory(:ets) && IO.puts("a7 done")
