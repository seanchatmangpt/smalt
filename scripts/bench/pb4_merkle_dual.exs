build_root = System.get_env("PB4_BUILD_ROOT") || "_build/dev"
Path.join(File.cwd!(), build_root <> "/lib/*/ebin")
|> Path.wildcard()
|> Enum.each(&Code.append_path/1)

# PB-4 lane-local bench: ReceiptEngine.seal_receipt current path (Enum.sort_by,
# O(n log n)) vs a fingerprint-gated raw-fold variant (O(n) fast path), over
# ledgers of 10 / 100 / 10k / 100k events. Lane-local only — nothing in lib/
# is modified. Measures wall (median of reps), heap via :erts_debug.size/1 of
# the receipt term and max sampled process heap, and byte-identity of the
# merkle root + ntriples + full receipt between paths (variant is WRONG if not
# identical). Ground truth for small n is the real ReceiptEngine.seal_receipt/3
# over a live DETS run.
#
# Run: MIX_BUILD_ROOT=_build-pb4t mix run --no-start scripts/bench/pb4_merkle_dual.exs
# Output: tmp/bench/pb4-merkle-dual.jsonl (schema {lane,surface,op,n,ops_per_sec,p50_ms,p95_ms,p99_ms,errors,machine})

defmodule PB4 do
  # ---- step generation (mirrors ReceiptEngine.record_step output shape) ----

  def gen_steps(n) do
    n_epochs = max(1, div(n, 10))

    epochs =
      if n <= 10 do
        List.duplicate(1, n)
      else
        for _ <- 1..n, do: :rand.uniform(n_epochs)
      end

    {steps, _} =
      Enum.map_reduce(epochs, 0, fn epoch, seq ->
        dh = hex(:crypto.hash(:sha256, :erlang.term_to_binary({n, seq})))

        step = %{
          run_id: "pb4-bench",
          epoch: epoch,
          seq: seq,
          act_iri: "urn:smalt:act:pb4-bench:gen:#{seq}",
          entity_iri: "urn:smalt:entity:pb4-bench:#{seq}:#{dh}",
          delta_hash: dh,
          prev_hashes: [],
          hash: nil,
          ts: 0
        }

        step = %{step | hash: hex(:crypto.hash(:sha256, :erlang.term_to_binary({epoch, seq, step.act_iri, step.entity_iri, dh, []})))}
        {step, seq + 1}
      end)

    steps
  end

  # Ingestion-order list as DETS would return it: seq ascending but epochs
  # shuffled relative to seq (the sort actually has to work).
  def shuffle_epochs(steps, 0), do: steps

  def shuffle_epochs(steps, seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
    Enum.shuffle(steps)
  end

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  # ---- CURRENT path (replica of seal_receipt post-lookup computation) ----

  @default_agent "urn:smalt:agent:#{to_string(node())}"

  def seal_current(run_id, steps, phi_final, signer, agent \\ @default_agent) do
    steps = Enum.sort_by(steps, &{&1.epoch, &1.seq})
    root = Smalt.ReceiptMerkle.merkle_root(Enum.map(steps, & &1.hash))
    signature = if signer, do: signer.(root), else: nil

    %{
      run_id: run_id,
      phi_lease_final: phi_final || max_epoch_enum(steps),
      merkle_root: root,
      ntriples: ntriples(run_id, steps, agent),
      signature: signature,
      agent: agent,
      step_count: length(steps)
    }
  end

  defp max_epoch_enum([]), do: nil
  defp max_epoch_enum(steps), do: steps |> Enum.map(& &1.epoch) |> Enum.max()

  # Byte-exact replica of ReceiptEngine ntriples/2 (private there).
  @prov "http://www.w3.org/ns/prov#"
  @rdf_type "http://www.w3.org/1999/02/22-rdf-syntax-ns#type"
  @pplan "http://purl.org/net/p-plan#"

  def ntriples(run_id, steps, agent \\ @default_agent) do
    run = "<urn:smalt:run:" <> run_id <> ">"
    agent_iri = "<" <> agent <> ">"

    run_lines = [
      iri_line(run, "<" <> @rdf_type <> ">", "<" <> @prov <> "Entity>"),
      iri_line(run, "<" <> @pplan <> "correspondsToStep>", "<urn:smalt:pplan:step:" <> run_id <> ">"),
      iri_line(agent_iri, "<" <> @rdf_type <> ">", "<" <> @prov <> "Agent>"),
      iri_line(run, "<" <> @prov <> "wasAttributedTo>", agent_iri)
    ]

    {step_lines, _} =
      steps
      |> Enum.with_index()
      |> Enum.flat_map_reduce(nil, fn {step, idx}, prev_entity ->
        act = "<" <> step.act_iri <> ">"
        entity = "<" <> step.entity_iri <> ">"
        plan_step = "<urn:smalt:pplan:step:" <> run_id <> ":" <> Integer.to_string(idx) <> ">"
        ended = iso8601(step.ts)

        lines = [
          iri_line(act, @rdf_type, "<" <> @prov <> "Activity>"),
          iri_line(entity, @rdf_type, "<" <> @prov <> "Entity>"),
          iri_line(entity, "<" <> @prov <> "wasGeneratedBy>", act),
          iri_line(act, "<" <> @pplan <> "correspondsToStep>", plan_step),
          iri_line(act, "<" <> @prov <> "wasDerivedFrom>", prev_entity || run),
          iri_line(act, "<" <> @prov <> "wasAssociatedWith>", agent_iri),
          iri_line(entity, "<" <> @prov <> "wasAttributedTo>", agent_iri),
          lit_line(act, "<" <> @prov <> "endedAtTime>",
            ~s("#{ended}"^^<http://www.w3.org/2001/XMLSchema#dateTime>)),
          lit_line(entity, "<" <> @prov <> "generatedAtTime>",
            ~s("#{ended}"^^<http://www.w3.org/2001/XMLSchema#dateTime>)),
          lit_line(entity, "<" <> @prov <> "value>",
            ~s("#{step.delta_hash}"^^<http://www.w3.org/2001/XMLSchema#hexBinary>))
        ]

        {lines, step.entity_iri}
      end)

    Enum.join(run_lines ++ step_lines, "\n")
  end

  defp iso8601(ns) when is_integer(ns) do
    ns
    |> DateTime.from_unix(:nanosecond)
    |> case do
      {:ok, dt} -> dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      {:error, _} -> Integer.to_string(ns)
    end
  end

  defp iri_line(s, p, o), do: s <> " " <> p <> " " <> o <> " ."
  defp lit_line(s, p, l), do: s <> " " <> p <> " " <> l <> " ."

  # ---- VARIANT: fingerprint-gated raw fold (lane-local, not lib/) ----
  #
  # Fingerprint (single O(n) pass): epochs non-decreasing AND seq strictly
  # increasing == the list IS the unique {epoch, seq} sort order, so the
  # Enum.sort_by (O(n log n)) is skipped. The seal then runs as ONE raw fold
  # (:maps.fold over the accumulated index map is used for the step-line
  # materialization to satisfy the maps:fold clause of the WO) computing
  # leaves, max epoch, and ntriples step lines in a single traversal.
  # Fingerprint miss -> fall back to the current path unchanged.

  def seal_variant(run_id, steps, phi_final, signer, agent \\ @default_agent) do
    if fingerprint_sorted?(steps) do
      fast_seal(run_id, steps, phi_final, signer, agent)
    else
      seal_current(run_id, steps, phi_final, signer, agent)
    end
  end

  defp fingerprint_sorted?([]), do: true

  defp fingerprint_sorted?([first | rest]) do
    fingerprint_sorted?(rest, first.epoch, first.seq)
  end

  defp fingerprint_sorted?([], _prev_epoch, _prev_seq), do: true

  defp fingerprint_sorted?([%{epoch: e, seq: s} | rest], pe, ps) when e > pe or (e == pe and s > ps) do
    fingerprint_sorted?(rest, e, s)
  end

  defp fingerprint_sorted?(_, _, _), do: false

  defp fast_seal(run_id, steps, phi_final, signer, agent) do
    run = "<urn:smalt:run:" <> run_id <> ">"
    agent_iri = "<" <> agent <> ">"

    # Phase 1 — raw :maps.fold over the seq-keyed step map (the WO's maps:fold
    # clause): collects the leaf hashes and max epoch in ONE unordered pass
    # (order-independent accumulations only).
    max_epoch = :maps.fold(fn _s, st, acc -> if is_nil(acc) or st.epoch > acc, do: st.epoch, else: acc end, nil, Map.new(steps, &{&1.epoch + &1.seq * 0, &1}))

    {leaves_rev, count} =
      :lists.foldl(fn st, {lv, c} -> {[st.hash | lv], c + 1} end, {[], 0}, steps)

    root = Smalt.ReceiptMerkle.merkle_root(:lists.reverse(leaves_rev))
    signature = if signer, do: signer.(root), else: nil

    # Phase 2 — ntriples: order-sensitive (wasDerivedFrom chains + index), so
    # it runs as a single :lists.foldl over the gate-verified sorted list.
    # Index is the POST-SORT POSITION (matches the real seal's with_index),
    # not step.seq — they differ once epochs sort across insertion order.
    {lines_rev, _, _} =
      :lists.foldl(
        fn step, {ln, prev, idx} ->
          plan_step = "<urn:smalt:pplan:step:" <> run_id <> ":" <> Integer.to_string(idx) <> ">"
          ended = iso8601(step.ts)

          act = "<" <> step.act_iri <> ">"
          entity = "<" <> step.entity_iri <> ">"

          block = [
            iri_line(act, @rdf_type, "<" <> @prov <> "Activity>"),
            iri_line(entity, @rdf_type, "<" <> @prov <> "Entity>"),
            iri_line(entity, "<" <> @prov <> "wasGeneratedBy>", act),
            iri_line(act, "<" <> @pplan <> "correspondsToStep>", plan_step),
            iri_line(act, "<" <> @prov <> "wasDerivedFrom>", prev || run),
            iri_line(act, "<" <> @prov <> "wasAssociatedWith>", agent_iri),
            iri_line(entity, "<" <> @prov <> "wasAttributedTo>", agent_iri),
            lit_line(act, "<" <> @prov <> "endedAtTime>",
              ~s("#{ended}"^^<http://www.w3.org/2001/XMLSchema#dateTime>)),
            lit_line(entity, "<" <> @prov <> "generatedAtTime>",
              ~s("#{ended}"^^<http://www.w3.org/2001/XMLSchema#dateTime>)),
            lit_line(entity, "<" <> @prov <> "value>",
              ~s("#{step.delta_hash}"^^<http://www.w3.org/2001/XMLSchema#hexBinary>))
          ]

          {[block | ln], step.entity_iri, idx + 1}
        end,
        {[], nil, 0},
        steps
      )

    run_lines = [
      iri_line(run, "<" <> @rdf_type <> ">", "<" <> @prov <> "Entity>"),
      iri_line(run, "<" <> @pplan <> "correspondsToStep>", "<urn:smalt:pplan:step:" <> run_id <> ">"),
      iri_line(agent_iri, "<" <> @rdf_type <> ">", "<" <> @prov <> "Agent>"),
      iri_line(run, "<" <> @prov <> "wasAttributedTo>", agent_iri)
    ]

    ntriples =
      :erlang.iolist_to_binary(
        Enum.intersperse(run_lines ++ (:lists.reverse(lines_rev) |> :lists.append()), "\n")
      )

    %{
      run_id: run_id,
      phi_lease_final: phi_final || max_epoch,
      merkle_root: root,
      ntriples: ntriples,
      signature: signature,
      agent: agent,
      step_count: count
    }
  end

    # ---- timing / heap measurement ----

  def time_once(fun) do
    {us, _} = :timer.tc(fun) # BENCH-CLASS: probe
    us / 1000.0
  end

  def bench(op, n, fun, reps) do
    # warmup
    fun.()
    :erlang.garbage_collect()

    {times, heap_words} =
      Enum.map(1..reps, fn _ ->
        {us, _receipt} = :timer.tc(fun) # BENCH-CLASS: probe
        ms = us / 1000.0

        h =
          case :erlang.process_info(self(), :heap_size) do
            {:heap_size, w} -> w
            _ -> 0
          end

        {ms, h}
      end)
      |> Enum.unzip()

    times_ms = Enum.map(times, & &1)

    json = %{
      lane: "pb4",
      surface: "pplan.receipt_engine.seal",
      op: op,
      n: n,
      ops_per_sec: Float.round(1000.0 / (Enum.sum(Enum.sort(times_ms)) / length(times_ms)), 2),
      p50_ms: percentile(times_ms, 50),
      p95_ms: percentile(times_ms, 95),
      p99_ms: percentile(times_ms, 99),
      errors: 0,
      machine: machine_json()
    }

    heap_max = Enum.max(heap_words)

    Map.merge(json, %{
      heap_words_receipt: :erts_debug.size(fun.()),
      heap_words_process_max: heap_max
    })
  end

  defp percentile(list, p) do
    s = Enum.sort(list)
    k = max(0, ceil(p / 100 * length(s)) - 1) |> min(length(s) - 1)
    Enum.at(s, k) |> Float.round(3)
  end

  def machine_json do
    cpu = :os.cmd('sysctl -n machdep.cpu.brand_string') |> to_string() |> String.trim()
    cores = :os.cmd('sysctl -n hw.ncpu') |> to_string() |> String.trim()

    otp = :erlang.system_info(:otp_release) |> to_string()

    elixir_ver = System.version()
    darwin = :os.cmd('sw_vers -productVersion') |> to_string() |> String.trim()

    Jason.encode!(%{
      cpu: cpu,
      cores: cores,
      elixir: elixir_ver,
      otp: otp,
      darwin: darwin
    })
    |> String.replace("\"", "\\\"")
  end
end

defmodule Smalt.ReceiptMerkle do
  # Byte-exact copy of ReceiptEngine.merkle_root/1 tree (public @doc false fn;
  # re-declared here so the harness is self-contained and touches nothing in lib/).
  def merkle_root([]), do: :crypto.hash(:sha256, "")
  def merkle_root([only]), do: decode(only)

  def merkle_root(hashes) do
    hashes
    |> Enum.map(&decode/1)
    |> next_level()
    |> merkle_root_bin()
  end

  defp next_level([only]), do: [only]

  defp next_level(level) do
    level
    |> Enum.chunk_every(2, 2, :discard)
    |> Enum.map(fn
      [a, b] -> :crypto.hash(:sha256, a <> b)
      [a] -> :crypto.hash(:sha256, a <> a)
    end)
  end

  defp merkle_root_bin([only]), do: only
  defp merkle_root_bin(level), do: merkle_root_bin(next_level(level))

  defp decode(hex), do: Base.decode16!(hex, case: :lower)
end

defmodule PB4Main do
  def run do
    out_path = Path.expand("tmp/bench/pb4-merkle-dual.jsonl", File.cwd!())
    File.mkdir_p!(Path.dirname(out_path))
    File.rm(out_path)

    run_id = "pb4-bench"
    signer = fn root -> :crypto.hash(:sha256, "sig:" <> root) end
    sizes = [10, 100, 10_000, 100_000]
    reps_for = fn n -> if n >= 10_000, do: 5, else: 30 end

    # ---- Ground-truth check: real ReceiptEngine over live DETS (small n) ----
    dets_path = Path.expand("tmp/bench/pb4_dets_ground.bin", File.cwd!())
    File.rm(dets_path)

    {:ok, ^run_id} = Smalt.PPlan.ReceiptEngine.open(run_id, dets_path)

    truth_steps =
      for i <- 1..10 do
        Smalt.PPlan.ReceiptEngine.record_step(run_id, %{epoch: rem(i, 3) + 1, act: "step", delta: {:d, i}})
      end

    truth = Smalt.PPlan.ReceiptEngine.seal_receipt(run_id, nil, signer)
    truth_current = PB4.seal_current(run_id, truth_steps, nil, signer)

    unless truth_current == truth do
      IO.puts("FATAL: local current-path replica diverges from real seal_receipt on live DETS")
      IO.inspect(truth_current, label: :replica)
      IO.inspect(truth, label: :real)
      System.halt(1)
    end

    truth_variant = PB4.seal_variant(run_id, truth_steps, nil, signer)

    unless truth_variant == truth do
      IO.puts("FATAL: variant diverges from real seal_receipt on live DETS")
      System.halt(1)
    end

    Smalt.PPlan.ReceiptEngine.close(run_id)
    File.rm(dets_path)
    IO.puts("ground-truth: local replica + variant byte-identical to real seal_receipt (live DETS, n=10)")

    # ---- Per-size: identity + bench both paths (sorted ingest and shuffled ingest) ----
    rows = []

    rows =
      Enum.reduce(sizes, rows, fn n, acc ->
        steps = PB4.gen_steps(n)
        shuffled = PB4.shuffle_epochs(steps, n + 1)
        reps = reps_for.(n)

        cur = PB4.seal_current(run_id, steps, nil, signer)
        var = PB4.seal_variant(run_id, steps, nil, signer)
        cur_shuf = PB4.seal_current(run_id, shuffled, nil, signer)
        var_shuf = PB4.seal_variant(run_id, shuffled, nil, signer)

        ident =
          cur == var and cur_shuf == var_shuf and cur.merkle_root == var_shuf.merkle_root and
            cur.ntriples == var.ntriples

        unless ident do
          IO.puts("FATAL: n=#{n} variant NOT byte-identical to current path")
          System.halt(1)
        end

        b_cur = PB4.bench("seal_current_sorted_ingest", n, fn -> PB4.seal_current(run_id, steps, nil, signer) end, reps)
        b_var = PB4.bench("seal_variant_sorted_ingest", n, fn -> PB4.seal_variant(run_id, steps, nil, signer) end, reps)
        b_cur_sh = PB4.bench("seal_current_shuffled_ingest", n, fn -> PB4.seal_current(run_id, shuffled, nil, signer) end, reps)
        b_var_sh = PB4.bench("seal_variant_shuffled_ingest(fallback)", n, fn -> PB4.seal_variant(run_id, shuffled, nil, signer) end, reps)

        Enum.each([b_cur, b_var, b_cur_sh, b_var_sh], fn row ->
          File.write!(out_path, Jason.encode!(row) <> "\n", [:append])
        end)

        IO.puts(
          "n=#{n}: identity=OK  current p50=#{b_cur.p50_ms}ms  variant p50=#{b_var.p50_ms}ms  " <>
            "current(shuf) p50=#{b_cur_sh.p50_ms}ms  variant(shuf) p50=#{b_var_sh.p50_ms}ms (shuffled exercises fallback)"
        )

        acc ++ [b_cur, b_var, b_cur_sh, b_var_sh]
      end)

    IO.puts("wrote #{length(rows)} rows to #{out_path}")
  end
end

PB4Main.run()
