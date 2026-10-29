# GLD-7 - SQL dump -> OCEL -> graphlaw laws -> POWL settlement court.
#
#   (1) deterministic 10-order pg_dump fixture (SQLD-2 pattern); a real
#       text parser reads the dump BYTES back (CREATE TABLE DDL + COPY
#       rows); after the bytes land the generator's in-memory rows are
#       never consulted.
#   (2) rows project to OCEL 2.0 events (Smalt.Ocel envelope,
#       validate_envelope/2 referential integrity). The ingested schema
#       compiles two ways: SQLD-5 auto-shapes (SqlShapeGen over the PARSED
#       DDL) and the hand-authored HighValueOrderShape law via the GL-2
#       LawCompiler.
#   (3) each ingested order runs the GL-4 settlement business net through
#       Smalt.POWL2.Executor: over-threshold orders ANDON at validate (the
#       refusal names the compiled law rule id), conforming orders commit
#       into the ChangeFeed (real CAS 201) and settle.
#   (4) ONE ReceiptEngine run seals 13 ingest events + every executor step;
#       the sealed Merkle receipt partitions exactly vs the law: 2 ANDON
#       leaves + 8 settlement chains, disjoint and exhaustive.
#
# Run:
#   MIX_BUILD_ROOT=_build-gld7 mix test test/integration/gld7_ingest_to_settlement_court_test.exs
# Exit 0 = PASS. No Process.sleep anywhere (bounded receive windows only).

defmodule Gld7.Dump do
  @moduledoc "Deterministic 10-order pg_dump fixture (SQLD-2 pattern)."

  # Over-threshold (>10_000): O-01 (48_000) and O-05 (12_500); 8 conforming.
  # Fixed corpus: no randomness, no wall clock.
  @orders [
    ["O-01", "C-1", 48_000, "new", "2026-03-01T08:00:00Z"],
    ["O-02", "C-2", 120, "paid", "2026-03-01T09:00:00Z"],
    ["O-03", "C-3", 480, "new", "2026-03-01T10:00:00Z"],
    ["O-04", "C-1", 9_950, "paid", "2026-03-02T08:00:00Z"],
    ["O-05", "C-2", 12_500, "new", "2026-03-02T09:00:00Z"],
    ["O-06", "C-3", 640, "shipped", "2026-03-03T08:00:00Z"],
    ["O-07", "C-1", 7_300, "new", "2026-03-03T09:00:00Z"],
    ["O-08", "C-2", 4_800, "new", "2026-03-04T08:00:00Z"],
    ["O-09", "C-3", 8_200, "new", "2026-03-05T08:00:00Z"],
    ["O-10", "C-1", 9_200, "paid", "2026-03-05T09:00:00Z"]
  ]

  @customers [
    ["C-1", "Acme 1", "us-east", 5_000],
    ["C-2", "Borealis 2", "eu-central", 4_000],
    ["C-3", "Cinder 3", "ap-south", 3_000]
  ]

  def orders, do: @orders
  def customers, do: @customers

  def dump do
    [
      """
      --
      -- PostgreSQL database dump (synthetic, GLD-7 court fixture)
      --

      SET statement_timeout = 0;
      SET client_encoding = 'UTF8';
      SET standard_conforming_strings = on;

      """,
      create_table("customers", [
        "customer_id TEXT PRIMARY KEY",
        "name VARCHAR NOT NULL",
        "region VARCHAR",
        "credit_limit INTEGER"
      ]),
      create_table("orders", [
        "order_id TEXT PRIMARY KEY",
        "customer_id TEXT NOT NULL",
        "amount INTEGER NOT NULL",
        "status VARCHAR",
        "created_at VARCHAR"
      ]),
      copy("customers", ~w(customer_id name region credit_limit),
        Enum.map(@customers, &Enum.join(&1, "\t"))),
      copy("orders", ~w(order_id customer_id amount status created_at),
        Enum.map(@orders, fn [oid, cid, amt, st, ts] ->
          Enum.join([oid, cid, Integer.to_string(amt), st, ts], "\t")
        end))
    ]
    |> IO.iodata_to_binary()
  end

  defp create_table(name, cols) do
    "CREATE TABLE public.#{name} (\n    " <>
      Enum.join(cols, ",\n    ") <> "\n);\n\n"
  end

  defp copy(table, cols, rows) do
    "COPY public.#{table} (#{Enum.join(cols, ", ")}) FROM stdin;\n" <>
      Enum.join(rows, "\n") <> "\n\\.\n\n"
  end
end

defmodule Gld7.Parser do
  @moduledoc "Real pg_dump text parser: CREATE TABLE DDL + COPY blocks."

  def parse!(bin) when is_binary(bin) do
    {tables, copies, _mode} =
      Enum.reduce(String.split(bin, ["\r\n", "\n"]), {%{}, %{}, :idle}, fn
        line, {ddl, copies, :idle} ->
          cond do
            hdr = Regex.run(~r/^CREATE TABLE public\.(\w+) \($/, line) ->
              {Map.put(ddl, hd(tl(hdr)), []), copies, {:ddl, hd(tl(hdr))}}

            hdr = Regex.run(~r/^COPY public\.(\w+) \(([^)]*)\) FROM stdin;$/, line) ->
              [_, t, c] = hdr
              cols = c |> String.split(",") |> Enum.map(&String.trim/1)
              {ddl, Map.put(copies, t, %{columns: cols, rows: []}), {:copy, t}}

            true ->
              {ddl, copies, :idle}
          end

        line, {ddl, copies, {:ddl, t}} ->
          cond do
            line == ");" ->
              {ddl, copies, :idle}

            col = Regex.run(~r/^\s{4}(\w+)\s+([A-Z]+)(.*)$/, line) ->
              [_, name, type, rest] = col
              entry = %{
                name: name,
                type: type,
                null: if(String.contains?(rest, "NOT NULL"), do: "NO", else: "YES"),
                pk: String.contains?(rest, "PRIMARY KEY")
              }

              {Map.update!(ddl, t, &(&1 ++ [entry])), copies, {:ddl, t}}

            true ->
              {ddl, copies, {:ddl, t}}
          end

        line, {ddl, copies, {:copy, t}} ->
          cond do
            line == "\\." ->
              {ddl, copies, :idle}

            line != "" ->
              cur = copies[t]
              vals = String.split(line, "\t") |> Enum.map(&String.trim/1)
              row = Enum.zip(cur.columns, vals) |> Map.new()
              {ddl, put_in(copies[t].rows, cur.rows ++ [row]), {:copy, t}}

            true ->
              {ddl, copies, {:copy, t}}
          end
      end)

    %{tables: tables, copies: copies}
  end
end

defmodule Gld7.Ingest do
  @moduledoc "Parsed dump -> OCEL 2.0 envelope + schema/law compilation."

  @law_ttl ~S"""
  @prefix ex: <https://example.com/gld7#> .
  @prefix sh: <http://www.w3.org/ns/shacl#> .

  ex:HighValueOrderShape a sh:NodeShape ;
    sh:targetClass ex:Order ;
    sh:property [
      sh:path totalAmount ;
      sh:maxInclusive 10000 ;
      sh:message "order total above 10000 requires compliance signature" ;
    ] .
  """

  def law_ttl, do: @law_ttl

  # OCEL 2.0 events over the PARSED rows (not the fixture lists).
  def ocel_envelope(parsed) do
    customers = parsed.copies["customers"].rows
    orders = parsed.copies["orders"].rows

    objects =
      Enum.map(customers, fn r ->
        %{"id" => r["customer_id"], "type" => "customers", "attributes" => r}
      end) ++
        Enum.map(orders, fn r ->
          %{"id" => r["order_id"], "type" => "orders", "attributes" => r}
        end)

    cust_events =
      Enum.map(Enum.with_index(customers, 1), fn {r, i} ->
        event("gld7-ing-c#{pad(i)}", "ingest", "2026-03-01T00:00:00Z", r,
          r["customer_id"])
      end)

    order_events =
      Enum.map(Enum.with_index(orders, 1), fn {r, i} ->
        event("gld7-ing-o#{pad(i)}", "ingest", "2026-03-01T00:01:00Z", r,
          r["order_id"])
      end)

    events = cust_events ++ order_events

    %{events: events, objects: objects, orders: orders}
  end

  defp event(id, type, time, row, oid) do
    %{
      "id" => id,
      "type" => type,
      "time" => time,
      "attributes" => Map.put(row, "op", type),
      "relationships" => [%{"objectId" => oid, "qualifier" => "row"}]
    }
  end

  defp pad(i), do: String.pad_leading(Integer.to_string(i), 3, "0")

  # Schema spec for SqlShapeGen built from the PARSED DDL.
  def schema_spec(parsed) do
    Enum.map(parsed.tables, fn {table, cols} ->
      %{
        table: table,
        columns:
          Enum.map(cols, fn c ->
            %{name: c.name, type: c.type, null: c.null, pk: c.pk}
          end)
      }
    end)
  end

  # The order settlement context the business net validates.
  def order_ctx(row) do
    %{
      "totalAmount" => String.to_integer(row["amount"]),
      "orderId" => row["order_id"],
      "region" => "US"
    }
  end
end

defmodule Gld7.Net do
  @moduledoc "GL-4 settlement business net, law-guarded at validate."

  alias Smalt.POWL2.ChangeFeed
  alias Smalt.POWL2.Reticle.AST

  def model(cf, pk, doc, schema_guard, law_guard) do
    %AST.ChoiceGraph{
      children: %{
        enter: %AST.Transition{id: :enter, label: :enter, op: tau_op()},
        exit: %AST.Transition{id: :exit, label: :exit, op: tau_op()},
        validate: %AST.Transition{id: :validate, label: :validate,
                                  op: validate_op(schema_guard, law_guard)},
        commit: %AST.Transition{id: :commit, label: :commit,
                                op: commit_op(cf, pk, doc)},
        settle: %AST.Transition{id: :settle, label: :settle, op: settle_op()}
      },
      start: :enter,
      end: :exit,
      edges: [
        {:enter, :validate},
        {:validate, :commit},
        {:commit, :settle},
        {:settle, :exit}
      ],
      guards: %{
        validate: :always,
        commit: :compliant,
        settle: :always
      }
    }
  end

  # validate_op: schema admission first (SqlShapeGen shape over the typed
  # row), then the compiled HighValueOrderShape law.
  defp validate_op(schema_guard, law_guard) do
    fn ctx ->
      row = Map.fetch!(ctx, :typed_row)

      with :ok <- schema_guard.(row),
           :ok <- law_guard.(%{"totalAmount" => row["amount"]}) do
        {:ok, Map.put(ctx, :validated, true), :compliant}
      else
        {:invalid, violations} ->
          {:error, {:andon, {:schema_admission, violations}}}

        {:violation, rule_id, diagnostic} ->
          {:error, {:andon, {:law, rule_id, diagnostic}}}
      end
    end
  end

  defp commit_op(cf, pk, doc) do
    fn ctx ->
      case ChangeFeed.put_item(cf, pk, doc, ctx.typed_row) do
        {:ok, status, etag} ->
          {:ok, Map.put(ctx, :commit_cas, {:ok, status, etag}), :committed}

        {:error, 412, current} ->
          {:error, {:cas_stale, current}}

        other ->
          {:error, {:unexpected_cas_result, other}}
      end
    end
  end

  defp settle_op do
    fn ctx -> {:ok, Map.put(ctx, :settled_at, System.system_time(:millisecond)), :settled} end
  end

  defp tau_op do
    fn ctx -> {:ok, ctx, :tau} end
  end
end



defmodule Gld7.Court do
  @moduledoc "GLD-7: ingest -> govern -> execute -> seal, asserted."

  alias Smalt.GraphLaw.SqlShapeGen
  alias Smalt.GraphLaw.Validator
  alias Smalt.Ocel
  alias Smalt.POWL2.ChangeFeed
  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.LawCompiler
  alias Smalt.POWL2.Reticle
  alias Smalt.Powl2.HsmSigner
  alias Smalt.PPlan.ReceiptEngine

  @pk "gld7-orders"

  defp assert!(true, msg), do: IO.puts("  ok  " <> msg)

  defp assert!(false, msg), do: raise("GLD-7 COURT FAIL: " <> msg)

  # ---------------------------------------------------------------
  # Phase 1-2: ingest + govern
  # ---------------------------------------------------------------
  def run do
    IO.puts("GLD-7 INGEST->GOVERN->EXECUTE COURT")

    dump = Gld7.Dump.dump()
    parsed = Gld7.Parser.parse!(dump)

    assert!(map_size(parsed.tables) == 2, "parsed 2 CREATE TABLEs from dump bytes")
    assert!(length(parsed.tables["orders"]) == 5, "orders DDL: 5 columns")
    assert!(length(parsed.copies["orders"].rows) == 10, "parsed 10 order rows from COPY")
    assert!(length(parsed.copies["customers"].rows) == 3, "parsed 3 customer rows from COPY")
    assert!(parsed.copies["orders"].rows |> hd() |> Map.get("amount") == "48000",
      "COPY row values tab-parsed")


    # --- OCEL projection ---------------------------------------------
    env = Gld7.Ingest.ocel_envelope(parsed)
    assert!(length(env.events) == 13, "OCEL envelope: 13 ingest events")
    assert!(length(env.objects) == 13, "OCEL envelope: 13 objects")
    assert!(Ocel.validate_envelope(env.events, env.objects) == :ok,
      "Ocel.validate_envelope/2: no dangling relationships")

    otrace = Ocel.object_trace(env.events, "O-05")
    assert!(length(otrace) == 1 and hd(otrace)["id"] == "gld7-ing-o005",
      "object_trace/2 for O-05 returns exactly its ingest event")

    # --- govern: auto-shapes over the PARSED DDL + compiled law -------
    schema = Gld7.Ingest.schema_spec(parsed)
    ttl = SqlShapeGen.generate(schema)
    shapes = SqlShapeGen.parse(ttl)
    assert!(Map.has_key?(shapes, "SqlOrdersShape"), "SqlShapeGen emitted SqlOrdersShape from parsed DDL")

    orders_shape = shapes["SqlOrdersShape"]

    typed_rows =
      Enum.map(parsed.copies["orders"].rows, fn r ->
        Map.update!(r, "amount", &String.to_integer/1)
      end)

    Enum.each(typed_rows, fn r ->
      assert!(Validator.validate_shape(orders_shape, r) == {:ok},
        "schema admission: #{r["order_id"]} conforms SqlOrdersShape")
    end)

    assert!(match?({:invalid, _}, Validator.validate_shape(orders_shape, Map.put(hd(typed_rows), "surprise", 1))),
      "schema non-vacuity: unknown column refuses (closed shape)")

    assert!(match?({:invalid, _}, Validator.validate_shape(orders_shape, Map.put(hd(typed_rows), "amount", "48000"))),
      "schema non-vacuity: string amount refuses (datatype)")

    {:ok, law} = LawCompiler.compile_shape("ex:HighValueOrderShape", Gld7.Ingest.law_ttl())
    assert!(is_function(law, 1), "GL-2 LawCompiler compiled HighValueOrderShape guard")

    # --- partition prediction from the law (exact vs executed) --------
    {expected_conform, expected_over} =
      Enum.split_with(typed_rows, fn r ->
        law.(%{"totalAmount" => r["amount"]}) == :ok
      end)

    assert!(length(expected_over) == 2, "law partitions exactly 2 orders over-threshold")
    assert!(Enum.map(expected_over, & &1["order_id"]) == ["O-01", "O-05"],
      "over-threshold set == [O-01, O-05] (law-predicted)")
    assert!(length(expected_conform) == 8, "law partitions 8 conforming orders")

    # law non-vacuity: threshold flip changes the partition
    {:ok, law_tight} =
      LawCompiler.compile_shape("ex:HighValueOrderShape", String.replace(Gld7.Ingest.law_ttl(), "10000", "5000"))

    over_tight =
      Enum.count(typed_rows, fn r -> law_tight.(%{"totalAmount" => r["amount"]}) != :ok end)

    assert!(over_tight == 6, "tightened law (5000) refuses 6 orders - partition is law-derived, not fixture-asserted")

    # --- phase 3: execute the settlement per ingested order -----------
    cf = :"gld7_change_feed_#{System.unique_integer([:positive])}"
    {:ok, _} = ChangeFeed.start_link(base: cf)

    dets = :"gld7_dets_#{System.unique_integer([:positive])}"
    dets_path = Path.join(System.tmp_dir!(), "#{dets}.dets")
    {:ok, ^dets} = :dets.open_file(dets, file: String.to_charlist(dets_path), repair: true)

    schema_guard = fn row ->
      case Validator.validate_shape(orders_shape, row) do
        {:ok} -> :ok
        other -> other
      end
    end

    results =
      Enum.map(typed_rows, fn r ->
        oid = r["order_id"]
        doc = "order-#{oid}"
        iid = :"gld7_#{oid}_#{System.unique_integer([:positive])}"
        model = Gld7.Net.model(cf, @pk, doc, schema_guard, law)
        :ok = Reticle.admit(model)

        ctx = %{typed_row: r}

        # sync return is :ok on success, {:error, {:transition_failed, ..}}
        # on ANDON; the outcome always also arrives as a message.
        _exec = Executor.execute_admitted(iid, {:ok, model}, ctx, dets, self())

        result =
          receive do
            {:orchestration_completed, ^iid, ctx2, receipt} ->
              {:settled, iid, receipt, ctx2}

            {:orchestration_failed, ^iid, outcome} ->
              [{_k, r2}] = :dets.lookup(dets, {:powl2_receipt, iid})
              :dets.insert(dets, {{:gld7_andon, iid}, %{rule: andon_rule(outcome), order: oid}})
              {:andon, iid, r2, outcome}
          after
            15_000 -> raise("GLD-7 COURT FAIL: orchestration for #{oid} did not terminate")
          end

        {oid, result}
      end)

    {settled, andons} =
      Enum.split_with(results, fn {_oid, res} -> elem(res, 0) == :settled end)

    andon_ids = Enum.map(andons, fn {oid, _} -> oid end) |> Enum.sort()
    settled_ids = Enum.map(settled, fn {oid, _} -> oid end) |> Enum.sort()

    assert!(andon_ids == ["O-01", "O-05"],
      "executed ANDON set == law-predicted over-threshold set [O-01, O-05]")

    assert!(settled_ids == Enum.map(expected_conform, & &1["order_id"]) |> Enum.sort(),
      "executed settled set == law-predicted conforming set")

    Enum.each(andons, fn {oid, {:andon, _iid, receipt, outcome}} ->
      {:transition_failed, :validate, {:andon, {:law, rule, _diag}}} = outcome
      assert!(String.starts_with?(rule, "HighValueOrderShape/maxInclusive"),
        "#{oid}: refusal names the compiled law rule (#{rule})")

      nodes = Enum.map(receipt.steps, & &1.node)
      assert!(not Enum.any?(nodes, &(&1 == :commit)), "#{oid}: commit transition never fired")
    end)

    Enum.each(settled, fn {oid, {:settled, _iid, receipt, ctx2}} ->
      assert!(match?({:ok, 201, _etag}, ctx2.commit_cas), "#{oid}: commit CAS 201")
      etag = ChangeFeed.etag(cf, @pk, "order-#{oid}")
      assert!(is_binary(etag), "#{oid}: document present in ChangeFeed")
      nodes = Enum.map(receipt.steps, & &1.node)
      assert!(nodes == [:validate, :commit, :settle, :exit], "#{oid}: settlement chain validate->commit->settle")
    end)

    docs_with_etag =
      Enum.count(results, fn {oid, _} -> is_binary(ChangeFeed.etag(cf, @pk, "order-#{oid}")) end)

    assert!(docs_with_etag == 8, "ChangeFeed holds exactly the 8 settled documents")

    # --- phase 4: ONE ReceiptEngine run seals everything --------------
    hsm = :"gld7_hsm_#{System.unique_integer([:positive])}"
    {:ok, _} = HsmSigner.start_link(name: hsm)

    run_id = "gld7-run-#{System.unique_integer([:positive])}"
    seal_path = Path.join(System.tmp_dir!(), "#{run_id}.dets")
    {:ok, ^run_id} = ReceiptEngine.open(run_id, seal_path)

    # ingest leaves first (epochs 1..13), then per-order executor steps
    env.events
    |> Enum.with_index(1)
    |> Enum.each(fn {ev, epoch} ->
      ReceiptEngine.record_step(run_id, %{epoch: epoch, act: "gld7.ingest", delta: ev})
    end)

    next_epoch = length(env.events) + 1

    {_, final_epoch} =
      Enum.reduce(results, {next_epoch, next_epoch - 1}, fn {_oid, res}, {e, _} ->
        steps =
          case elem(res, 0) do
            s when s in [:settled, :andon] -> elem(res, 2).steps
          end

        n = length(steps)

        steps
        |> Enum.with_index(e)
        |> Enum.each(fn {step, epoch} ->
          ReceiptEngine.record_step(run_id, %{
            epoch: epoch,
            act: "gld7.settlement.#{step.node}",
            delta: step
          })
        end)

        {e + n, e + n - 1}
      end)

    signer = fn digest ->
      {:ok, sig} = HsmSigner.sign_digest(hsm, digest)
      sig
    end

    sealed = ReceiptEngine.seal_receipt(run_id, nil, signer)

    expected_leaves = length(env.events) + Enum.reduce(results, 0, fn {_oid, res}, acc ->
      acc + length(elem(res, 2).steps)
    end)

    assert!(sealed.step_count == expected_leaves,
      "sealed receipt holds #{expected_leaves} leaves (13 ingest + all executor steps)")

    assert!(byte_size(sealed.merkle_root) == 32 and sealed.signature != nil,
      "sealed Merkle root is 32 bytes and HSM-signed")

    assert!(sealed.phi_lease_final == final_epoch, "phi_lease_final == max epoch")

    # every order's events are committed leaves: its ingest delta_hash and
    # all its executor step delta_hashes are present in the sealed ledger
    delta_hashes = ReceiptEngine.steps(run_id) |> Enum.map(& &1.delta_hash) |> MapSet.new()

    Enum.each(results, fn {oid, res} ->
      ingest_ev = Enum.find(env.events, fn ev -> hd(ev["relationships"])["objectId"] == oid end)

      ingest_hex =
        Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(ingest_ev)), case: :lower)

      assert!(MapSet.member?(delta_hashes, ingest_hex), "sealed receipt contains the #{oid} ingest event leaf")

      steps = elem(res, 2).steps

      Enum.each(steps, fn step ->
        hex = Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(step)), case: :lower)
        assert!(MapSet.member?(delta_hashes, hex), "sealed receipt contains a #{oid} settlement step leaf")
      end)
    end)

    # --- partition exactness in the SEALED receipt --------------------
    all_hashes = ReceiptEngine.steps(run_id) |> Enum.map(& &1.hash)
    assert!(length(all_hashes) == expected_leaves, "step ledger == leaf count")

    acts = ReceiptEngine.steps(run_id) |> Enum.map(& &1.act_iri)
    commit_acts = Enum.count(acts, &String.contains?(&1, "settlement.commit"))

    andon_orders =
      results
      |> Enum.filter(fn {_oid, res} -> elem(res, 0) == :andon end)
      |> Enum.map(fn {oid, _} -> oid end)

    settle_chains = Enum.count(acts, &String.contains?(&1, "settlement.settle"))

    assert!(commit_acts == 8, "receipt carries exactly 8 commit acts (settlement chains)")
    assert!(settle_chains == 8, "receipt carries exactly 8 settle acts")
    assert!(length(andon_orders) == 2, "2 ANDON orders stopped at validate")

    # non-vacuity: dropping one leaf changes the root
    root_all = ReceiptEngine.merkle_root(all_hashes)
    root_less = ReceiptEngine.merkle_root(List.delete_at(all_hashes, 0))
    assert!(root_all != root_less, "non-vacuity: dropping a leaf changes the Merkle root")

    assert!(MapSet.new(andon_ids) |> MapSet.disjoint?(MapSet.new(settled_ids)),
      "ANDON and settled sets are disjoint")

    assert!(Enum.sort(andon_ids ++ settled_ids) == Enum.sort(Enum.map(typed_rows, & &1["order_id"])),
      "partition exhaustive over all 10 ingested orders")

    File.rm(dets_path)
    ReceiptEngine.close(run_id)
    File.rm(seal_path)

    IO.puts("GLD-7 COURT: PASS")
    IO.puts("orders: 10 | andon: #{Enum.join(andon_ids, ",")} | settled: #{length(settled_ids)}")
    IO.puts("sealed leaves: #{sealed.step_count}  merkle_root: #{Base.encode16(sealed.merkle_root, case: :lower)}")
    IO.puts("signature: #{inspect(sealed.signature)}")
    :ok
  end

  defp andon_rule({:transition_failed, _node, {:andon, {:law, rule, _diag}}}), do: rule
  defp andon_rule({:transition_failed, _node, {:andon, {:schema_admission, _v}}}),
    do: :schema_admission

end

# BK-POWLH4: converted from self-exiting script (System.stop at load) to an
# ExUnit case so `mix test test/integration` runs it instead of dropping the
# batch. Court legs unchanged; the run/0 verdict is asserted, not halted on.
defmodule Gld7IngestToSettlementCourtTest do
  use ExUnit.Case, async: false

  test "GLD-7 SQL dump -> OCEL -> graphlaw laws -> POWL settlement court" do
    case Gld7.Court.run() do
      :ok -> :ok
      other -> flunk("GLD-7 COURT: FAIL #{inspect(other)}")
    end
  end
end
