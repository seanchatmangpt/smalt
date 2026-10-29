#!/usr/bin/env elixir
# SQLD-8 — bulk-ingest perf baseline worker (denominator for the ingestion path).
#
# AR-BENCH-01 aggregate model: wall via :erlang.monotonic_time deltas, paired
# rounds, min-of-3; the measured body runs in an isolated worker OS process
# (plain `elixir`, no Mix in the hot path, AR-BENCH-05); peak memory = OS
# max-RSS of the worker (/usr/bin/time -l), not :erlang.memory (banned in
# AR-BENCH-01/02 fences). No fixed sleeps anywhere.
#
# Subcommands:
#   gen-dump <path> <rows>        — deterministic pg COPY-format dump
#   rows-csv <path> <rows>        — same rows rendered directly as CSV
#   converter-round <dump> <csv> <db> — SqlIngest parse -> CSV -> duckdb
#                    COPY into ocel_events + per-activity aggregate projection
#   direct-round <csv> <db>       — duckdb read_csv, same projection
# Each round subcommand prints ROUND-RESULT wall_ms=<int> rows=<int>.

defmodule SqlD8 do
  @seed 20261021
  @activities ["freeze", "convey", "palletize"]

  defp next(state, mod) do
    s = rem(state * 6_364_136_223_846_793_005 + 1_442_695_040_888_963_407, 2 ** 64)
    {s, rem(s, mod)}
  end

  def rows!(count) do
    for i <- 1..count do
      {s1, a} = next(@seed + i * 4, 3)
      {s2, obj} = next(s1, 200)
      {s3, temp} = next(s2, 1500)
      {s4, dur} = next(s3, 30_000)
      {s5, ts} = next(s4, 1_000_000_000)

      {i, 1_700_000_000 + ts, Enum.at(@activities, a), "obj_" <> Integer.to_string(obj),
       temp / 100.0, dur}
    end
  end

  def generate_dump(path, count) do
    t0 = now()

    body =
      rows!(count)
      |> Enum.map(fn {i, ts, act, obj, temp, dur} ->
        :erlang.iolist_to_binary([
          Integer.to_string(i), ?\t, Integer.to_string(ts), ?\t, act, ?\t,
          obj, ?\t, :erlang.float_to_binary(temp, decimals: 1), ?\t,
          Integer.to_string(dur)
        ])
      end)

    File.write!(path, [
      "-- SQLD-8 synthetic bulk dump (pg COPY text format), #{count} rows, seed 20261021\n",
      "CREATE TABLE events (event_id INTEGER, ts BIGINT, activity TEXT, object_id TEXT, temp REAL, duration BIGINT);\n",
      "COPY events (event_id, ts, activity, object_id, temp, duration) FROM stdin;\n",
      Enum.intersperse(body, ?\n),
      "\n\\.\n"
    ])

    {count, now() - t0, byte_size(File.read!(path))}
  end

  def rows_csv(path, count) do
    t0 = now()

    body =
      rows!(count)
      |> Enum.map(fn {i, ts, act, obj, temp, dur} ->
        :erlang.iolist_to_binary([
          Integer.to_string(i), ?, , Integer.to_string(ts), ?, , act, ?, ,
          obj, ?, , :erlang.float_to_binary(temp, decimals: 1), ?, ,
          Integer.to_string(dur)
        ])
      end)

    File.write!(path, [
      "event_id,ts,activity,object_id,temp,duration\n", Enum.intersperse(body, ?\n), "\n"
    ])

    now() - t0
  end

  def now, do: :erlang.monotonic_time(:millisecond)
end

case System.argv() do
  ["gen-dump", path, rows] ->
    {n, ms, bytes} = SqlD8.generate_dump(path, String.to_integer(rows))
    IO.puts("GEN-DUMP rows=#{n} wall_ms=#{ms} bytes=#{bytes}")

  ["rows-csv", path, rows] ->
    ms = SqlD8.rows_csv(path, String.to_integer(rows))
    IO.puts("ROWS-CSV wall_ms=#{ms}")

  ["converter-round", dump, csv, db] ->
    t0 = SqlD8.now()
    Code.eval_file(Path.expand("lib/smalt/sql_ingest.ex", File.cwd!()))
    {:ok, text} = File.read(dump)
    {:ok, tables} = Smalt.SqlIngest.parse_dump(text)
    %{columns: cols, rows: rows} = Map.fetch!(tables, "events")
    File.write!(csv, Smalt.SqlIngest.to_csv(cols, rows))

    projection_sql = """
    DROP TABLE IF EXISTS ocel_events;
    CREATE TABLE ocel_events (event_id INTEGER, ts BIGINT, activity VARCHAR, object_id VARCHAR, temp DOUBLE, duration BIGINT);
    INSERT INTO ocel_events SELECT * FROM read_csv_auto('#{csv}');
    DROP TABLE IF EXISTS activity_aggregate;
    CREATE TABLE activity_aggregate AS
      SELECT activity, COUNT(*) AS n, SUM(duration) AS dur_sum, ROUND(AVG(temp), 4) AS temp_avg, MAX(temp) AS temp_max
      FROM ocel_events GROUP BY activity ORDER BY activity;
    COPY (SELECT * FROM activity_aggregate) TO '#{db}.agg.csv' (HEADER, DELIMITER ',');
    """

    {out, 0} = System.cmd("duckdb", [db, "-c", projection_sql], stderr_to_stdout: true)
    wall = SqlD8.now() - t0
    agg = File.read!(db <> ".agg.csv")
    rows_n = length(rows)
    IO.puts("ROUND-RESULT wall_ms=#{wall} rows=#{rows_n}")
    IO.puts("AGG-BEGIN\n#{agg}AGG-END")

  ["direct-round", csv, db] ->
    t0 = SqlD8.now()

    projection_sql = """
    DROP TABLE IF EXISTS ocel_events;
    CREATE TABLE ocel_events AS SELECT * FROM read_csv_auto('#{csv}');
    DROP TABLE IF EXISTS activity_aggregate;
    CREATE TABLE activity_aggregate AS
      SELECT activity, COUNT(*) AS n, SUM(duration) AS dur_sum, ROUND(AVG(temp), 4) AS temp_avg, MAX(temp) AS temp_max
      FROM ocel_events GROUP BY activity ORDER BY activity;
    COPY (SELECT * FROM activity_aggregate) TO '#{db}.agg.csv' (HEADER, DELIMITER ',');
    """

    {out, 0} = System.cmd("duckdb", [db, "-c", projection_sql], stderr_to_stdout: true)
    wall = SqlD8.now() - t0
    IO.puts("ROUND-RESULT wall_ms=#{wall} rows=100000")
    IO.puts("AGG-BEGIN\n#{File.read!(db <> ".agg.csv")}AGG-END")

  _ ->
    IO.puts("usage: sqld8_ingest_baseline.exs gen-dump|rows-csv|converter-round|direct-round ...")
    System.halt(2)
end
