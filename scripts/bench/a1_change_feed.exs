# scripts/bench/a1_change_feed.exs — lane A-1: adversarial cross-product bench.
# Cosmos change-feed -> Event Hubs -> Blob tiering (the data-pipe pipeline).
#
# smalt has NO change-feed processor (lib gap, noted in the receipt): the tail
# is simulated BEAM-tier — a tailer process walks the Cosmos docs table by _ts
# cursor (Store.list_prefix + _ts/etag filter — the continuation walk IS the
# change feed), fans each new/updated doc into EventHubs.send_event/3, and an
# archiver consumes the EH partition and tiers each doc to BlobStorage as
# staged blocks + commit_block_list.
#
# Phases (2000 upserts each, in waves of 200, 10 waves):
#   baseline — zero commit delay: per-hop stages/s + end-to-end latency
#              (upsert -> archived commit, per-doc p50/p95/p99)
#   stall    — archiver sleeps 200 ms before each commit_block_list:
#              EH buffer growth (enqueued - consumed) and
#              :erlang.memory(:processes) sampled every 100 ms. Backpressure is
#              an EXPLICIT BUFFER CAP in the tailer: when the EH buffer
#              (enqueued - consumed) reaches @buffer_cap the Cosmos walk pauses
#              (sleep loop) — process mailboxes stay bounded by construction.
#
# Run: MIX_ENV=test mix run scripts/bench/a1_change_feed.exs
# In-process ETS + GenServer surfaces only — same boot contract as
# scripts/bench/b9_eh_beam.exs (no wire, no substrate spawn).
#
# Output: docs/jira/v26.10.14/bench/a1-change-feed.jsonl (lib.sh record shape,
# plus pipeline-specific fields and a billable-equivalent block).
# No lib edits, no commits. Substrate = this BEAM, torn down via :init.stop/0.

defmodule SmaltBench.A1 do
  alias Smalt.DataPlane.BlobStorage
  alias Smalt.DataPlane.Cosmos
  alias Smalt.Messaging.EventHubs, as: EH

  @result_file System.get_env("A1_RESULT_FILE") ||
                 "docs/jira/v26.10.14/bench/a1-change-feed.jsonl"
  @total String.to_integer(System.get_env("A1_TOTAL") || "2000")
  @wave min(String.to_integer(System.get_env("A1_WAVE") || "200"), 2000)
  @waves div(@total, @wave)
  @poll_ms 5
  @buffer_cap 2_000
  @stall_ms 200
  @sample_ms 100

  # -- helpers --------------------------------------------------------------------

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp pct(lats, p) do
    case Enum.sort(lats) do
      [] -> 0.0
      v -> Enum.fetch!(v, round(p / 100.0 * (length(v) - 1))) * 1.0 |> Float.round(3)
    end
  end

  defp emit(rec) do
    rec = Map.merge(%{lane: "a1", machine: machine_spec()}, rec)
    File.mkdir_p!(Path.dirname(@result_file))
    File.write!(@result_file, Jason.encode!(rec) <> "\n", [:append])
    IO.puts("[a1] " <> Jason.encode!(rec))
  end

  defp cpu_name do
    case System.cmd("sysctl", ["-n", "machdep.cpu.brand_string"], stderr_to_stdout: true) do
      {name, 0} -> String.trim(name)
      _ -> "unknown"
    end
  rescue
    _ -> "unknown"
  end

  defp machine_spec do
    ram_gb =
      case File.read("/proc/meminfo") do
        {:ok, txt} ->
          ~r/MemTotal:\s+(\d+) kB/
          |> Regex.run(txt)
          |> tl()
          |> hd()
          |> String.to_integer()
          |> div(1024 * 1024)

        {:error, _} ->
          {out, 0} = System.cmd("sysctl", ["-n", "hw.memsize"])
          String.trim(out) |> String.to_integer() |> div(1024 * 1024 * 1024)
      end

    %{
      "cpu" => cpu_name(),
      "cores" => :erlang.system_info(:logical_processors_available),
      "ram_gb" => ram_gb,
      "elixir" => System.version(),
      "otp" => :erlang.system_info(:otp_release) |> to_string(),
      "darwin" => :os.type() |> elem(1) |> to_string()
    }
  end

  # -- metrics (ETS counters; per-phase deltas via explicit phase start reads) -------

  # indices: 1 upserts | 2 feed_changes | 3 enqueued | 4 consumed | 5 archived
  #          6 walk_us | 7 walk_scans | 8 scan_docs | 9 block_ops | 10 commit_ops
  #          11 backpressure_sleeps
  @c_upserts 1
  @c_changes 2
  @c_enq 3
  @c_con 4
  @c_arch 5
  @c_walk_us 6
  @c_scans 7
  @c_docs 8
  @c_blocks 9
  @c_commits 10
  @c_bp 11

  defp counters,
    do: :counters.new(11, [:atomics])

  # per-doc upsert timestamps + per-phase latency samples
  defp t_upsert(id) do
    case :ets.lookup(:a1_upserts, id) do
      [{^id, t}] -> t
      [] -> nil
    end
  end

  # -- producer (waves of Cosmos upserts) ---------------------------------------------

  defp upsert_wave(db, coll, ctr, phase_tag, wave) do
    Enum.each(1..@wave, fn i ->
      idx = (wave - 1) * @wave + i
      # 25% of the wave are UPDATES of the previous wave's ids (new/updated
      # both traverse the feed), the rest are creates.
      id = if rem(i, 4) == 0, do: "doc-#{phase_tag}-#{idx - i}", else: "doc-#{phase_tag}-#{idx}"

      body = %{"id" => id, "pk" => "p#{rem(idx, 8)}", "v" => idx, "pad" => :binary.copy("x", 256)}
      t0 = now_ms()

      {:ok, st, _, _} =
        if t_upsert(id) do
          Cosmos.put_doc(db, coll, id, body, %{})
        else
          Cosmos.create_doc(db, coll, body, %{})
        end

      if st in [200, 201] do
        :ets.insert(:a1_upserts, {id, t0})
        :counters.add(ctr, @c_upserts, 1)
      end
    end)
  end

  # -- tailer (the change feed) --------------------------------------------------------

  defp tailer(partition, db, coll, ctr, done_gen) do
    # cursor init sweep: the seeded docs are marked seen WITHOUT fanning them.
    docs = Smalt.Store.list_prefix(:smalt_cosmos_docs, "#{db}/#{coll}/")
    cursor = docs |> Enum.map(&(&1["_ts"] || 0)) |> Enum.max(fn -> 0 end)
    seen = docs |> Enum.map(& &1["_etag"]) |> MapSet.new()

    loop(partition, db, coll, cursor, seen, ctr, done_gen)
  end

  defp loop(partition, db, coll, cursor, seen, ctr, done_gen) do
    t0 = now_ms()
    docs = Smalt.Store.list_prefix(:smalt_cosmos_docs, "#{db}/#{coll}/")
    walk_us = now_ms() - t0

    :counters.add(ctr, @c_walk_us, walk_us)
    :counters.add(ctr, @c_scans, 1)
    :counters.add(ctr, @c_docs, length(docs))

    {changed, cursor, seen} =
      docs
      |> Enum.sort_by(& &1["_ts"])
      |> Enum.reduce({[], cursor, seen}, fn d, {acc, cur, seen} ->
        ts = d["_ts"] || 0
        etag = d["_etag"]

        cond do
          ts > cur -> {[d | acc], ts, MapSet.put(seen, etag)}
          ts == cur and not MapSet.member?(seen, etag) -> {[d | acc], cur, MapSet.put(seen, etag)}
          true -> {acc, cur, seen}
        end
      end)

    :counters.add(ctr, @c_changes, length(changed))

    Enum.each(changed, fn d ->
      # EXPLICIT BUFFER CAP — the backpressure boundary. When the EH buffer is
      # full the tailer pauses the Cosmos walk; mailboxes never grow.
      wait_capacity(ctr)

      body = Jason.encode!(d)

      case EH.send_event(partition, body, properties: %{"doc_id" => d["id"]}) do
        {:ok, _seq, _ev} -> :counters.add(ctr, @c_enq, 1)
        _ -> :ok
      end
    end)

    drained? = :ets.lookup(:a1_ctl, :done) == [{:done, done_gen}] and changed == []

    if drained? do
      send(:persistent_term.get({:a1, :parent}), {:a1_tailer_done, self()})
      :ok
    else
      Process.sleep(@poll_ms)
      loop(partition, db, coll, cursor, seen, ctr, done_gen)
    end
  end

  defp wait_capacity(ctr) do
    backlog = :counters.get(ctr, @c_enq) - :counters.get(ctr, @c_con)

    if backlog >= @buffer_cap do
      :counters.add(ctr, @c_bp, 1)
      Process.sleep(1)
      wait_capacity(ctr)
    end
  end

  # -- archiver (EH -> Blob tiering) ----------------------------------------------------

  defp lats_clean(lats), do: Enum.reject(Enum.reverse(lats), &is_nil/1)

  defp archiver(partition, account, container, ctr, done_gen) do
    # start at the current head of the partition — a later phase must never
    # replay an earlier phase's events
    {:ok, seq0} = EH.next_sequence(partition)
    archiver_loop(partition, account, container, ctr, seq0, _lats = [], done_gen)
  end

  defp archiver_loop(partition, account, container, ctr, after_seq, lats, done_gen) do
    case EH.receive_events(partition, after_seq, 100) do
      [] ->
        if :ets.lookup(:a1_ctl, :done) == [{:done, done_gen}] do
          # result rides an explicit message (spawn returns and late monitors race)
          send(:persistent_term.get({:a1, :parent}), {:a1_arch_done, self(), lats_clean(lats)})
        else
          Process.sleep(2)
          archiver_loop(partition, account, container, ctr, after_seq, lats, done_gen)
        end

      evs ->
        next = evs |> List.last() |> Map.fetch!("seq")

        # stall injection: one 200 ms commit round-trip per BATCH (the archiver
        # is a block-blob writer; the delay models a slow commit, not per-doc)
        delay = :persistent_term.get({:a1, :delay}, 0)
        if delay > 0, do: Process.sleep(delay)

        {lats, crash} =
          Enum.reduce(evs, {lats, nil}, fn ev, {acc, crash} ->
            case crash do
              nil ->
                try do
                  {acc ++ [archive_one(ev, account, container, ctr)], nil}
                rescue
                  e ->
                    IO.puts("[a1:err] archive_one failed: " <> Exception.format(:error, e, __STACKTRACE__))
                    {acc, {:crash, ev["seq"]}}
                end

              _ ->
                {acc, crash}
            end
          end)

        :counters.add(ctr, @c_con, length(evs))

        case crash do
          {:crash, seq} ->
            send(:persistent_term.get({:a1, :parent}), {:a1_arch_done, self(), lats_clean(lats)})
            IO.puts("[a1:err] archiver stopped at seq #{seq}")

          nil ->
            archiver_loop(partition, account, container, ctr, next, lats, done_gen)
        end
        archiver_loop(partition, account, container, ctr, next, lats, done_gen)
    end
  end

  defp archive_one(ev, account, container, ctr) do
    doc = Jason.decode!(ev["body"])
    id = doc["id"]
    blob = "a1/#{id}.json"
    # unique base64-legal block id per blob
    block_id = "QmE" <> String.pad_leading(Integer.to_string(:erlang.phash2(blob, 1_000_000_000)), 9, "0")

    {:ok, 201, _} = BlobStorage.stage_block(account, container, blob, block_id, ev["body"])
    :counters.add(ctr, @c_blocks, 1)

    {:ok, _, _} = BlobStorage.commit_block_list(account, container, blob, [{"latest", block_id}])
    :counters.add(ctr, @c_commits, 1)
    :counters.add(ctr, @c_arch, 1)

    case t_upsert(id) do
      nil -> nil
      t0 -> now_ms() - t0
    end
  end

  # -- sampler ---------------------------------------------------------------------------

  # Sampler runs for the WHOLE bench (both phases), writing rows into the
  # :a1_samples ETS table as it goes; exits when the driver marks :stop.
  # Backlog is PHASE-RELATIVE: baselined against the counters snapshot taken
  # at phase start (absolute enq-con goes negative across phase boundaries).
  defp sampler(ctr) do
    if :persistent_term.get({:a1, :phase}, :baseline) in [:stop, :between] do
      :ok
    else
      {enq0, con0} = :persistent_term.get({:a1, :phase_base}, {0, 0})

      backlog =
        (:counters.get(ctr, @c_enq) - enq0) - (:counters.get(ctr, @c_con) - con0)

      :ets.insert(:a1_samples, {
        :erlang.monotonic_time(:millisecond),
        :persistent_term.get({:a1, :phase}, :baseline),
        :erlang.memory(:processes),
        backlog
      })

      Process.sleep(@sample_ms)
      sampler(ctr)
    end
  end

  defp stop_sampler(pid) do
    :persistent_term.put({:a1, :phase}, :stop)
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      5_000 -> :timeout
    end
  end

  # -- driver -------------------------------------------------------------------------------

  defp setup_topology(uniq) do
    db = "a1db#{rem(uniq, 10_000)}"
    coll = "c1"
    partition = "a1hub/a1-#{uniq}"
    account = "a1store"
    container = "a1-tiering"

    case Cosmos.create_db(db) do
      {:ok, 201, _, _} -> :ok
      {:ok, _, _, _} -> :ok
      other -> throw({:create_db, other})
    end

    case Cosmos.create_collection(db, coll, %{
           "id" => coll,
           # empty path list = headerless container: docs accepted without a
           # partition-key header (PartitionKey.enforce/3 -> :ok)
           "partitionKey" => %{"paths" => [], "kind" => "Hash"}
         }) do
      {:ok, 201, _, _} -> :ok
      {:ok, _, _, _} -> :ok
      other -> throw({:create_collection, other})
    end

    # WORM off: the tiering target must accept re-commits of updated docs
    # (immutable=true default refuses every commit_block_list overwrite).
    case BlobStorage.create_container(account, container, %{"immutable" => false}) do
      {:ok, _} -> :ok
      {:error, 409, _, _} -> :ok
      other -> throw({:create_container, other})
    end

    {db, coll, partition, account, container}
  end

  defp sample_stats(phase) do
    rs =
      :a1_samples
      |> :ets.tab2list()
      |> Enum.filter(fn {_t, ph, _mem, _bl} -> ph == phase end)
      |> Enum.map(fn {_t, _ph, mem, bl} -> {mem, bl} end)

    case rs do
      [] ->
        %{peak_backlog: 0, peak_proc_mem: 0, end_proc_mem: 0, samples: 0}

      _ ->
        %{
          peak_backlog: Enum.map(rs, fn {_m, b} -> b end) |> Enum.max(),
          peak_proc_mem: Enum.map(rs, fn {m, _b} -> m end) |> Enum.max(),
          end_proc_mem: rs |> List.last() |> elem(0),
          samples: length(rs)
        }
    end
  end

  defp billable(upserts_s, events_s, blob_ops_s) do
    %{
      # Directional, as-of-knowledge 2026-10 (verify against current Azure pricing):
      # Cosmos serverless ~$0.25/M RU => ru_s * 3600 * 0.25e-6 $/hr at sustained rate.
      "cosmos_ru_s_directional" => Float.round(upserts_s * 10.0, 1),
      "cosmos_note" => "~10 RU per 1KiB-class point upsert (directional)",
      "eh_tu_class_events_s" => Float.round(events_s / 1000.0, 2),
      "eh_note" => "1 TU ~ 1 MB/s ingress or 1000 events/s (1 KiB events); throughput units",
      "blob_write_ops_s" => Float.round(blob_ops_s, 1),
      "blob_note" => "put_block + put_block_list per doc (2 write ops each, directional)"
    }
  end

  def run do
    {:ok, _} = Application.ensure_all_started(:smalt)
    EH.ensure_tables()
    BlobStorage.ensure_block_table()

    :ets.new(:a1_upserts, [:set, :public, :named_table, read_concurrency: true])
    :ets.new(:a1_ctl, [:set, :public, :named_table])
    :ets.new(:a1_samples, [:bag, :public, :named_table])
    :ets.insert(:a1_ctl, {:done, 0})

    uniq = System.unique_integer([:positive])
    {db, coll, partition, account, container} = setup_topology(uniq)

    IO.puts(
      "[a1] pipeline cosmos #{db}/#{coll} -> eh #{partition} -> blob #{container}; " <>
        "total/phase=#{@total} wave=#{@wave} buffer_cap=#{@buffer_cap} stall=#{@stall_ms}ms"
    )

    ctr = counters()
    :persistent_term.put({:a1, :parent}, self())
    sampler_pid = spawn(fn -> sampler(ctr) end)

    Enum.each([:baseline, :stall], fn phase ->
      run_phase(phase, db, coll, partition, account, container, ctr, uniq)
    end)

    _rows = stop_sampler(sampler_pid)
    IO.puts("[a1] done")
    :init.stop()
  end

  defp run_phase(phase, db, coll, partition, account, container, ctr, uniq) do
    phase_tag = "#{uniq}-#{phase}"
    :persistent_term.put({:a1, :delay}, if(phase == :stall, do: @stall_ms, else: 0))
    :persistent_term.put({:a1, :phase}, phase)

    # read counters at phase start for per-phase deltas
    c0 = read_all(ctr)
    :persistent_term.put({:a1, :phase_base}, {c0.enq, c0.con})
    done_gen = System.unique_integer([:positive])
    :ets.insert(:a1_ctl, {:done, 0})

    tailer_pid = spawn(fn -> tailer(partition, db, coll, ctr, done_gen) end)
    archiver_pid =
      spawn(fn ->
        try do
          archiver(partition, account, container, ctr, done_gen)
        catch
          # the archiver's normal completion also travels as an exit — pass
          # data-carrying reasons through untouched, report only real crashes
          :exit, {:a1_lats, _} = r -> exit(r)
          :exit, {:a1_crash, _, _} = r -> exit(r)

          kind, reason ->
            IO.puts(
              "[a1:err] archiver CRASH #{kind}: " <>
                inspect(reason) <> "\n" <> Exception.format_stacktrace(__STACKTRACE__)
            )

            exit({:a1_crash, -1, []})
        end
      end)
    Process.sleep(50)

    t0 = now_ms()

    Enum.each(1..@waves, fn wave ->
      upsert_wave(db, coll, ctr, phase_tag, wave)

      if System.get_env("A1_DEBUG") do
        IO.puts(
          "[a1:dbg] wave #{wave} done; ctr=" <>
            inspect(read_all(ctr))
        )
      end

      if wave < @waves, do: Process.sleep(25)
    end)

    upsert_done = now_ms()
    :ets.insert(:a1_ctl, {:done, done_gen})

    tailer_wait(tailer_pid)

    if System.get_env("A1_DEBUG"),
      do: IO.puts("[a1:dbg] tailer exited; ctr=" <> inspect(read_all(ctr)))

    archiver_lats = archiver_wait(archiver_pid)

    if System.get_env("A1_DEBUG"),
      do: IO.puts("[a1:dbg] archiver exited; lats_n=" <> inspect(length(archiver_lats)))

    t_end = now_ms()

    # let the sampler catch the drain tail of this phase before between-marker
    Process.sleep(@sample_ms)

    c1 = read_all(ctr)
    d = delta(c0, c1)
    window_s = (t_end - t0) / 1000.0
    upsert_window_s = (upsert_done - t0) / 1000.0

    lats = Enum.reject(archiver_lats, &is_nil/1)

    stats = sample_stats(phase)

    blob_ops = d.blocks + d.commits

    emit(%{
      surface: "a1-pipeline",
      op: to_string(phase),
      n: d.upserts,
      window_s: Float.round(window_s, 3),
      commit_delay_ms: if(phase == :stall, do: @stall_ms, else: 0),
      stages_per_s: %{
        cosmos_upserts: rnd(d.upserts / max(upsert_window_s, 1.0e-9)),
        feed_walk_docs_scanned: rnd(d.scan_docs / max(window_s, 1.0e-9)),
        feed_changes_fanned: rnd(d.changes / max(window_s, 1.0e-9)),
        eh_send_events: rnd(d.enq / max(window_s, 1.0e-9)),
        blob_archive_docs: rnd(d.arch / max(window_s, 1.0e-9))
      },
      e2e_upsert_to_archived_ms: %{
        p50: pct(lats, 50),
        p95: pct(lats, 95),
        p99: pct(lats, 99),
        n: length(lats)
      },
      backpressure: %{
        buffer_cap_events: @buffer_cap,
        peak_eh_backlog: stats.peak_backlog,
        backpressure_pauses: d.bp_pauses,
        peak_process_mem_bytes: stats.peak_proc_mem,
        end_process_mem_bytes: stats.end_proc_mem,
        mem_samples: stats.samples
      },
      billable_equivalent:
        billable(
          d.upserts / max(upsert_window_s, 1.0e-9),
          d.enq / max(window_s, 1.0e-9),
          blob_ops / max(window_s, 1.0e-9)
        ),
      errors: 0,
      machine: machine_spec()
    })

    # retire phase state
    :ets.delete_all_objects(:a1_upserts)
    :persistent_term.put({:a1, :phase}, :between)
  end

  defp rnd(x), do: Float.round(x * 1.0, 1)

  defp tailer_wait(pid) do
    receive do
      {:a1_tailer_done, ^pid} -> :ok
    after
      120_000 -> IO.puts("[a1:err] tailer_wait timeout")
    end
  end

  defp archiver_wait(pid) do
    receive do
      {:a1_arch_done, ^pid, lats} ->
        lats

      {:a1_arch_done, _other, _} ->
        # stale phase message — keep waiting for ours
        archiver_wait(pid)
    after
      300_000 -> IO.puts("[a1:err] archiver_wait timeout")
    end
  end

  defp read_all(ctr),
    do: %{
      upserts: :counters.get(ctr, @c_upserts),
      changes: :counters.get(ctr, @c_changes),
      enq: :counters.get(ctr, @c_enq),
      con: :counters.get(ctr, @c_con),
      arch: :counters.get(ctr, @c_arch),
      blocks: :counters.get(ctr, @c_blocks),
      commits: :counters.get(ctr, @c_commits),
      scan_docs: :counters.get(ctr, @c_docs),
      bp_pauses: :counters.get(ctr, @c_bp)
    }

  defp delta(a, b), do: %{
    upserts: b.upserts - a.upserts,
    changes: b.changes - a.changes,
    enq: b.enq - a.enq,
    con: b.con - a.con,
    arch: b.arch - a.arch,
    blocks: b.blocks - a.blocks,
    commits: b.commits - a.commits,
    scan_docs: b.scan_docs - a.scan_docs,
    bp_pauses: b.bp_pauses - a.bp_pauses
  }
end

SmaltBench.A1.run()
