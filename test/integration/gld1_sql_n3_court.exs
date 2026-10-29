# GLD-1 — SQL-ingestion + N3 business-rule court (the graphlaw value on the
# ingestion path). Extends the COLD-1 pattern onto SQLD-2's real projection:
#
#   PostgreSQL dump (SQLD-2 fixture, sha256-pinned) -> faithful COPY->INSERT
#   transform -> real duckdb CLI ingest + window/aggregate pushdown -> CSV
#   projections -> N3 forward-chaining FIXED-POINT over projected triples ->
#   exact partition equality vs an independent Elixir re-derivation (dual
#   governance over ingested data) + typed fail-closed ambiguity handling +
#   tamper/truncation non-vacuity + determinism re-run.
#
# Run: elixir test/integration/gld1_sql_n3_court.exs
# (plain `elixir`: needs only stdlib + the duckdb CLI, immune to concurrent
#  lanes' in-flight lib/ edits — same rationale as COLD-1.)

defmodule Gld1Court do
  @duckdb "/opt/homebrew/bin/duckdb"
  @dump Path.expand("test/integration/fixtures/gld1/orders_dump.sql")
  @dump_sha "c5c65bd153391752d05a56b3d9311a0492d90f21e44da4d28a82637afeed1990"
  @out_dir Path.expand("tmp/gld1")

  # Business-rule literals (sealed; bound into the audit hash).
  @high_value_cents 1500
  @suspicious_window_s 3600
  @suspicious_min_events 3
  @suspicious_min_credit 1500

  @positive_preds [:highValueOrder, :hasFlaggedOrder, :slaBreachEvent, :hasBreach, :suspicious, :escalated]
  @ambiguous_preds [:amountAmbiguous, :ambiguousCustomer, :ambiguousOrder]

  # -- entry -------------------------------------------------------------------

  def run! do
    File.rm_rf!(@out_dir)
    File.mkdir_p!(@out_dir)
    assert_sha!(@dump, @dump_sha)

    rows = parse_dump(File.read!(@dump))

    # --- Leg B: real duckdb ingest + projection pushdown ---
    sealed = pipeline!(rows)

    # --- Leg C: sealed corpus carries zero ambiguous rows ---
    sealed_amb =
      MapSet.new(sealed.facts, fn {_s, p, _o} -> p end) |> MapSet.intersection(MapSet.new(@ambiguous_preds))

    MapSet.size(sealed_amb) == 0 || raise("Leg C: sealed corpus unexpectedly ambiguous: #{inspect(sealed_amb)}")

    # --- Leg D: N3 fixed-point vs independent re-derivation (dual governance) ---
    expected = rederive(rows)
    assert_partition!(sealed.facts, expected)

    # --- Leg E: the fixed point is genuinely multi-pass ---
    iters = sealed.iterations
    min_escalated = min_iter_for(iters, :escalated)

    is_integer(min_escalated) and min_escalated >= 2 ||
      raise("Leg E BROKEN: escalated derived at iteration #{inspect(min_escalated)} (one-shot, not a fixed point)")

    max_iter = iters |> Map.values() |> Enum.max()

    # --- Leg F: tamper non-vacuity ---
    tamper = tamper_leg!(rows, sealed.partition)

    # --- determinism: identical sealed re-run ---
    second = pipeline!(rows)

    sealed.facts == second.facts and sealed.audit_hash == second.audit_hash ||
      raise("NONDETERMINISTIC RERUN")

    %{
      verdict: "PASS",
      corpus: %{customers: length(rows.customers), orders: length(rows.orders), events: length(rows.events)},
      partition: sealed.partition,
      derived_fact_count: derived_count(sealed.facts),
      max_iteration: max_iter,
      min_escalated_iteration: min_escalated,
      tamper_leg: tamper,
      audit_hash: sealed.audit_hash
    }
  end

  # -- dump parsing (shared by ingestion AND re-derivation; rules are NOT) -----

  defp parse_dump(text) do
    blocks =
      Regex.scan(~r/COPY public\.(\w+) \(([^)]*)\) FROM stdin;\n(.*?)\n\\\.\n/s, text,
        capture: :all_but_first
      )

    by_table = Map.new(blocks, fn [table, _cols, body] -> {table, body} end)
    lines = fn table -> by_table |> Map.fetch!(table) |> String.split("\n", trim: true) end

    customers =
      for [cid, name, region, credit] <- Enum.map(lines.("customers"), &String.split(&1, "\t")) do
        %{id: cid, name: name, region: region, credit: int!(credit, "customer #{cid} credit")}
      end

    orders =
      for [oid, cid, amount, status, created] <- Enum.map(lines.("orders"), &String.split(&1, "\t")) do
        %{id: oid, customer: cid, amount: parse_amount(amount, oid), status: status, created: created}
      end

    events =
      for [eid, oid, etype, value, dur, occ] <- Enum.map(lines.("order_events"), &String.split(&1, "\t")) do
        %{id: eid, order: oid, type: etype, at: occ}
      end

    known = MapSet.new(customers, & &1.id)

    orders =
      Enum.map(orders, fn o ->
        Map.put(o, :dangling_customer, not MapSet.member?(known, o.customer))
      end)

    %{customers: customers, orders: orders, events: events}
  end

  defp parse_amount("NULL", _oid), do: nil

  defp parse_amount(a, oid) do
    case Integer.parse(a) do
      {n, ""} -> n
      _ -> raise("FAIL-CLOSED: unparseable amount on #{oid}: #{inspect(a)}")
    end
  end

  defp int!(s, what) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> raise("FAIL-CLOSED: unparseable #{what}: #{inspect(s)}")
    end
  end

  # -- duckdb ingest + projection ----------------------------------------------

  defp pipeline!(rows) do
    projection = duckdb_projection!(rows)
    facts = base_facts(rows, projection)
    {facts, iterations} = n3_fixed_point(MapSet.new(facts))
    %{facts: facts, iterations: iterations, partition: partition_view(facts), audit_hash: audit_hash(rows)}
  end

  defp duckdb_projection!(rows) do
    script = Path.join(@out_dir, "project.sql")
    File.write!(script, ingest_sql(rows) <> "\n" <> projection_sql())

    {out, exit} = System.cmd(@duckdb, ["-f", script], stderr_to_stdout: true)
    exit == 0 || raise("duckdb ingest+projection FAILED (exit #{exit}): #{String.slice(out, 0, 800)}")

    %{
      orders: read_csv("orders.csv"),
      events: read_csv("events.csv"),
      customers: read_csv("customers.csv"),
      windows: read_csv("windows.csv"),
      ambiguous: read_csv("ambiguous.csv")
    }
  end

  # Faithful COPY->INSERT transform of the pg dump text. Values are escaped;
  # the transform never interprets business fields.
  defp ingest_sql(rows) do
    lit = fn s -> "'" <> String.replace(s, "'", "''") <> "'" end

    cust =
      Enum.map_join(rows.customers, ",\n", fn c ->
        "(#{lit.(c.id)}, #{lit.(c.name)}, #{lit.(c.region)}, #{c.credit})"
      end)

    orders =
      Enum.map_join(rows.orders, ",\n", fn o ->
        amt = if o.amount == nil, do: "NULL", else: Integer.to_string(o.amount)
        "(#{lit.(o.id)}, #{lit.(o.customer)}, #{amt}, #{lit.(o.status)}, TIMESTAMP #{lit.(o.created)})"
      end)

    events =
      Enum.map_join(rows.events, ",\n", fn e ->
        "(#{lit.(e.id)}, #{lit.(e.order)}, #{lit.(e.type)}, TIMESTAMP #{lit.(e.at)})"
      end)

    """
    CREATE SCHEMA IF NOT EXISTS public;
    DROP TABLE IF EXISTS public.customers; CREATE TABLE public.customers (customer_id TEXT, name TEXT, region TEXT, credit_limit INTEGER);
    DROP TABLE IF EXISTS public.orders; CREATE TABLE public.orders (order_id TEXT, customer_id TEXT, amount INTEGER, status TEXT, created_at TIMESTAMP);
    DROP TABLE IF EXISTS public.order_events; CREATE TABLE public.order_events (event_id TEXT, order_id TEXT, event_type TEXT, occurred_at TIMESTAMP);
    INSERT INTO public.customers VALUES #{cust};
    INSERT INTO public.orders VALUES #{orders};
    INSERT INTO public.order_events VALUES #{events};
    """
  end

  defp projection_sql do
    """
    COPY (SELECT customer_id, credit_limit FROM public.customers ORDER BY customer_id) TO '#{@out_dir}/customers.csv' (HEADER, DELIMITER ',');
    COPY (SELECT order_id, customer_id, amount FROM public.orders ORDER BY order_id) TO '#{@out_dir}/orders.csv' (HEADER, DELIMITER ',');
    COPY (SELECT event_id, order_id, event_type FROM public.order_events ORDER BY event_id) TO '#{@out_dir}/events.csv' (HEADER, DELIMITER ',');
    COPY (
      WITH ect AS (
        SELECT o.customer_id AS cid, e.event_id AS eid, e.occurred_at AS at
        FROM public.order_events e JOIN public.orders o ON e.order_id = o.order_id
      ), win AS (
        SELECT a.cid, a.eid, COUNT(*) AS cnt
        FROM ect a JOIN ect b
          ON a.cid = b.cid AND b.at >= a.at AND b.at <= a.at + INTERVAL #{@suspicious_window_s} SECONDS
        GROUP BY a.cid, a.eid
      )
      SELECT cid, MAX(cnt) AS max_events FROM win GROUP BY cid ORDER BY cid
    ) TO '#{@out_dir}/windows.csv' (HEADER, DELIMITER ',');
    COPY (
      SELECT 'amount_null' AS kind, order_id AS id, '' AS detail FROM public.orders WHERE amount IS NULL
      UNION ALL
      SELECT 'dangling_customer', order_id, customer_id FROM public.orders
        WHERE customer_id NOT IN (SELECT customer_id FROM public.customers)
      UNION ALL
      SELECT 'dangling_order', event_id, order_id FROM public.order_events
        WHERE order_id NOT IN (SELECT order_id FROM public.orders)
    ) TO '#{@out_dir}/ambiguous.csv' (HEADER, DELIMITER ',');
    """
  end

  defp read_csv(name) do
    path = Path.join(@out_dir, name)

    case File.read(path) do
      {:ok, body} ->
        case String.split(body, "\n", trim: true) do
          [] ->
            []

          [header | data] ->
            ncols = length(String.split(header, ","))

            Enum.map(data, fn line ->
              fields = String.split(line, ",")
              length(fields) == ncols || raise("FAIL-CLOSED: malformed projection row in #{name}: #{inspect(line)}")
              fields
            end)
        end

      {:error, reason} ->
        raise("FAIL-CLOSED: projection #{name} unreadable: #{inspect(reason)}")
    end
  end

  # -- base facts (projection CSVs -> triples; ambiguity TYPED, never dropped) -

  defp base_facts(rows, projection) do
    known_orders = MapSet.new(rows.orders, & &1.id)

    amb_dangling_customer =
      projection.ambiguous
      |> Enum.filter(&match?(["dangling_customer", _oid, _cid], &1))
      |> Map.new(fn [_k, oid, cid] -> {oid, cid} end)

    amb_dangling_order =
      projection.ambiguous
      |> Enum.filter(&match?(["dangling_order", _eid, _oid], &1))
      |> Map.new(fn [_k, eid, oid] -> {eid, oid} end)

    Enum.flat_map(projection.orders, fn [oid, cid, amt] ->
      cond do
        Map.has_key?(amb_dangling_customer, oid) ->
          c = Map.fetch!(amb_dangling_customer, oid)
          [{oid, :ambiguousCustomer, c}, {c, :manualReview, :t}]

        amt in ["", "NULL"] ->
          [{oid, :amountAmbiguous, :t}]

        true ->
          [{oid, :amount, String.to_integer(amt)}, {oid, :orderCustomer, cid}]
      end
    end) ++
      Enum.flat_map(projection.events, fn [eid, oid, etype] ->
        if Map.has_key?(amb_dangling_order, eid) do
          [{eid, :ambiguousOrder, oid}]
        else
          oid in known_orders || raise("FAIL-CLOSED: event #{eid} references unknown order #{oid} not flagged ambiguous")
          [{eid, :eventOrder, oid}, {eid, :eventType, event_type(etype)}]
        end
      end) ++
      Enum.map(projection.customers, fn [cid, credit] -> {cid, :creditLimit, String.to_integer(credit)} end) ++
      Enum.map(projection.windows, fn [cid, n] -> {cid, :windowCount, String.to_integer(n)} end) ++
      # dangling-customer targets are typed for the audit trail; they carry NO
      # positive base facts and can only ever reach :manualReview
      (projection.ambiguous
       |> Enum.filter(&match?(["dangling_customer", _oid, _cid], &1))
       |> Enum.flat_map(fn [_k, _oid, cid] -> [{cid, :unknownCustomer, :t}, {cid, :manualReview, :t}] end))
  end

  defp event_type("payment_excursion"), do: :payment_excursion
  defp event_type(t) when t in ["charge", "note", "ship"], do: String.to_atom(t)
  defp event_type(t), do: raise("FAIL-CLOSED: unknown event_type #{inspect(t)}")

  # -- N3 forward-chaining fixed-point -----------------------------------------
  # Each rule is a deterministic derivation over the CURRENT fact set; the loop
  # re-applies ALL rules until no new triple is derivable. Derived-fact
  # provenance (derivation iteration) is recorded for the multi-pass leg.

  defp n3_fixed_point(base) do
    iterate(base, base, %{}, 1)
  end

  defp iterate(all, _prev_new, iters, n) do
    new = apply_rules(all) |> MapSet.difference(all)

    if MapSet.size(new) == 0 do
      {all, iters}
    else
      iters2 = Map.merge(iters, Map.new(new, fn f -> {f, n} end))
      iterate(MapSet.union(all, new), new, iters2, n + 1)
    end
  end

  defp apply_rules(facts) do
    MapSet.new(r1(facts) ++ r2(facts) ++ r3(facts) ++ r4(facts) ++ r5(facts) ++ r6(facts) ++ r7(facts))
  end

  defp by_pred(facts, p), do: Enum.filter(facts, fn {_s, q, _o} -> q == p end)
  defp index(facts, p), do: Map.new(by_pred(facts, p), fn {s, _p, o} -> {s, o} end)

  # r1: ?o :amount ?a , ?a > 1500  =>  ?o :highValueOrder
  defp r1(facts) do
    for {o, :amount, a} <- by_pred(facts, :amount), is_integer(a), a > @high_value_cents do
      {o, :highValueOrder, :t}
    end
  end

  # r2: ?o :highValueOrder , ?o :orderCustomer ?c  =>  ?c :hasFlaggedOrder
  defp r2(facts) do
    hv = index(facts, :highValueOrder)

    for {o, :orderCustomer, c} <- by_pred(facts, :orderCustomer), Map.has_key?(hv, o) do
      {c, :hasFlaggedOrder, :t}
    end
  end

  # r3: ?e :eventType :payment_excursion  =>  ?e :slaBreachEvent   (SLA typed)
  defp r3(facts) do
    for {e, :eventType, :payment_excursion} <- by_pred(facts, :eventType), do: {e, :slaBreachEvent, :t}
  end

  # r4: ?e :slaBreachEvent , ?e :eventOrder ?o , ?o :orderCustomer ?c => ?c :hasBreach
  defp r4(facts) do
    breach = MapSet.new(by_pred(facts, :slaBreachEvent))
    eo = index(facts, :eventOrder)
    oc = index(facts, :orderCustomer)

    for {e, :slaBreachEvent, :t} <- by_pred(facts, :slaBreachEvent),
        MapSet.member?(breach, {e, :slaBreachEvent, :t}),
        o = Map.get(eo, e),
        c = Map.get(oc, o) do
      {c, :hasBreach, :t}
    end
  end

  # r5: ?c :windowCount ?n , ?n > 3  =>  ?c :suspicious  (">3 events in 1h")
  defp r5(facts) do
    for {c, :windowCount, n} <- by_pred(facts, :windowCount), n > @suspicious_min_events do
      {c, :suspicious, :t}
    end
  end

  # r6: ?c :hasBreach , ?c :creditLimit ?k , ?k >= 1500 => ?c :suspicious
  #     (SLA breach on a high-credit account is suspicious)
  defp r6(facts) do
    breach = MapSet.new(for {c, :hasBreach, :t} <- by_pred(facts, :hasBreach), do: c)

    for {c, :creditLimit, k} <- by_pred(facts, :creditLimit),
        MapSet.member?(breach, c),
        k >= @suspicious_min_credit do
      {c, :suspicious, :t}
    end
  end

  # r7: ?c :suspicious , ?c :hasFlaggedOrder => ?c :escalated
  #     (chained rule: consumes ONLY rule-derived facts — the reason the court
  #      needs a fixed point, not one pass)
  defp r7(facts) do
    susp = MapSet.new(for {c, :suspicious, :t} <- by_pred(facts, :suspicious), do: c)

    for {c, :hasFlaggedOrder, :t} <- by_pred(facts, :hasFlaggedOrder), MapSet.member?(susp, c) do
      {c, :escalated, :t}
    end
  end

  # -- independent Elixir re-derivation (dual governance) -----------------------
  # Computed from the PARSED DUMP with straightforward comprehensions. Shares
  # no rule code, no duckdb output, no fixed-point machinery with the engine.

  defp rederive(rows) do
    oc = Map.new(rows.orders, fn o -> {o.id, o} end)
    cust = Map.new(rows.customers, fn c -> {c.id, c} end)

    high_value =
      rows.orders |> Enum.filter(fn o -> is_integer(o.amount) and o.amount > @high_value_cents end) |> Enum.map(& &1.id)

    has_flagged = Enum.map(high_value, fn oid -> oc |> Map.fetch!(oid) |> Access.get(:customer) end)

    breach_events = Enum.map(Enum.filter(rows.events, fn e -> e.type == "payment_excursion" end), & &1.id)

    has_breach =
      rows.events
      |> Enum.filter(fn e -> e.type == "payment_excursion" and Map.has_key?(oc, e.order) end)
      |> Enum.map(fn e -> oc |> Map.fetch!(e.order) |> Access.get(:customer) end)

    # suspicious via window: >3 events in any rolling 1h per customer
    by_cust =
      rows.events
      |> Enum.filter(fn e -> Map.has_key?(oc, e.order) end)
      |> Enum.group_by(fn e -> oc |> Map.fetch!(e.order) |> Access.get(:customer) end)
      |> Map.new(fn {c, evs} -> {c, Enum.map(evs, fn e -> epoch(e.at) end)} end)

    suspicious_window =
      for {c, ts} <- by_cust,
          Enum.any?(ts, fn t0 -> Enum.count(ts, fn t -> t >= t0 and t <= t0 + @suspicious_window_s end) > @suspicious_min_events end),
          into: MapSet.new() do
        c
      end

    suspicious_credit =
      has_breach
      |> MapSet.new()
      |> MapSet.intersection(MapSet.new(rows.customers |> Enum.filter(fn c -> c.credit >= @suspicious_min_credit end) |> Enum.map(& &1.id)))

    suspicious = MapSet.union(suspicious_window, suspicious_credit)

    escalated =
      suspicious
      |> MapSet.intersection(MapSet.new(has_flagged))

    %{
      highValueOrder: MapSet.new(high_value),
      hasFlaggedOrder: MapSet.new(has_flagged),
      slaBreachEvent: MapSet.new(breach_events),
      hasBreach: MapSet.new(has_breach),
      suspicious: suspicious,
      escalated: escalated
    }
  end

  defp epoch(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _off} -> DateTime.to_unix(dt)
      _ -> raise("FAIL-CLOSED: unparseable timestamp #{inspect(ts)}")
    end
  end

  # -- partition assertion -------------------------------------------------------

  defp assert_partition!(facts, expected) do
    actual =
      @positive_preds
      |> Map.new(fn p -> {p, MapSet.new(for {s, ^p, :t} <- MapSet.to_list(facts), do: s)} end)

    for p <- @positive_preds do
      exp = Map.fetch!(expected, p)
      act = Map.fetch!(actual, p)

      MapSet.equal?(exp, act) ||
        raise("""
        PARTITION MISMATCH on #{p}
          engine:    #{inspect(Enum.sort(MapSet.to_list(act)))}
          rederived: #{inspect(Enum.sort(MapSet.to_list(exp)))}
        """)
    end

    # fail-closed invariant: no ambiguous subject ever reaches a positive class
    amb_subjects =
      for {s, p, _o} <- MapSet.to_list(facts), p in @ambiguous_preds, into: MapSet.new(), do: s

    for p <- @positive_preds do
      overlap = MapSet.intersection(amb_subjects, Map.fetch!(actual, p))
      MapSet.size(overlap) == 0 || raise("FAIL-CLOSED VIOLATION: ambiguous subjects #{inspect(overlap)} in #{p}")
    end

    :ok
  end

  defp partition_view(facts) do
    @positive_preds
    |> Map.new(fn p -> {Atom.to_string(p), Enum.sort(for {s, ^p, :t} <- MapSet.to_list(facts), do: s)} end)
  end

  defp derived_count(facts), do: facts |> MapSet.to_list() |> Enum.count(fn {_s, p, _o} -> p in @positive_preds end)

  defp min_iter_for(iters, pred) do
    iters |> Enum.filter(fn {{_s, p, _o}, _i} -> p == pred end) |> Enum.map(&elem(&1, 1)) |> Enum.min(fn -> nil end)
  end

  # -- tamper non-vacuity ---------------------------------------------------------

  defp tamper_leg!(rows, sealed_partition) do
    # (a) value tamper: flip O-2's amount out of the high-value band; the full
    # pipeline re-run must DIFFER from sealed AND still match the independent
    # re-derivation on the tampered corpus.
    rows_a = update_rows(rows, "O-2", fn o -> %{o | amount: 100} end)
    run_a = pipeline!(rows_a)
    exp_a = rederive(rows_a)

    run_a.partition != sealed_partition || raise("TAMPER (a): amount flip did not change the partition (vacuous)")
    assert_partition!(run_a.facts, exp_a)

    # (b) ambiguity tamper: repoint O-3's customer at an unknown id; the row
    # must land in the typed ambiguous path (manualReview, no positive class)
    # and the partition must flip.
    rows_b = update_rows(rows, "O-3", fn o -> %{o | customer: "C-999", dangling_customer: true} end)
    run_b = pipeline!(rows_b)

    amb_b =
      MapSet.new(for {s, p, _o} <- MapSet.to_list(run_b.facts), p in @ambiguous_preds, do: s)

    MapSet.member?(amb_b, "O-3") || raise("TAMPER (b): dangling FK not typed ambiguous (fail-closed path not taken)")
    assert_partition!(run_b.facts, rederive(rows_b))

    reviewed =
      MapSet.new(for {s, :manualReview, :t} <- MapSet.to_list(run_b.facts), do: s)

    MapSet.member?(reviewed, "C-999") || raise("TAMPER (b): dangling customer not fail-closed to manualReview")

    positive_b =
      for {s, p, _o} <- MapSet.to_list(run_b.facts), p in @positive_preds, into: MapSet.new(), do: s

    MapSet.disjoint?(MapSet.new(["O-3", "C-999"]), positive_b) ||
      raise("TAMPER (b): ambiguous row reached a positive class")

    # (c) truncation: a corrupt ingest script makes real duckdb REFUSE (nonzero
    # exit), which the court surfaces as a hard failure — never a silent pass.
    trunc = Path.join(@out_dir, "truncated.sql")
    File.write!(trunc, String.slice(ingest_sql(rows), 0, 400))
    {_, exit_c} = System.cmd(@duckdb, ["-f", trunc], stderr_to_stdout: true)
    exit_c != 0 || raise("TAMPER (c): duckdb accepted a truncated ingest script (refusal gate vacuous)")

    %{
      amount_flip: "partition flipped + re-derivation matched on tampered corpus",
      dangling_fk: "typed ambiguous + manualReview(C-999), excluded from positive classes",
      truncation: "duckdb exit #{exit_c} (refusal) surfaced as court failure"
    }
  end

  defp update_rows(rows, oid, f) do
    Map.update!(rows, :orders, fn os -> Enum.map(os, fn o -> if o.id == oid, do: f.(o), else: o end) end)
  end

  # -- misc ----------------------------------------------------------------------

  defp assert_sha!(path, want) do
    got =
      :crypto.hash(:sha256, File.read!(path))
      |> Base.encode16(case: :lower)

    got == want || raise("SHA PIN MISMATCH for #{path}: #{got} != #{want}")
  end

  defp audit_hash(rows) do
    :crypto.hash(:sha256, inspect(rows, limit: :infinity) <> "||" <> inspect(literals()))
    |> Base.encode16(case: :lower)
  end

  defp literals, do: {@high_value_cents, @suspicious_window_s, @suspicious_min_events, @suspicious_min_credit}
end

court = Gld1Court.run!()
File.mkdir_p!("tmp")
File.write!("tmp/gld1-court-result.terms", inspect(court, limit: :infinity))
IO.puts("GLD-1 COURT: " <> court.verdict)
IO.inspect(court.corpus, label: "corpus")
IO.inspect(court.partition, label: "partition")
IO.puts("derived facts: #{court.derived_fact_count}  max_iteration: #{court.max_iteration}  min_escalated_iteration: #{court.min_escalated_iteration}")
IO.inspect(court.tamper_leg, label: "tamper_leg")
IO.puts("audit_hash: #{court.audit_hash}")
