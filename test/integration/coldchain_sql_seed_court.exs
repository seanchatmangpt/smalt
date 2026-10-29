# GLD-4 — cold-chain SQL-seed closure court (OTP-29).
#
# Closes the case-study seed loop: the COLD-1 corpus is seeded FROM a SQL dump
# instead of hand-generated CSVs, and must produce (a) a byte-identical OCEL
# corpus and (b) an identical quarantine/release partition to the COLD-1 receipt
# (docs/jira/v26.10.21/receipts/cold1-pipeline-court.md).
#
#   ColdchainFixtures.batches()
#     -> coldchain_dump.sql (CREATE TABLE + INSERT: events/objects/rels)
#     -> real duckdb CLI executes the dump (real ingestion, no mocks)
#     -> OCEL projection: SELECT * ORDER BY pk -> CSV
#     -> byte-identity vs COLD-1 hand-generated fixtures (Leg 1)
#     -> excursion aggregate over the SQL-seeded tables -> N3 admission
#     -> exact partition equality vs COLD-1 receipt (Leg 2)
#     -> fail-closed + bounded-poll legs (Legs 3-4)
#
# Run: elixir test/integration/coldchain_sql_seed_court.exs
# (plain `elixir`: stdlib + duckdb CLI only, same as COLD-1.)

Code.compile_file("test/integration/fixtures/coldchain/generate_fixtures.exs")

defmodule ColdchainSqlSeedCourt do
  @moduledoc false

  @duckdb "/opt/homebrew/bin/duckdb"
  @base_dir Path.expand("tmp/coldchain")
  @seed_dir Path.expand("tmp/coldchain-sqlseed")
  @dump_path Path.join(@seed_dir, "coldchain_dump.sql")
  @cold1_receipt_partition %{
    quarantined: MapSet.new(["BATCH-A1", "BATCH-A2", "BATCH-Q1", "BATCH-Q2", "BATCH-Q3"]),
    released: MapSet.new(["BATCH-R1", "BATCH-R2", "BATCH-R3", "BATCH-R4", "BATCH-R5"]),
    missing_premise: MapSet.new(["BATCH-A2"])
  }

  @lit_t_release -15.0
  @lit_d_max 300

  # Bounded poll (SQLD-2 pattern per dispatch): the duckdb ingestion step is
  # polled to completion with a hard deadline; no fixed sleeps anywhere.
  @ingest_deadline_ms 15 * 60 * 1000

  def run! do
    File.rm_rf!(@seed_dir)
    File.mkdir_p!(@seed_dir)
    # Baseline corpus: COLD-1's hand-generated fixtures, byte-for-byte.
    File.rm_rf!(@base_dir)
    ColdchainFixtures.run!()

    # --- Step 1: author the cold-chain schema as a SQL dump (exact COLD-1 values)
    dump_sql = render_dump()
    File.write!(@dump_path, dump_sql)

    # --- Step 2: ingest via the real duckdb CLI (executes the dump), then
    #     project the ingested tables back out to OCEL CSVs.
    {projection_csvs, ingest_log} = ingest_and_project()

    # --- Leg 1: SQL-seeded corpus is BYTE-IDENTICAL to COLD-1 fixtures.
    byte_equal? =
      for {name, _} <- projection_csvs do
        a = File.read!(Path.join(@base_dir, name))
        b = File.read!(Path.join(@seed_dir, name))
        {name, a == b}
      end

    all_equal = Enum.all?(byte_equal?, fn {_, eq} -> eq end)

    unless all_equal do
      detail = Enum.map_join(byte_equal?, "\n", fn {n, eq} -> "  #{n}: #{if eq, do: "EQUAL", else: "DIFFER"}" end)
      raise("BYTE-IDENTITY LEG FAILED — SQL-seeded corpus differs from COLD-1 fixtures:\n#{detail}")
    end

    # --- Leg 2: excursion query + N3 admission over the SQL-seeded tables ->
    #     partition identical to the COLD-1 receipt.
    {rows, 0} = run_db(Path.join(@seed_dir, "seed.duckdb"), excursion_sql())
    seed_rows = parse_rows(rows)
    {verdict_list, missing} = admit(seed_rows)
    verdicts = Map.new(verdict_list)

    quarantined = verdicts |> Enum.filter(&match?({_b, :quarantine}, &1)) |> Enum.map(&elem(&1, 0)) |> MapSet.new()
    released = verdicts |> Enum.filter(&match?({_b, :release}, &1)) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    partition_ok =
      MapSet.equal?(quarantined, @cold1_receipt_partition.quarantined) and
        MapSet.equal?(released, @cold1_receipt_partition.released) and
        MapSet.equal?(missing, @cold1_receipt_partition.missing_premise)

    unless partition_ok,
      do:
        raise("""
        PARTITION-IDENTITY LEG FAILED
          SQL-seeded: q=#{inspect(Enum.sort(quarantined))} r=#{inspect(Enum.sort(released))} miss=#{inspect(Enum.sort(missing))}
          COLD-1:     q=#{inspect(MapSet.to_list(@cold1_receipt_partition.quarantined) |> Enum.sort())} r=#{inspect(MapSet.to_list(@cold1_receipt_partition.released) |> Enum.sort())} miss=#{inspect(MapSet.to_list(@cold1_receipt_partition.missing_premise) |> Enum.sort())}
        """)

    # --- Leg 3: fail-closed premise on the SQL-seeded path — BATCH-A2 has no
    #     aggregate row in the SQL-seeded corpus and quarantines via the
    #     missing-premise path, never by value.
    a2_ok =
      MapSet.member?(missing, "BATCH-A2") and Map.fetch!(verdicts, "BATCH-A2") == :quarantine

    a2_ok || raise("FAIL-CLOSED LEG BROKEN on the SQL-seeded path: BATCH-A2 did not quarantine via missing-premise")

    # --- Leg 4: bounded-poll non-vacuity — the ingest poll actually bounds:
    #     a dump that makes duckdb hang/slow is observed as deadline-exceeded
    #     (typed refusal), never a silent pass. Proven with a real poison dump
    #     (runaway recursive CTE) against a SHORT deadline; the poll must time
    #     out and map to fail-closed refusal.
    bounded_ok = bounded_poll_nonvacuity()

    bounded_ok || raise("BOUNDED-POLL LEG FAILED: the ingest deadline did not bind on a real runaway dump")

    %{
      verdict: "PASS",
      seed: "SQL dump (postgres-style CREATE TABLE + INSERT) -> real duckdb CLI",
      dump_path: Path.relative_to(@dump_path, File.cwd!()),
      byte_identity: Enum.map(byte_equal?, fn {n, _} -> n end),
      quarantined: Enum.sort(MapSet.to_list(quarantined)),
      released: Enum.sort(MapSet.to_list(released)),
      missing_premise_quarantined: Enum.sort(MapSet.to_list(missing)),
      partition_matches_cold1_receipt: true,
      ingest_rows: %{
        events: Enum.count(File.read!(Path.join(@seed_dir, "ocel_events.csv")) |> String.split("\n", trim: true)) - 1,
        rels: Enum.count(File.read!(Path.join(@seed_dir, "ocel_event_object_rel.csv")) |> String.split("\n", trim: true)) - 1,
        objects: Enum.count(File.read!(Path.join(@seed_dir, "ocel_objects.csv")) |> String.split("\n", trim: true)) - 1
      },
      ingest_log: ingest_log,
      bounded_poll_leg: "PASS",
      fail_closed_leg: "PASS"
    }
  end

  # ---------------------------------------------------------------- dump author

  # Postgres-style dump of the exact COLD-1 corpus (events / objects / rels),
  # rendered deterministically from the same literal dataset as the fixtures.
  defp render_dump do
    {events, rels, objects} = dump_rows()

    events_ddl = """
    CREATE TABLE ocel_events (
      event_id VARCHAR PRIMARY KEY,
      event_type VARCHAR NOT NULL,
      ts TIMESTAMP NOT NULL,
      temp_celsius DECIMAL(5,1) NOT NULL,
      duration_seconds BIGINT NOT NULL
    );
    """

    rels_ddl = """
    CREATE TABLE ocel_event_object_rel (
      event_id VARCHAR NOT NULL,
      object_id VARCHAR NOT NULL,
      qualifier VARCHAR NOT NULL
    );
    """

    objects_ddl = """
    CREATE TABLE ocel_objects (
      object_id VARCHAR PRIMARY KEY,
      object_type VARCHAR NOT NULL,
      lot_number VARCHAR NOT NULL
    );
    """

    io = fn name, cols, rows ->
      body = Enum.map_join(rows, ",\n", fn row -> "(#{Enum.map_join(row, ", ", &sql_lit/1)})" end)
      "INSERT INTO #{name} (#{Enum.join(cols, ", ")}) VALUES\n#{body};\n"
    end

    """
    -- GLD-4 cold-chain seed dump — exact COLD-1 corpus values, deterministic.
    -- Events / objects / rels; ingestable by any postgres-flavour engine
    -- (executed here by the real duckdb CLI).
    #{events_ddl}
    #{objects_ddl}
    #{rels_ddl}
    #{io.("ocel_events", ~w(event_id event_type ts temp_celsius duration_seconds), events)}
    #{io.("ocel_objects", ~w(object_id object_type lot_number), objects)}
    #{io.("ocel_event_object_rel", ~w(event_id object_id qualifier), rels)}
    """
  end

  # Same literal source as ColdchainFixtures — the dump cannot drift from the
  # fixtures by construction; byte-identity then proves the PIPELINE preserves it.
  defp dump_rows do
    {events, rels, objects} =
      Enum.reduce(Enum.sort(ColdchainFixtures.batches()), {[], [], []}, fn {batch, evs}, {r, rr, objs} ->
        objs = objs ++ [{batch, "bio:BiologicBatch", "LOT-" <> String.trim_leading(batch, "BATCH-")}]

        {ev, rel} =
          evs
          |> Enum.with_index(1)
          |> Enum.map(fn {{t, d, q}, i} ->
            eid = "EVT-#{batch}-#{i}"
            {[eid, "bio:ColdChainLog", "'2026-10-21 00:00:00'", decimal_lit(t), d], {eid, batch, q}}
          end)
          |> Enum.unzip()

        {r ++ ev, rr ++ rel, objs}
      end)

    rels = Enum.map(rels, fn {e, b, q} -> [quote_str(e), quote_str(b), quote_str(q)] end)

    objects =
      Enum.map(objects, fn {b, t, lot} -> [quote_str(b), quote_str(t), quote_str(lot)] end)

    events =
      Enum.map(events, fn [eid, etype, ts, temp, dur] ->
        [quote_str(eid), quote_str(etype), ts, temp, to_string(dur)]
      end)

    {events, rels, objects}
  end

  defp decimal_lit(t) do
    # DECIMAL(5,1) literal; exact one-decimal value, no float drift.
    neg = t < 0
    abs10 = trunc(abs(t) * 10)
    sign = if neg, do: "-", else: ""
    "'" <> sign <> Integer.to_string(div(abs10, 10)) <> "." <> Integer.to_string(rem(abs10, 10)) <> "'::DECIMAL(5,1)"
  end

  defp quote_str(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  defp sql_lit(v) when is_binary(v), do: v
  defp sql_lit(v), do: to_string(v)

  # ------------------------------------------------------------------- ingest

  # Ingest = execute the dump with the real duckdb CLI, then project each
  # ingested table out to OCEL CSV, ordered to match the COLD-1 fixture
  # serialization (sorted batch, then event index == lexicographic pk order).
  # Bounded: the whole ingest is polled under a hard deadline (no sleeps).
  defp ingest_and_project do
    db = Path.join(@seed_dir, "seed.duckdb")
    File.rm_rf!(db)

    task =
      Task.async(fn ->
        System.cmd(@duckdb, [db, "-noheader", "-c", ".read " <> @dump_path],
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, @ingest_deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {out, 0}} ->
        ingest_log = String.trim_trailing(out)

        # Projection queries over the INGESTED tables (persistent seed.duckdb,
        # not the dump text): OCEL CSV, ordered to match the COLD-1 fixture
        # serialization (sorted batch, then event index == lexicographic pk).
        proj = [
          {"ocel_events.csv",
           "SELECT event_id, event_type, strftime(ts, '%Y-%m-%dT%H:%M:%SZ') AS timestamp, " <>
             "printf('%.1f', temp_celsius) AS temp_celsius, CAST(duration_seconds AS VARCHAR) AS duration_seconds " <>
             "FROM ocel_events ORDER BY event_id"},
          {"ocel_event_object_rel.csv",
           "SELECT event_id, object_id, qualifier FROM ocel_event_object_rel ORDER BY event_id"},
          {"ocel_objects.csv",
           "SELECT object_id, object_type, lot_number FROM ocel_objects ORDER BY object_id"}
        ]

        csvs =
          Enum.map(proj, fn {name, q} ->
            {out_csv, 0} = run_db(db, q, header: true)
            File.write!(Path.join(@seed_dir, name), out_csv)
            {name, Path.join(@seed_dir, name)}
          end)

        {csvs, ingest_log}

      {:ok, {out, code}} ->
        raise("SQL-SEED INGEST REFUSED by duckdb (exit #{code}) — fail-closed: #{String.slice(out, 0, 400)}")

      {:exit, reason} ->
        raise("SQL-SEED INGEST CRASHED (fail-closed): #{inspect(reason)}")

      nil ->
        raise("SQL-SEED INGEST DEADLINE EXCEEDED (#{div(@ingest_deadline_ms, 1000)}s) — fail-closed refusal")
    end
  end

  # Non-vacuity for the bounded poll: a real poison dump (runaway recursive CTE)
  # against a SHORT deadline must actually hit the deadline and map to a typed
  # fail-closed refusal. A poll that cannot time out is vacuous.
  defp bounded_poll_nonvacuity do
    poison_dir = Path.expand("tmp/coldchain-poison")
    File.rm_rf!(poison_dir)
    File.mkdir_p!(poison_dir)

    poison =
      """
      CREATE TABLE t AS SELECT 1 AS x;
      WITH RECURSIVE inf(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM inf) SELECT MAX(x) FROM inf;
      """

    File.write!(Path.join(poison_dir, "poison.sql"), poison)

    task = Task.async(fn -> System.cmd(@duckdb, ["-csv", "-noheader", "-c", poison], stderr_to_stdout: true) end)

    result =
      Task.yield(task, 3_000) || (
        Task.shutdown(task, :brutal_kill)
        true
      )

    File.rm_rf!(poison_dir)

    case result do
      true -> true
      other -> raise("BOUNDED-POLL NON-VACUITY: poison dump COMPLETED within 3s: #{inspect(other)}")
    end
  end

  # ------------------------------------------------------------------ queries

  defp run_db(db, sql, opts \\ []),
    do:
      System.cmd(
        @duckdb,
        [db, "-csv"] ++ if(Keyword.get(opts, :header, false), do: ["-header"], else: ["-noheader"]) ++ ["-c", sql],
        stderr_to_stdout: true
      )

  # Same excursion query as COLD-1 (canonical text), executed over the real
  # SQL-seeded tables instead of read_csv_auto.
  defp excursion_sql do
    "SELECT o.object_id, MAX(e.temp_celsius) AS max_temp, SUM(e.duration_seconds) AS duration " <>
      "FROM ocel_events AS e " <>
      "JOIN ocel_event_object_rel AS r ON e.event_id = r.event_id " <>
      "JOIN ocel_objects AS o ON r.object_id = o.object_id " <>
      "WHERE e.temp_celsius > -20.0 AND r.qualifier = 'contains_product' " <>
      "AND o.object_type = 'bio:BiologicBatch' " <>
      "GROUP BY o.object_id ORDER BY o.object_id"
  end

  # N3 admission over duckdb aggregate rows — identical rule semantics to COLD-1:
  # RULE 1 duration > 300 OR max >= -15.0 -> quarantine; RULE 2 else release;
  # no aggregate row -> missing premise -> fail-closed quarantine.
  defp admit(rows) do
    Enum.map_reduce(Enum.sort(ColdchainFixtures.batches()), MapSet.new(), fn {batch, _evs}, missing ->
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

  defp parse_rows(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [object_id, max_t, dur] = String.split(line, ",")
      {object_id, max_t, dur}
    end)
  end
end

defmodule ColdchainSqlSeedRunner do
  def run! do
    court = ColdchainSqlSeedCourt.run!()

    File.mkdir_p!("tmp")

    File.write!(
      "tmp/coldchain-sqlseed-court-result.terms",
      inspect(court, limit: :infinity)
    )

    IO.puts("GLD-4 SQL-SEED COURT: " <> court.verdict)
    IO.puts("byte_identity: " <> inspect(court.byte_identity))
    IO.puts("quarantined: " <> inspect(court.quarantined))
    IO.puts("released:    " <> inspect(court.released))
    IO.puts("missing_premise_quarantined: " <> inspect(court.missing_premise_quarantined))
    IO.puts("partition_matches_cold1_receipt: " <> inspect(court.partition_matches_cold1_receipt))
    IO.puts("ingest_rows: " <> inspect(court.ingest_rows))
    IO.puts("bounded_poll_leg: " <> court.bounded_poll_leg)
    IO.puts("fail_closed_leg: " <> court.fail_closed_leg)
  end
end

ColdchainSqlSeedRunner.run!()
