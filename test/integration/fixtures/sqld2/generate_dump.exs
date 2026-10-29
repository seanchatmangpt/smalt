# SQLD-2 deterministic pg_dump fixture generator.
# Determinism: xorshift64* PRNG with a fixed seed — no :rand, no wall clock.
# Emits a realistic pg_dump text dump: SET preamble, CREATE TABLE DDL,
# COPY blocks (COPY format) for customers / orders / order_events.

defmodule Sqld2.Gen do
  @seed 0x51D2_CAFE_BABE_0001

  def tables do
    {customers, s1} = customers(@seed)
    {orders, s2} = orders(s1, customers)
    {events, _} = events(s2, orders)
    %{"customers" => customers, "orders" => orders, "order_events" => events}
  end

  defp customers(state) do
    Enum.map_reduce(1..120, state, fn i, st ->
      {name, st} = pick(st, ["Acme", "Borealis", "Cinder", "Delta", "Ember", "Foxtrot"])
      {region, st} = pick(st, ["us-east", "us-west", "eu-central", "ap-south"])
      {credit, st} = int(st, 500, 5000)
      {%{"customer_id" => "C-#{i}", "name" => "#{name} #{i}", "region" => region,
         "credit_limit" => credit}, st}
    end)
  end

  defp orders(state, customers) do
    Enum.map_reduce(1..300, state, fn i, st ->
      {cust, st} = pick(st, customers)
      {amount, st} = int(st, 10, 2000)
      {status, st} = pick(st, ["new", "paid", "shipped", "closed"])
      {%{"order_id" => "O-#{i}", "customer_id" => cust["customer_id"], "amount" => amount,
         "status" => status, "created_at" => ts(2026, 1, rem(i - 1, 28) + 1, rem(i, 24))}, st}
    end)
  end

  defp events(state, orders) do
    Enum.map_reduce(1..80, state, fn i, st ->
      {order, st} = pick(st, orders)
      {etype, st} = pick(st, ["charge", "ship", "payment_excursion", "note"])
      {value, st} = int(st, 0, 120)
      {dur, st} = int(st, 5, 400)
      {%{"event_id" => "E-#{i}", "order_id" => order["order_id"], "event_type" => etype,
         "value" => value, "duration_s" => dur,
         "occurred_at" => ts(2026, 2, rem(i - 1, 28) + 1, rem(i, 24))}, st}
    end)
  end

  defp ts(y, m, d, h),
    do: :io_lib.format(~c"~4..0B-~2..0B-~2..0BT~2..0B:00:00Z", [y, m, d, h]) |> IO.iodata_to_binary()

  defp pick(st, list) do
    {i, st2} = next(st, length(list))
    {Enum.at(list, i - 1), st2}
  end

  defp int(st, lo, hi) do
    {i, st2} = next(st, hi - lo + 1)
    {lo + i - 1, st2}
  end

  # xorshift64*: deterministic, seed nonzero
  defp next(st, n) do
    x = :erlang.band(st * 2685821657736338717, 0xFFFFFFFFFFFFFFFF)
    x3 = :erlang.band(x * 2685821657736338717, 0xFFFFFFFFFFFFFFFF)
    x5 = :erlang.band(x3 * 2685821657736338717, 0xFFFFFFFFFFFFFFFF)
    r = :erlang.band(:erlang.bsr(x5, 31), 0x7FFFFFFF)
    {rem(r, n) + 1, x5}
  end

  # — pg_dump text emission —

  def dump(tables) do
    [
      preamble(),
      create_table("customers", ["customer_id TEXT", "name TEXT", "region TEXT", "credit_limit INTEGER"]),
      create_table("orders", ["order_id TEXT", "customer_id TEXT", "amount INTEGER", "status TEXT", "created_at TIMESTAMP"]),
      create_table("order_events", ["event_id TEXT", "order_id TEXT", "event_type TEXT", "value DOUBLE PRECISION", "duration_s INTEGER", "occurred_at TIMESTAMP"]),
      copy_customers(tables["customers"]),
      copy_orders(tables["orders"]),
      copy_events(tables["order_events"])
    ]
    |> IO.iodata_to_binary()
  end

  defp preamble do
    """
    --
    -- PostgreSQL database dump (synthetic, SQLD-2 court fixture)
    --

    SET statement_timeout = 0;
    SET client_encoding = 'UTF8';
    SET standard_conforming_strings = on;

    """
  end

  defp create_table(name, cols) do
    "CREATE TABLE public.#{name} (\n" <>
      Enum.map_join(cols, ",\n", &"    #{&1}") <>
      "\n);\n\n"
  end

  defp copy_customers(rows) do
    "COPY public.customers (customer_id, name, region, credit_limit) FROM stdin;\n" <>
      Enum.map_join(rows, "\n", fn r ->
        Enum.join([r["customer_id"], r["name"], r["region"], Integer.to_string(r["credit_limit"])], "\t")
      end) <> "\n\\.\n\n"
  end

  defp copy_orders(rows) do
    "COPY public.orders (order_id, customer_id, amount, status, created_at) FROM stdin;\n" <>
      Enum.map_join(rows, "\n", fn r ->
        Enum.join([r["order_id"], r["customer_id"], Integer.to_string(r["amount"]), r["status"], r["created_at"]], "\t")
      end) <> "\n\\.\n\n"
  end

  defp copy_events(rows) do
    "COPY public.order_events (event_id, order_id, event_type, value, duration_s, occurred_at) FROM stdin;\n" <>
      Enum.map_join(rows, "\n", fn r ->
        Enum.join([r["event_id"], r["order_id"], r["event_type"],
                   :erlang.float_to_binary(r["value"] * 1.0, [:compact, decimals: 6]),
                   Integer.to_string(r["duration_s"]), r["occurred_at"]], "\t")
      end) <> "\n\\.\n\n"
  end
end

out_dir = Path.expand("tmp/sqld2", File.cwd!())
File.mkdir_p!(out_dir)
tables = Sqld2.Gen.tables()
total = tables |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

dump_path = Path.join(out_dir, "orders_dump.sql")
File.write!(dump_path, Sqld2.Gen.dump(tables))

# per-table counts for the court's round-trip assertion (plain term file)
counts = tables |> Enum.map(fn {name, rows} -> {name, length(rows)} end) |> Enum.sort()
File.write!(Path.join(out_dir, "expected_counts.terms"), inspect(counts, limit: :infinity))

IO.puts("SQLD2 GEN: OK total_rows=#{total} counts=#{inspect(counts)}")
IO.puts("dump: #{dump_path} (#{File.stat!(dump_path).size} bytes)")
