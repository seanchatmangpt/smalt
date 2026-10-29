# SQLD-2 — postgres-dump ingestion court (real duckdb CLI).
# Corpus: deterministic synthetic pg_dump (500 rows, COPY format) from
# test/integration/fixtures/sqld2/generate_dump.exs.
# Run: MIX_BUILD_ROOT=_build-sqld2 mix test test/integration/sqld2_sql_ingest_court_test.exs
# No mocks, no sleeps, no Jason — stdlib only.

defmodule Sqld2.Court do
  @duckdb "/opt/homebrew/bin/duckdb"
  @dir Path.expand("tmp/sqld2", File.cwd!())
  @dump Path.join(@dir, "orders_dump.sql")
  @counts_path Path.join(@dir, "expected_counts.terms")
  @csv_dir Path.join(@dir, "csv")
  @ocel_dir Path.join(@dir, "ocel")
  @poison "orders; DROP TABLE orders;--"
  @db Path.join(@dir, "duck.db")

  def run do
    File.rm_rf!(@db)
    File.rm_rf!(@db <> ".wal")
    File.rm_rf!(@csv_dir)
    File.rm_rf!(@ocel_dir)
    File.mkdir_p!(@csv_dir)
    File.mkdir_p!(@ocel_dir)

    dump = File.read!(@dump)
    {expected, _} = Code.eval_string(File.read!(@counts_path))

    # Leg 1: scanner discovery — the fallback premise is exercised, not assumed.
    {out1, exit1} =
      System.cmd(@duckdb, ["-c", "LOAD postgres; SELECT * FROM read_pg_copy('#{@dump}')"],
        stderr_to_stdout: true
      )

    true = exit1 != 0 and String.contains?(out1, "read_pg_copy does not exist")
    IO.puts("leg1 scanner: read_pg_copy refused as expected -> typed fallback (Elixir COPY parse + CSV load)")

    # Leg 2: converter round-trip.
    {:ok, tables} = Smalt.SqlIngest.parse_dump(dump)
    got = tables |> Enum.map(fn {t, %{rows: rows}} -> {t, length(rows)} end) |> Enum.sort()
    ^expected = got

    expect_cols = %{
      "customers" => ["customer_id", "name", "region", "credit_limit"],
      "orders" => ["order_id", "customer_id", "amount", "status", "created_at"],
      "order_events" => ["event_id", "order_id", "event_type", "value", "duration_s", "occurred_at"]
    }

    Enum.each(expect_cols, fn {t, cols} ->
      true = tables[t].columns == cols or raise("column drift in #{t}: #{inspect(tables[t].columns)}")
    end)

    IO.puts("leg2 converter: counts=#{inspect(got)} (500 rows), columns exact")

    # Leg 2b: unterminated COPY block fails closed.
    {:error, :unterminated_copy_block} = Smalt.SqlIngest.parse_dump("COPY t (a) FROM stdin;\n1\n")
    IO.puts("leg2b unterminated COPY block: refused")

    # Leg 3: CSV emit + real duckdb load + round-trip counts + integrity.
    for t <- ["customers", "orders", "order_events"] do
      File.write!(Path.join(@csv_dir, t <> ".csv"), Smalt.SqlIngest.to_csv(tables[t].columns, tables[t].rows))
    end

    ddl = """
    CREATE TABLE customers AS
      SELECT * FROM read_csv('#{@csv_dir}/customers.csv', header = true,
        types = {'customer_id': 'VARCHAR', 'name': 'VARCHAR', 'region': 'VARCHAR', 'credit_limit': 'INTEGER'});
    CREATE TABLE orders AS
      SELECT * FROM read_csv('#{@csv_dir}/orders.csv', header = true,
        types = {'order_id': 'VARCHAR', 'customer_id': 'VARCHAR', 'amount': 'INTEGER', 'status': 'VARCHAR', 'created_at': 'TIMESTAMP'});
    CREATE TABLE order_events AS
      SELECT * FROM read_csv('#{@csv_dir}/order_events.csv', header = true,
        types = {'event_id': 'VARCHAR', 'order_id': 'VARCHAR', 'event_type': 'VARCHAR', 'value': 'DOUBLE', 'duration_s': 'INTEGER', 'occurred_at': 'TIMESTAMP'});
    """

    duck!(ddl)

    [[cn, onn, en, total]] = duck_rows(counter_sql())
    {120, 300, 80, 500} = {cn, onn, en, total}
    [[dord, devent, damt]] = duck_rows(integrity_sql())
    {0, 0, 0} = {dord, devent, damt}
    IO.puts("leg3 duckdb: 120/300/80 = 500 typed rows loaded; referential + domain integrity 0 violations")

    # Leg 4: OCEL v2 projection.
    ocel_ddl = """
    CREATE TABLE ocel_events AS
      SELECT e.event_id AS "ocel:id", e.event_type AS "ocel:activity", e.occurred_at AS "ocel:timestamp",
             e.order_id, e.value, e.duration_s
      FROM order_events e;
    CREATE TABLE ocel_objects AS
      SELECT customer_id AS id, 'customer' AS object_type FROM customers
      UNION ALL
      SELECT order_id, 'order' FROM orders;
    CREATE TABLE ocel_rels AS
      SELECT event_id AS source_id, order_id AS target_id, 'belongs_to' AS qualifier FROM order_events
      UNION ALL
      SELECT order_id, customer_id, 'placed_by' FROM orders;
    """

    duck!(ocel_ddl)

    [[ev, obj, rels]] = duck_rows(ocel_count_sql())
    {80, 420, 380} = {ev, obj, rels}

    [[dang]] = duck_rows(ocel_dangling_sql())
    0 = dang
    IO.puts("leg4 OCEL v2: 80 events / 420 objects / 380 rels, 0 dangling rels")

    duck!(ocel_copy_sql())

    files = File.ls!(@ocel_dir) |> Enum.sort()
    true = files == ["ocel_events.csv", "ocel_objects.csv", ocel_rels_file()]

    IO.puts("leg4 persist: tmp/sqld2/ocel/ triple written via real duckdb COPY")

    # Leg 5: excursion query vs independent Elixir re-derivation.
    {duck_exc, elixir_exc} = excursion(tables)
    true = duck_exc == elixir_exc or raise("excursion mismatch")

    duck_exc != [] or raise("non-vacuity: excursion set must be non-empty")

    IO.puts(
      "leg5 excursion: duckdb == Elixir re-derivation, n=#{length(duck_exc)} orders: #{Enum.map_join(duck_exc, ", ", &hd/1)}"
    )

    # Leg 6: SHACL-shaped gate.
    poison_block =
      "COPY public.#{@poison} (a, b) FROM stdin;\n1\t2\n\\.\n"

    {:error, {:injection_token, refused}} = Smalt.SqlIngest.parse_dump(dump <> "\n" <> poison_block)
    String.starts_with?(refused, "orders;") or raise("gate refused the wrong token: #{refused}")

    {:error, {:injection_token, _}} = Smalt.SqlIngest.parse_dump(poison_block)
    IO.puts("leg6 SHACL gate: injection-token table refused; whole-parse fail-closed (pattern-match assertion, acceptance raises)")

    audit = Base.encode16(:crypto.hash(:sha256, dump), case: :lower)

    IO.puts("""

    SQLD2 COURT: PASS
    dump: #{@dump}
    sha256: #{audit}
    rows: 500 (customers 120 / orders 300 / order_events 80)
    ocel: 80 events / 420 objects / 380 rels -> tmp/sqld2/ocel/
    excursion orders: #{length(duck_exc)}
    """)
  end

  # — Leg 5 bodies —
  defp excursion(tables) do
    sql =
      "SELECT o.order_id, MAX(e.value) AS max_value, SUM(e.duration_s) AS total_duration " <>
        "FROM order_events e JOIN orders o ON o.order_id = e.order_id " <>
        "WHERE e.event_type = 'payment_excursion' AND e.value > 75.0 " <>
        "GROUP BY o.order_id HAVING MAX(e.value) > 75.0 OR SUM(e.duration_s) > 300 " <>
        "ORDER BY o.order_id"

    duck_rows(sql)
    |> Enum.map(fn [oid, mx, sd] -> [oid, to_f(mx), as_int(sd)] end)
    |> then(fn duck_exc ->
      {duck_exc, elixir_excursion(tables)}
    end)
  end

  defp elixir_excursion(tables) do
    tables["order_events"].rows
    |> Enum.filter(fn [_, _, ty, v, _, _] -> ty == "payment_excursion" and to_f(v) > 75.0 end)
    |> Enum.group_by(fn [_, o | _] -> o end)
    |> Enum.map(fn {o, evs} ->
      mx = evs |> Enum.map(fn [_, _, _, v, _, _] -> to_f(v) end) |> Enum.max()
      sd = evs |> Enum.map(fn [_, _, _, _, d, _] -> String.to_integer(d) end) |> Enum.sum()
      [o, mx, sd]
    end)
    |> Enum.filter(fn [_o, mx, sd] -> mx > 75.0 or sd > 300 end)
    |> Enum.sort()
  end

  # — helpers —

  defp duck!(sql) do
    {out, 0} = System.cmd(@duckdb, [@db, "-c", sql], stderr_to_stdout: true)
    out
  end

  defp duck_rows(sql) do
    {out, 0} = System.cmd(@duckdb, ["-csv", "-noheader", @db, "-c", sql], stderr_to_stdout: true)
    rows = String.split(String.trim_trailing(out, "\n"), "\n") |> Enum.reject(&(&1 == ""))

    Enum.map(rows, fn line ->
      String.split(line, ",")
      |> Enum.map(fn f ->
        case Regex.match?(~r/^\d+$/, f) do
          true -> String.to_integer(f)
          false -> f
        end
      end)
    end)
  end

  defp to_f(v) when is_binary(v) do
    if String.contains?(v, "."), do: String.to_float(v), else: String.to_float(v <> ".0")
  end

  defp to_f(v) when is_integer(v), do: v * 1.0

  defp as_int(v) when is_integer(v), do: v
  defp as_int(v) when is_binary(v), do: String.to_integer(v)

  defp counter_sql do
    "SELECT (SELECT count(*) FROM customers), (SELECT count(*) FROM orders), (SELECT count(*) FROM order_events), (SELECT count(*) FROM customers) + (SELECT count(*) FROM orders) + (SELECT count(*) FROM order_events)"
  end

  defp integrity_sql do
    """
    SELECT
      (SELECT count(*) FROM orders o WHERE NOT EXISTS (SELECT 1 FROM customers c WHERE c.customer_id = o.customer_id)),
      (SELECT count(*) FROM order_events e WHERE NOT EXISTS (SELECT 1 FROM orders o WHERE o.order_id = e.order_id)),
      (SELECT count(*) FROM orders WHERE amount < 10 OR amount > 2000)
    """
  end

  defp ocel_count_sql do
    "SELECT (SELECT count(*) FROM ocel_events), (SELECT count(*) FROM ocel_objects), (SELECT count(*) FROM ocel_rels)"
  end

  defp ocel_dangling_sql do
    # a rel is well-formed when its source is a known event OR object and
    # its target is a known object
    """
    SELECT count(*) FROM ocel_rels r
    WHERE NOT (
      ((EXISTS (SELECT 1 FROM ocel_events e WHERE e."ocel:id" = r.source_id)
        OR EXISTS (SELECT 1 FROM ocel_objects o WHERE o.id = r.source_id))
       AND EXISTS (SELECT 1 FROM ocel_objects o WHERE o.id = r.target_id))
    )
    """
  end

  defp ocel_copy_sql do
    """
    COPY (SELECT r.source_id, r.qualifier, r.target_id FROM ocel_rels r ORDER BY 1,2,3)
      TO '#{@ocel_dir}/ocel_rels.csv' (HEADER, DELIMITER ',');
    COPY (SELECT o.id, o.object_type FROM ocel_objects o ORDER BY id)
      TO '#{@ocel_dir}/ocel_objects.csv' (HEADER, DELIMITER ',');
    COPY (SELECT e."ocel:id", e."ocel:activity", e."ocel:timestamp", e.order_id, e.value, e.duration_s
          FROM ocel_events e ORDER BY "ocel:timestamp", "ocel:id")
      TO '#{@ocel_dir}/ocel_events.csv' (HEADER, DELIMITER ',');
    """
  end

  defp ocel_rels_file do
    "ocel_rels.csv"
  end
end

# BK-SQLD2X: converted from self-exiting script (ran only under
# `mix run --no-start`; under `mix test` it reported 0 tests / exit 0 — a
# typed vacuous pass for census tooling) to an ExUnit case so
# `mix test test/integration` executes it instead of dropping the batch.
# Court legs unchanged; the run/0 verdict is asserted, not halted on.
defmodule Sqld2SqlIngestCourtTest do
  use ExUnit.Case, async: false

  test "SQLD-2 postgres-dump ingestion court (real duckdb CLI, legs 1-6)" do
    Sqld2.Court.run()
  end
end
