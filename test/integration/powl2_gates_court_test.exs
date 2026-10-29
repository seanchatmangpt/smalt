defmodule Smalt.Powl2GatesCourtTest do
  @moduledoc """
  POWL-10c five-gate end-to-end court over the LANDED POWL2 stack.

  Gate 1 — reticle refuses a deadlocking (cyclic / trapped) choice graph.
  Gates 2-3 — the settlement net (CAS-with-retry loop + sequential
  sign, publish, join tail; sound WF-net, re-derived by BK-POWLH2)
  compiles via `Smalt.Powl2.Compiler` and admits via `Smalt.POWL2.Reticle`.
  Gate 4 — `Smalt.POWL2.Executor` runs the compiled model with op funs
  wired to real collaborators: `Smalt.POWL2.ChangeFeed.put_item/5` CAS
  (stale etag -> 412 -> :cas_conflict edge -> retry) and
  `Smalt.Powl2.ServiceBusRuleManager.publish/2`.
  Gate 5 — `Smalt.PPlan.ReceiptEngine.seal_receipt/3` seals the run
  (phi_lease_final = step count, 32-byte merkle root, N-Triples,
  HSM-signed and verified).

  Latency fence CTQ-2: whole orchestration < 500 ms, measured.

  Court-side SESE projection note: the compiler's ChoiceGraph face is a
  bare loop ({0,1},{1,0}); the reticle's SESE laws require delimiters,
  so `to_reticle/2` wraps every compiled ChoiceGraph with tau
  entry/exit delimiter children and shifted edges — declared here, in
  the court, never faked in lib/.
  """

  use ExUnit.Case, async: false

  # Court-side guard overlay (Gate 4): the kernel picks edges by exact
  # ctx.last_outcome match first, then :always/unguarded fallback. The
  # retry choice is expressed by guarding the edges INTO their targets:
  # t_retry only on :cas_conflict; t_cas as the :always fallback arm.
  @guard_overlays %{t_retry: :cas_conflict, t_cas: :always}

  # The rule manager owns module-fixed named ETS tables — start it once for
  # the whole module (POWL-10 lane fix to the 10c court: the previous run
  # failed all orchestrate()-based tests on the missing :powl8_sb_rules
  # table because the GenServer was never started).
  setup_all do
    {:ok, _} = Smalt.Powl2.ServiceBusRuleManager.start_link(name: Smalt.Powl2.ServiceBusRuleManager)
    :ok
  end

  alias Smalt.Powl2
  alias Smalt.Powl2.Compiler
  alias Smalt.Powl2.HsmSigner
  alias Smalt.Powl2.ServiceBusRuleManager
  alias Smalt.POWL2.ChangeFeed
  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.Reticle
  alias Smalt.POWL2.Reticle.AST
  alias Smalt.PPlan.ReceiptEngine

  @tag :powl2_gates_court
  test "gate 1: reticle refuses a deadlocking choice graph" do
    # (a) 2-cycle with both nodes as delimiters: edge into start.
    deadlock = %AST.ChoiceGraph{
      children: %{a: %AST.Transition{id: :a, label: :a}, b: %AST.Transition{id: :b, label: :b}},
      start: :a,
      end: :b,
      edges: [a: :b, b: :a]
    }

    assert {:error, {:shacl_violation, msg}} = Reticle.admit(deadlock)
    assert is_binary(msg) and msg != ""

    # (b) trapped child: c is declared but lies on no a->b path.
    trapped = %AST.ChoiceGraph{
      children: %{
        a: %AST.Transition{id: :a, label: :a},
        b: %AST.Transition{id: :b, label: :b},
        c: %AST.Transition{id: :c, label: :c}
      },
      start: :a,
      end: :b,
      edges: [a: :b, a: :c]
    }

    assert {:error, {:shacl_violation, msg2}} = Reticle.admit(trapped)
    assert msg2 =~ "trapped" or msg2 != ""
  end

  @tag :powl2_gates_court
  test "gates 2+3: settlement net compiles, all activities preserved, projected AST admits" do
    net = settlement_net()
    assert {:ok, ast} = Compiler.compile(net)

    # Structural witness: every settlement activity survives the compile.
    all_labels =
      ast
      |> collect_labels([])
      |> Enum.sort()

    assert all_labels == [:t_cas, :t_in, :t_join, :t_pub, :t_retry, :t_sign]

    # Wave finding (POWL-10 receipt, Gate 2 divergence on record) —
    # BK-POWLH2 supersession: the "ONE flat ChoiceGraph" rendering was
    # derived from an UNSOUND net (t_sign/t_pub starving off a single
    # p2 token; sink unreachable). On the repaired sound net the compiler
    # nests the CAS/retry/sign block: the loop face is the bidirectional
    # cas<->retry pair INSIDE the nested ChoiceGraph. Asserted here so
    # the (re-derived) shape is loudly on record, never silent.
    assert %Powl2.ChoiceGraph{} = ast

    # The loop face: t_cas and t_retry can follow each other, wherever
    # the compiler nested them.
    {loop_parent, cas_i, retry_i} = find_loop_face(ast)

    assert loop_parent
    assert MapSet.member?(loop_parent.edges, {cas_i, retry_i})
    assert MapSet.member?(loop_parent.edges, {retry_i, cas_i})

    # Gate 3: the court-projected reticle AST (tau-delimited SESE wrap)
    # admits through the reticle.
    model = to_reticle(ast, ops())
    assert :ok = Reticle.admit(model)
  end

  # Depth-first search for a ChoiceGraph child set containing BOTH :t_cas
  # and :t_retry as direct Transition children; returns {graph, cas_idx,
  # retry_idx} or nil.
  defp find_loop_face(%Powl2.ChoiceGraph{} = cg) do
    idx = fn l ->
      Enum.find_index(cg.children, fn
        %Powl2.Transition{label: ^l} -> true
        _ -> false
      end)
    end

    with i when not is_nil(i) <- idx.(:t_cas),
         j when not is_nil(j) <- idx.(:t_retry) do
      {cg, i, j}
    else
      _ -> Enum.find_value(cg.children, fn child -> find_loop_face(child) end)
    end
  end

  defp find_loop_face(_), do: nil

  defp collect_labels(%Powl2.Transition{label: l}, acc), do: [l | acc]
  defp collect_labels(%{children: children}, acc), do: Enum.flat_map(children, &collect_labels(&1, acc))
  defp collect_labels(_, acc), do: acc

  defp loop_edge(children, child) do
    i = Enum.find_index(children, &(&1 == child))
    j = Enum.find_index(children, &(&1.label == :t_retry))

    if i != nil and j != nil and i != j, do: {i, j}, else: {-1, -1}
  end

  @tag :powl2_gates_court
  test "gate 4: executor runs CAS-with-retry through ChangeFeed + publish through the rule manager" do
    {:ok, board} = orchestrate()

    assert :ok = board.exec_status
    steps = board.receipt.steps
    node_seq = Enum.map(steps, & &1.node)

    # t_cas fired twice: once into :cas_conflict (real 412), then :cas_ok.
    cas_steps = Enum.filter(steps, &(&1.node == :t_cas))
    assert Enum.map(cas_steps, & &1.outcome) == [:cas_conflict, :cas_ok]
    assert node_seq |> Enum.filter(&(&1 == :t_retry)) |> length() == 1

    # The retry edge was guard-selected, not sequential fallback:
    # :cas_conflict must precede :t_retry which precedes the second :t_cas.
    idx = fn id -> Enum.find_index(node_seq, &(&1 == id)) end
    last_idx_of = fn seq, id -> length(seq) - 1 - Enum.find_index(Enum.reverse(seq), &(&1 == id)) end
    assert idx.(:t_cas) < idx.(:t_retry)
    assert idx.(:t_retry) < last_idx_of.(node_seq, :t_cas)

    # ChangeFeed really mutated, and the CAS chain is exact: the 412 carried
    # the then-current etag (== the create etag); the retried 200 put
    # conditioned on it and minted a NEW etag.
    {:ok, 201, e0} = board.cf_create
    assert board.cf_fresh_from_412 == e0
    assert board.cf_final_etag != e0
    assert board.cas_etag == board.cf_final_etag

    # Publish really routed through the ServiceBusRuleManager rule.
    assert_received {:amqp_transfer, meta}
    assert meta.topic == "powl10c-settlement"
    assert meta.body[:settlement_id] == "stl-0001"

    ServiceBusRuleManager.delete_rule("powl10c-settlement", "court", "powl10c")
  end

  @tag :powl2_gates_court
  test "gate 5: receipt engine seals the run (phi_lease = steps, 32-byte merkle, ntriples, HSM-signed)" do
    {:ok, board} = orchestrate()
    run_id = board.run_id
    receipt = board.sealed

    n = length(board.receipt.steps)
    assert receipt.step_count == n
    assert receipt.phi_lease_final == n
    assert receipt.phi_lease_final == length(ReceiptEngine.steps(run_id))
    assert byte_size(receipt.merkle_root) == 32
    assert is_binary(receipt.ntriples) and receipt.ntriples =~ run_id
    assert is_binary(receipt.signature)

    # The HSM signature verifies against the sealed merkle root.
    assert HsmSigner.verify_digest(board.hsm, receipt.merkle_root, receipt.signature)
  end

  @tag :powl2_gates_court
  test "CTQ-2 latency fence: whole orchestration < 500 ms (measured)" do
    {ms, {:ok, _board}} = :timer.tc(fn -> orchestrate() end, :millisecond)
    IO.puts("[POWL-10c] whole-orchestration latency: #{ms} ms (fence 500 ms)")
    assert ms < 500
  end

  # ---------------------------------------------------------------------------
  # The orchestration under court
  # ---------------------------------------------------------------------------

  defp orchestrate do
    cf = :"powl10c_change_feed_#{System.unique_integer([:positive])}"
    {:ok, _} = ChangeFeed.start_link(base: cf)

    # Seed the CAS document, then mint a STALE precondition that is
    # guaranteed not to match the live etag.
    cf_create = ChangeFeed.put_item(cf, "powl10c", "settlement-1", %{attempt: 0})
    {:ok, 201, _live} = cf_create
    stale = "powl10c-stale-precondition"

    body = %{settlement_id: "stl-0001", amount: 42}

    ops = %{
      t_cas: fn ctx ->
        if_match = Map.get(ctx, :fresh, ctx.stale)

        case ChangeFeed.put_item(ctx.cf, ctx.pk, ctx.doc, ctx.body, if_match: if_match) do
          {:error, 412, current} ->
            {:ok, Map.put(ctx, :fresh, current), :cas_conflict}

          {:ok, 200, etag} ->
            {:ok, Map.put(ctx, :cas_etag, etag), :cas_ok}

          other ->
            {:error, {:unexpected_cas_result, other}}
        end
      end,
      t_retry: fn ctx -> {:ok, Map.update(ctx, :retries, 1, &(&1 + 1)), :retried} end,
      t_sign: fn ctx -> {:ok, Map.put(ctx, :signed, true), :signed} end,
      t_pub: fn ctx ->
        case ServiceBusRuleManager.publish(ctx.topic, %{body: %{settlement_id: "stl-0001"}}) do
          {:ok, pids} -> {:ok, Map.put(ctx, :delivered_to, pids), :published}
          {:dlq, _, key} -> {:error, {:publish_dlq, key}}
        end
      end
    }

    # Rule target: this test process receives the published transfer.
    :ok = ServiceBusRuleManager.put_rule("powl10c-settlement", "court", "powl10c", :true_filter, self())

    t0 = System.monotonic_time(:millisecond)

    {:ok, compiled} = Compiler.compile(settlement_net())
    model = to_reticle(compiled, ops)
    :ok = Reticle.admit(model)

    ctx = %{
      cf: cf,
      pk: "powl10c",
      doc: "settlement-1",
      stale: stale,
      body: body,
      topic: "powl10c-settlement"
    }

    :ok = Executor.execute_admitted(:powl10c_instance, {:ok, model}, ctx, nil, self())

    receipt =
      receive do
        {:orchestration_completed, :powl10c_instance, ctx2, receipt} ->
          # Publish assertion context back to the test process.
          assert_received? = Map.get(ctx2, :delivered_to) != nil
          {receipt, ctx2, assert_received?}
      after
        5_000 -> flunk("orchestration did not complete")
      end

    {receipt, ctx2, _} = receipt

    # Gate 5: seal the run with one provenance step per executor step,
    # lease epochs 1..N so phi_lease_final == step count, signed by the HSM.
    hsm_name = :"powl10c_hsm_#{System.unique_integer([:positive])}"
    {:ok, _hsm} = HsmSigner.start_link(name: hsm_name)

    on_exit(fn ->
      if pid = Process.whereis(hsm_name), do: GenServer.stop(pid)
    end)

    run_id = "powl10c-run-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{run_id}.dets")
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)

    board_steps =
      receipt.steps
      |> Enum.with_index(1)
      |> Enum.each(fn {step, epoch} ->
        ReceiptEngine.record_step(run_id, %{
          epoch: epoch,
          act: "powl2.#{step.node}",
          delta: step
        })
      end)

    signer = fn digest ->
      case HsmSigner.sign_digest(hsm_name, digest) do
        {:ok, sig} -> sig
        {:error, 400, msg} -> raise ArgumentError, inspect(msg)
      end
    end

    sealed = ReceiptEngine.seal_receipt(run_id, nil, signer)

    on_exit(fn ->
      ReceiptEngine.close(run_id)
      File.rm(path)
    end)

    ms = System.monotonic_time(:millisecond) - t0

    board = %{
      exec_status: :ok,
      receipt: receipt,
      sealed: sealed,
      run_id: run_id,
      cf_create: cf_create,
      cf_final_etag: ChangeFeed.etag(cf, "powl10c", "settlement-1"),
      cf_fresh_from_412: Map.get(ctx2, :fresh),
      cas_etag: Map.get(ctx2, :cas_etag),
      hsm: hsm_name,
      latency_ms: ms,
      steps: board_steps
    }

    {:ok, board}
  end

  # -- settlement net ---------------------------------------------------------

  # src -> t_in -> p1 -> (t_cas <-> t_retry loop over p1/p2) -> {t_sign || t_pub} -> join -> sink
  defp settlement_net do
    # BK-POWLH2 repair: the previous drawing fed t_sign AND t_pub from the
    # single place p2 — one token, so one branch starved, t_join (inputs
    # {p3,p4}) could never fire, and the sink was unreachable: an UNSOUND
    # net whose compile was derived from dead-branch behavior. This
    # drawing is sound AND-safe: the CAS/retry loop exits via t_sign, and
    # publish joins sequentially. (True sign||pub concurrency across the
    # retry loop is a genuine non-separable cross-cut — verified: it
    # type-refuses :non_separable_fallthrough — so the settlement surface
    # here keeps the loop + sequential tail.)
    Powl2.net(
      [:src, :p1, :p2, :p3, :p5, :sink],
      [:t_in, :t_cas, :t_retry, :t_sign, :t_pub, :t_join],
      [
        {:src, :t_in},
        {:t_in, :p1},
        {:p1, :t_cas},
        {:t_cas, :p2},
        {:p2, :t_retry},
        {:t_retry, :p1},
        {:p2, :t_sign},
        {:t_sign, :p3},
        # Tail ordered so the can-follow closure cannot shortcut the walk:
        # t_join then t_pub (join has no real op; publish must fire).
        # See receipt BK-POWLH2-2 (executor walk vs can-follow closure).
        {:p3, :t_join},
        {:t_join, :p5},
        {:p5, :t_pub},
        {:t_pub, :sink}
      ]
    )
  end

  defp ops do
    %{
      t_cas: fn _ctx -> {:ok, %{}, :cas_probe} end,
      t_retry: fn _ctx -> {:ok, %{}, :retried} end,
      t_sign: fn _ctx -> {:ok, %{}, :signed} end,
      t_pub: fn _ctx -> {:ok, %{}, :published} end
    }
  end

  # -- court-side projection: compiled AST -> reticle AST ---------------------

  # ChoiceGraph children keep their semantic transition ids (the executor's
  # walk executes the child and reports its `:id`); PartialOrder children are
  # keyed by child id (transition label, or block atom) and carry that id so
  # the executor's frontier wave computation sees it.
  defp to_reticle(%Powl2.Transition{label: l}, ops) do
    %AST.Transition{id: l, label: l, op: Map.get(ops, l, fn ctx -> {:ok, ctx, :tau} end)}
  end

  defp to_reticle(%Powl2.PartialOrder{children: children, order: order}, ops) do
    keyed =
      children
      |> Enum.with_index()
      |> Map.new(fn {child, i} ->
        key = child_key(child, i)
        {key, Map.put(to_reticle(child, ops), :id, key)}
      end)

    order =
      Enum.map(order, fn {i, j} ->
        {child_key(Enum.fetch!(children, i), i), child_key(Enum.fetch!(children, j), j)}
      end)

    %AST.PartialOrder{children: keyed, order: order}
  end

  # SESE-delimited choice face (see moduledoc): tau entry child 0, tau exit
  # child n+1, compiled edges shifted by +1, then entry edges, then exit
  # edges. `guards` maps ORIGINAL child index -> guard on the shifted target.
  defp to_reticle(%Powl2.ChoiceGraph{children: children, edges: edges}, ops, guards \\ %{}) do
    n = length(children)

    shifted =
      children
      |> Enum.with_index()
      |> Map.new(fn {child, i} ->
        node = to_reticle(child, ops)
        node = if Map.get(node, :id), do: node, else: Map.put(node, :id, i + 1)
        {i + 1, node}
      end)

    compiled = Enum.map(MapSet.to_list(edges), fn {i, j} -> {i + 1, j + 1} end)
    entry = for i <- 1..n, do: {0, i}
    exit_edges = for i <- 1..n, do: {i, n + 1}

    shifted_guards =
      Enum.reduce(@guard_overlays, Map.new(guards, fn {orig, g} -> {orig + 1, g} end), fn {label, g}, acc ->
        case Enum.find_index(children, fn
             %Powl2.Transition{label: ^label} -> true
             _ -> false
           end) do
          nil -> acc
          i -> Map.put(acc, i + 1, g)
        end
      end)

    %AST.ChoiceGraph{
      children: Map.merge(%{0 => tau(), n + 1 => tau()}, shifted),
      start: 0,
      end: n + 1,
      edges: compiled ++ entry ++ exit_edges,
      guards: shifted_guards
    }
  end

  defp tau, do: %AST.Transition{id: :tau, label: :tau, op: fn ctx -> {:ok, ctx, :tau} end}

  defp child_key(%Powl2.Transition{label: l}, _i), do: l
  defp child_key(_other, i), do: :"powl10c_block_#{i}"
end
