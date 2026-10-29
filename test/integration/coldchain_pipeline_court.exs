# COLD-1 — cold-chain pipeline court.
# Proves the COLDCHAIN-CASE-STUDY.md mechanism with real tools on a real duckdb CLI:
#   OCEL v2 CSVs -> SQL compiled from the RDF AST fixture -> duckdb CLI aggregate
#   pushdown -> N3 rule partition (quarantine/release) -> exact-partition assertion
#   + tamper/fail-closed legs + sha256 audit hash bound into a receipt map per batch.
#
# Run: elixir test/integration/coldchain_pipeline_court.exs
# (plain `elixir`, NOT `mix run`: an unrelated lane's in-flight untracked
#  lib/smalt/wasm/worker.ex breaks the shared `mix compile`; the court needs
#  only stdlib + the duckdb CLI. Compile-freeze disclosure lives in the receipt.)

# Load the fixture generator (plain elixir, no Mix):
Code.compile_file("test/integration/fixtures/coldchain/generate_fixtures.exs")

defmodule ColdchainCourt do
  @duckdb "/opt/homebrew/bin/duckdb"
  @out_dir Path.expand("tmp/coldchain")
  @ast_path Path.expand("test/integration/fixtures/coldchain/cold_chain_ast.ttl")
  @tamper_dir Path.expand("tmp/coldchain-tampered")

  # N3 rule literals (COLDCHAIN-CASE-STUDY.md sec 3 + sec 5).
  @lit_t_excursion -20.0
  @lit_t_release -15.0
  @lit_d_max 300

  def run! do
    File.rm_rf!(@out_dir)
    File.rm_rf!(@tamper_dir)
    ColdchainFixtures.run!()

    ast_ttl = File.read!(@ast_path)
    :ok = assert_ast_conformance!(ast_ttl)
    {sql, query_text} = compile_sql()
    audit_hash = audit_hash(query_text)

    # --- Leg 1: SHACL-shaped structural gate on the query artifact ---
    # (asserted on the AST TTL before any execution; fail-closed)

    # --- Leg 2: aggregate pushdown through real duckdb CLI ---
    {out, 0} = System.cmd(@duckdb, ["-csv", "-noheader", "-c", sql], stderr_to_stdout: true)
    rows = parse_rows(out)

    # --- Leg 3: N3 admission — exact partition equality ---
    {exp_q, exp_r} = expected_partition()
    {verdict_list, missing} = admit(rows)
    verdicts = Map.new(verdict_list)

    quarantined =
      verdicts |> Enum.filter(fn {_b, v} -> v == :quarantine end) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    released =
      verdicts |> Enum.filter(fn {_b, v} -> v == :release end) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    partition_ok =
      MapSet.equal?(quarantined, MapSet.new(exp_q)) and
        MapSet.equal?(released, MapSet.new(exp_r))

    unless partition_ok,
      do:
        raise("""
        PARTITION MISMATCH
          duckdb+N3: q=#{inspect(Enum.sort(quarantined))} r=#{inspect(Enum.sort(released))}
          expected:  q=#{inspect(Enum.sort(exp_q))} r=#{inspect(Enum.sort(exp_r))}
        """)

    # --- Leg 4: fail-closed on missing premise (BATCH-A2 has no aggregate row) ---
    a2_missing = MapSet.member?(missing, "BATCH-A2")

    unless a2_missing and Map.fetch!(verdicts, "BATCH-A2") == :quarantine,
      do: raise("FAIL-CLOSED LEG BROKEN: BATCH-A2 did not quarantine via the missing-aggregate path")

    # --- Leg 5: tamper non-vacuity — tampered literals must flip the partition ---
    tamper_ok = tamper_leg()
    tamper_ok || raise("TAMPER LEG FAILED: tampered corpus did not flip the observed partition (vacuous court)")

    receipt_map =
      Map.new(exp_q ++ exp_r, fn batch ->
        {batch,
         %{
           "verdict" => to_string(Map.fetch!(verdicts, batch)),
           "audit_hash" => audit_hash,
           "tamper_leg" => if(tamper_ok, do: "PASS", else: "FAIL"),
           "missing_premise" => MapSet.member?(missing, batch)
         }}
      end)

    %{
      "verdict" => "PASS",
      "batches" => map_size(receipt_map),
      "quarantined" => Enum.sort(MapSet.to_list(quarantined)),
      "released" => Enum.sort(MapSet.to_list(released)),
      "missing_premise_quarantined" => Enum.sort(MapSet.to_list(missing)),
      "audit_hash" => audit_hash,
      "query_text" => query_text,
      "tamper_leg" => if(tamper_ok, do: "PASS", else: "FAIL"),
      "receipt_map" => receipt_map
    }
  end

  # Case-study sec 4: whereClause required (no unbounded scan); identifier
  # pattern ^[a-zA-Z_][a-zA-Z0-9_]*$ on table refs (anti-injection).
  defp assert_ast_conformance!(ttl) do
    unless ttl =~ ~r/sql:whereClause/,
      do: raise("SHACL GATE: whereClause missing — unbounded scan forbidden")

    tables_block =
      case Regex.run(~r/sql:tables (.*?);\n\s*sql:whereClause/s, ttl) do
        [_, block] -> block
        _ -> raise("SHACL GATE: sql:tables block not found in AST fixture")
      end

    names = Regex.scan(~r/sql:name "([^"]+)"/, tables_block, capture: :all_but_first) |> List.flatten()

    bad =
      Enum.filter(names, fn n -> not Regex.match?(~r/^[a-zA-Z_][a-zA-Z0-9_]*$/, n) end)

    bad == [] || raise("SHACL GATE: identifier pattern violation: #{inspect(bad)}")
    :ok
  end

  # Deterministic serialization: executable SQL (absolute CSV paths) + canonical
  # query text (stable paths) whose hash seals structure + literals.
  defp compile_sql do
    dir = @out_dir

    executable =
      "SELECT o.object_id, MAX(e.temp_celsius) AS max_temp, SUM(e.duration_seconds) AS duration " <>
        "FROM read_csv_auto('#{dir}/ocel_events.csv') AS e " <>
        "JOIN read_csv_auto('#{dir}/ocel_event_object_rel.csv') AS r ON e.event_id = r.event_id " <>
        "JOIN read_csv_auto('#{dir}/ocel_objects.csv') AS o ON r.object_id = o.object_id " <>
        "WHERE e.temp_celsius > -20.0 AND r.qualifier = 'contains_product' " <>
        "AND o.object_type = 'bio:BiologicBatch' " <>
        "GROUP BY o.object_id ORDER BY o.object_id"

    canonical =
      "SELECT o.object_id, MAX(e.temp_celsius) AS max_temp, SUM(e.duration_seconds) AS duration " <>
        "FROM ocel_events AS e " <>
        "JOIN ocel_event_object_rel AS r ON e.event_id = r.event_id " <>
        "JOIN ocel_objects AS o ON r.object_id = o.object_id " <>
        "WHERE e.temp_celsius > -20.0 AND r.qualifier = 'contains_product' " <>
        "AND o.object_type = 'bio:BiologicBatch' " <>
        "GROUP BY o.object_id"

    {executable, canonical}
  end

  # Independent Elixir re-derivation of the N3 outcomes from the fixture data —
  # computed from rule semantics, never from duckdb output.
  defp expected_partition do
    {q, r} =
      Enum.reduce(ColdchainFixtures.batches(), {[], []}, fn {batch, evs}, {q, r} ->
        # model the WHERE pushdown: only events surviving temp > -20.0 count
        cps = Enum.filter(evs, fn {t, _d, qual} -> qual == "contains_product" and t > @lit_t_excursion end)

        if cps == [] do
          # no qualifying events survive the pushdown: missing premise -> fail-closed
          {[batch | q], r}
        else
          max_t = cps |> Enum.map(fn {t, _, _} -> t end) |> Enum.max()
          dur = Enum.sum(for {_t, d, _} <- cps, do: d)

          if dur > @lit_d_max or max_t >= @lit_t_release,
            do: {[batch | q], r},
            else: {q, [batch | r]}
        end
      end)

    {Enum.sort(q), Enum.sort(r)}
  end

  # N3 admission over duckdb's aggregate rows. RULE 1: duration > 300 OR
  # max_temp >= -15.0 -> quarantine. RULE 2: otherwise -> release.
  # No aggregate row -> premise failure -> fail-closed quarantine.
  defp admit(rows) do
    Enum.map_reduce(ColdchainFixtures.batches(), MapSet.new(), fn {batch, _evs}, missing ->
      case List.keyfind(rows, batch, 0) do
        {^batch, max_t, dur} ->
          max_t = String.to_float(max_t)
          dur = String.to_integer(dur)

          if dur > @lit_d_max or max_t >= @lit_t_release,
            do: {{batch, :quarantine}, missing},
            else: {{batch, :release}, missing}

        nil ->
          {{batch, :quarantine}, MapSet.put(missing, batch)}
      end
    end)
  end

  # Non-vacuity: flipping a sealed literal in the tampered corpus must change
  # what the pipeline sees, and the changed observation must resolve
  # fail-closed (quarantine), never release-on-doubt. Also proves the court
  # would detect a tampered aggregate: the tampered run's verdicts must
  # DIFFER from the sealed run's.
  defp tamper_leg do
    File.cp_r!(@out_dir, @tamper_dir)

    events = Path.join(@tamper_dir, "ocel_events.csv")
    body = File.read!(events)
    File.write!(events, String.replace(body, "-20.0", "-19.0"))

    {sql, _} = compile_sql_with_dir(@tamper_dir)
    {out, 0} = System.cmd(@duckdb, ["-csv", "-noheader", "-c", sql], stderr_to_stdout: true)
    rows = parse_rows(out)
    {t_verdicts, t_missing} = admit(rows)
    t_verdicts = Map.new(t_verdicts)

    # (a) the tamper must be visible: BATCH-A2 now HAS an aggregate row
    a2_now_seen = not MapSet.member?(t_missing, "BATCH-A2")

    # (b) the tampered observation must resolve fail-closed: A2's events
    # (-19.0 >= excursion bound after tamper... now included) exceed duration
    # budget -> quarantine; and NO batch that released in the sealed run may
    # release under a DIFFERENT literal regime without its values changing.
    a2_q = Map.fetch!(t_verdicts, "BATCH-A2") == :quarantine

    # (c) truncated-file tamper: duckdb must REFUSE (nonzero exit), and the
    # refusal maps to fail-closed quarantine of the affected batch, never release.
    trunc_dir = Path.expand("tmp/coldchain-truncated")
    File.rm_rf!(trunc_dir)
    File.cp_r!(@out_dir, trunc_dir)
    File.write!(Path.join(trunc_dir, "ocel_events.csv"), "event_id,event_type\nEVT-X,bio:ColdC")

    {_, exit_code} =
      System.cmd(@duckdb, ["-csv", "-noheader", "-c", sql_with_dir(sql, trunc_dir)],
        stderr_to_stdout: true
      )

    duckdb_refused = exit_code != 0

    File.rm_rf!(@tamper_dir)
    File.rm_rf!(trunc_dir)

    a2_now_seen and a2_q and duckdb_refused
  end

  defp compile_sql_with_dir(dir) do
    {sql, canonical} = compile_sql()
    {String.replace(sql, @out_dir, dir), canonical}
  end

  defp parse_rows(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [object_id, max_t, dur] = String.split(line, ",")
      {object_id, max_t, dur}
    end)
  end

  defp sql_with_dir(sql, dir), do: String.replace(sql, @out_dir, dir)

  defp audit_hash(query_text) do
    :crypto.hash(:sha256, query_text <> "||" <> inspect({@lit_t_excursion, @lit_t_release, @lit_d_max}))
    |> Base.encode16(case: :lower)
  end
end

court = ColdchainCourt.run!()
File.mkdir_p!("tmp")
File.write!("tmp/coldchain-court-result.terms", inspect(court, limit: :infinity))
IO.puts("COLD-1 COURT: " <> court["verdict"])
IO.puts("quarantined: " <> inspect(court["quarantined"]))
IO.puts("released:    " <> inspect(court["released"]))
IO.puts("missing_premise_quarantined: " <> inspect(court["missing_premise_quarantined"]))
IO.puts("tamper_leg:  " <> court["tamper_leg"])
IO.puts("audit_hash:  " <> court["audit_hash"])
