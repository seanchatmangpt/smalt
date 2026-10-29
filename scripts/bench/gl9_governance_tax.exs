# GL-9 governance-tax differential (DIRECTIVES charter exercise).
#
# Same 4-step settlement executed two ways through Smalt.POWL2.Executor:
#   (a) unguarded  — plain Transition ops, no law seam
#   (b) guarded    — GL-1 seam: op = {:graphlaw_guard, shape_id, guard, inner_op}
#                    with the guard compiled by GL-2 (Smalt.POWL2.LawCompiler)
#                    from SHACL Turtle law text.
#
# Topology: ChoiceGraph 4-step chain — the executor walks ChoiceGraph fully
# sequentially in the caller process (no Task waves), so caller-process
# reduction deltas and wall-clock both capture the ENTIRE execution: exact
# differential accounting, no scheduler spill.
#
# Measurement discipline:
#   * interleaved pair-per-iteration (unguarded, guarded) — drift-cancelled
#   * reductions: exact caller :reductions delta per run (ints, not timers)
#   * tax from medians (mean is tail-dominated by GC pauses)
#   * n=500 measured pairs after 100 warmup pairs
#
# Receipt identity: conforming runs under the SAME run id across both arms
# must produce identical projected receipts (at_ms stripped).
#
# Non-vacuity: a non-conforming ctx MUST take the andon refusal path
# (op never runs, typed refusal returned); asserted in-script.
#
# In-process, no substrate. Writes tmp/bench/gl9-governance-tax.jsonl.
# Run: MIX_BUILD_ROOT=_build-gl9 mix run --no-start scripts/bench/gl9_governance_tax.exs

defmodule GL9 do
  @transition Smalt.POWL2.Reticle.AST.Transition
  @choice Smalt.POWL2.Reticle.AST.ChoiceGraph
  @n 500
  @warmup 100
  @steps 4

  @law_ttl ~s"""
  @prefix sh: <http://www.n3.org/2001/shacl#> .
  @prefix powl: <https://smalt.local/powl2#> .

  ex:SettlementShape a sh:NodeShape ;
    sh:targetClass ex:Settlement ;
    sh:property [
      sh:path amount ;
      sh:maxInclusive 10000 ;
      sh:message "settlement amount exceeds delegated authority ceiling (10k)" ;
    ] ;
    sh:property [
      sh:path approver ;
      sh:minCount 1 ;
      sh:message "settlement requires an approver signature" ;
    ] ;
    sh:property [
      sh:path approver ;
      powl:notEquals initiator ;
      sh:message "approver must not equal initiator (self-approval exclusion)" ;
    ] ;
  .
  """

  def run do
    {:ok, guard} = Smalt.POWL2.LawCompiler.compile_shape("ex:SettlementShape", @law_ttl)

    # Non-vacuity at the guard level: over-ceiling amount MUST refuse.
    {:violation, rule_id, _diag} =
      guard.(%{"amount" => 10_001, "approver" => "a", "initiator" => "b"})

    IO.puts("guard compiled, non-vacuity witness: refusal #{rule_id}")

    dets = open_dets()
    base_ctx = %{amount: 9_500, approver: "agent-a", initiator: "agent-b", ledger: 0}

    inner_ops =
      Map.new(1..@steps, fn i ->
        {String.to_atom("s#{i}"),
         fn ctx -> {:ok, ctx |> Map.update(:ledger, 0, &(&1 + 1)) |> Map.put(:last_step, i)} end}
      end)

    unguarded_model = model(inner_ops, nil)
    guarded_model = model(inner_ops, {"SettlementShape", guard})

    # -- warmup: 100 interleaved pairs ------------------------------------------
    Enum.each(1..@warmup, fn i ->
      exec(String.to_atom("gl9_wug#{i}"), unguarded_model, base_ctx, dets)
      exec(String.to_atom("gl9_wg#{i}"), guarded_model, base_ctx, dets)
    end)

    # -- measured: interleaved pair per iteration (drift-cancelled) -------------
    {ug_wall, ug_reds, g_wall, g_reds} =
      Enum.map(1..@n, fn i ->
        pair(i, unguarded_model, guarded_model, base_ctx, dets)
      end)
      |> Enum.reduce({[], 0, [], 0}, fn {uw, ur, gw, gr}, {uws, urs, gws, grs} ->
        {[uw | uws], urs + ur, [gw | gws], grs + gr}
      end)

    :ok = :dets.sync(dets)

    # -- receipt identity (conforming runs, same run id) ------------------------
    {:ok, ug_receipt} = exec_r(:gl9_ident, unguarded_model, base_ctx, dets)
    {:ok, g_receipt} = exec_r(:gl9_ident, guarded_model, base_ctx, dets)
    identity = projected(ug_receipt) == projected(g_receipt)

    unless identity do
      IO.puts(:stderr, "PROJECTED RECEIPT DIFF:\n#{inspect(ug_receipt)}\n#{inspect(g_receipt)}")
    end

    # -- refusal path (proves the seam is live) ----------------------------------
    refusal = exec_refusal(:gl9_refusal, guarded_model, %{base_ctx | amount: 10_001}, dets)

    machine = machine()

    rows = [
      row("unguarded", ug_wall, ug_reds, machine),
      row("graphlaw_guarded", g_wall, g_reds, machine),
      %{
        lane: "gl9",
        surface: "powl2-settlement-4step",
        op: "governance-tax",
        n: @n,
        ops_per_sec: nil,
        p50_ms: nil,
        p95_ms: nil,
        p99_ms: nil,
        errors: 0,
        machine: machine,
        tax_us_per_step: tax_us(g_wall, ug_wall),
        tax_reductions_per_step:
          Float.round((g_reds / @n - ug_reds / @n) / @steps, 2),
        receipt_identity_conforming: identity,
        refusal_witness: refusal,
        context: "solo"
      }
    ]

    File.mkdir_p!("tmp/bench")
    path = "tmp/bench/gl9-governance-tax.jsonl"
    File.write!(path, Enum.map_join(rows, "", fn r -> Jason.encode!(r) <> "\n" end))

    # -- prose table ---------------------------------------------------------------
    tax = tax_us(g_wall, ug_wall)
    red_tax = Float.round((g_reds / @n - ug_reds / @n) / @steps, 2)

    IO.puts("")
    IO.puts("GL-9 governance tax — 4-step settlement (ChoiceGraph sequential), n=#{@n} pairs")
    IO.puts("")
    IO.puts("| arm | reds/step | p50 us | p99 us | ops/sec |")
    IO.puts("|---|---|---|---|---|")
    Enum.each(
      [
        {"unguarded", ug_wall, ug_reds},
        {"graphlaw_guarded", g_wall, g_reds}
      ],
      fn {name, wall, reds} ->
        IO.puts(
          "| #{name} | #{Float.round(reds / @n / @steps, 1)} | " <>
            "#{us(pct(wall, 50) * 1000)} | #{us(pct(wall, 99) * 1000)} | #{ops_sec(wall)} |"
        )
      end
    )

    IO.puts("")
    IO.puts("governance tax: #{tax} us/step, #{red_tax} reds/step")
    IO.puts("receipt identity (conforming): #{identity}")
    IO.puts("refusal witness (live seam): #{refusal}")
    IO.puts("results: #{Path.absname(path)}")
  end

  # -- pair -------------------------------------------------------------------

  defp pair(i, um, gm, ctx, dets) do
    ug_id = String.to_atom("gl9_ug#{i}")
    g_id = String.to_atom("gl9_g#{i}")

    r0 = reds()
    t0 = System.monotonic_time(:microsecond)
    exec(ug_id, um, ctx, dets)
    ug_us = System.monotonic_time(:microsecond) - t0
    ug_r = reds() - r0

    r1 = reds()
    t1 = System.monotonic_time(:microsecond)
    exec(g_id, gm, ctx, dets)
    g_us = System.monotonic_time(:microsecond) - t1
    g_r = reds() - r1

    {ug_us, ug_r, g_us, g_r}
  end

  # -- model ---------------------------------------------------------------------

  defp model(ops, law_guard) do
    children =
      Map.new(ops, fn {id, op} ->
        op2 =
          if law_guard do
            {shape, guard} = law_guard
            {:graphlaw_guard, shape, guard, op}
          else
            op
          end

        {id, %{__struct__: @transition, id: id, label: Atom.to_string(id), op: op2}}
      end)

    ids = Map.keys(ops) |> Enum.sort()
    edges = Enum.chunk_every(ids, 2, 1, :discard) |> Enum.map(&List.to_tuple/1)

    %{
      __struct__: @choice,
      id: :settlement,
      start: hd(ids),
      end: List.last(ids),
      children: children,
      edges: edges,
      guards: %{}
    }
  end

  # -- execution --------------------------------------------------------------------

  defp exec(id, model, ctx, dets) do
    :ok = Smalt.POWL2.Executor.execute_admitted(id, {:ok, model}, ctx, dets, self())
    assert_completed(id)
    :ok
  end

  defp exec_r(id, model, ctx, dets) do
    :ok = Smalt.POWL2.Executor.execute_admitted(id, {:ok, model}, ctx, dets, self())

    receive do
      {:orchestration_completed, ^id, _ctx2, receipt} -> {:ok, receipt}
      {:orchestration_refused, ^id, why} -> raise "unexpected refusal #{id}: #{inspect(why)}"
    after
      1000 -> raise "no orchestration message for #{id}"
    end
  end

  defp exec_refusal(id, model, ctx, dets) do
    # The executor keys the andon on the NODE id (:s1), not the run id.
    {:error, {:powl2_andon, _node, rule_id, _diag}} =
      Smalt.POWL2.Executor.execute_admitted(id, {:ok, model}, ctx, dets, self())

    receive do
      {:orchestration_refused, ^id, {:powl2_andon, _node, ^rule_id, _}} -> rule_id
    after
      1000 -> raise "no refusal message for #{id}"
    end
  end

  defp assert_completed(id) do
    receive do
      {:orchestration_completed, ^id, _ctx, _receipt} -> :ok
      {:orchestration_refused, ^id, why} -> raise "unexpected refusal #{id}: #{inspect(why)}"
    after
      1000 -> raise "no orchestration message for #{id}"
    end
  end

  # -- stats --------------------------------------------------------------------------

  defp tax_us(g_wall, ug_wall), do: Float.round((pct(g_wall, 50) - pct(ug_wall, 50)) * 1000 / @steps, 3)

  defp pct(list, p) do
    sorted = Enum.sort(list)
    idx = min(trunc(length(sorted) * p / 100), length(sorted) - 1)
    Enum.at(sorted, idx) / 1000.0
  end

  defp us(v), do: :erlang.float_to_binary(v, decimals: 2)
  defp reds, do: elem(:erlang.process_info(self(), :reductions), 1)
  defp ops_sec(wall), do: trunc(1_000_000 / (Enum.sum(wall) / @n))

  # -- receipt identity ------------------------------------------------------------------

  defp projected(receipt) do
    receipt
    |> Map.update!(:steps, &Enum.map(&1, fn s -> Map.delete(s, :at_ms) end))
  end
  # -- row / dets / machine ---------------------------------------------------------------

  defp row(op, wall, reds, machine) do
    %{
      lane: "gl9",
      surface: "powl2-settlement-4step",
      op: op,
      n: @n,
      ops_per_sec: ops_sec(wall),
      p50_ms: pct(wall, 50),
      p95_ms: pct(wall, 95),
      p99_ms: pct(wall, 99),
      errors: 0,
      machine: machine,
      reductions_per_step: Float.round(reds / @n / @steps, 2),
      context: "solo"
    }
  end

  defp open_dets do
    table = String.to_atom("gl9_receipts_#{System.unique_integer([:positive])}")
    path = Path.join(System.tmp_dir!(), "#{table}.dets")
    {:ok, ^table} = :dets.open_file(table, file: String.to_charlist(path))
    table
  end

  defp machine do
    {:ok, hostname} = :inet.gethostname()
    "otp#{:erlang.system_info(:otp_release)} #{hostname}"
  end
end

GL9.run()
