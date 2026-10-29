defmodule Smalt.GraphLawRuleChangeTest do
  @moduledoc """
  GL-7 court: "rule change = RDF edit, not refactor".

  The SAME settlement net (one AST: intake -> validate -> commit -> settle
  -> done) runs three times under three compiled laws — each law is a TTL
  string handed to `Smalt.POWL2.LawCompiler.compile_shape/2`, never a code
  edit:

    1. `sh:maxInclusive 10000` on `totalAmount` — the $15k order has no
       compliance signature, the ceiling fires, ANDON stops the line.
    2. `sh:maxInclusive 20000` — the SAME $15k order now admits.
    3. two required signatures (`sh:minCount 1` on `complianceSignature`
       and `financeSignature`) — ANDON returns (neither signature present).

  The property under proof: across all three runs the workflow net topology
  is identical — same transition ids, same edges, same guards — only the
  guard predicate swapped. Rules live in the shapes, not the net.
  """

  use ExUnit.Case, async: false

  alias Smalt.Powl2.Andon
  alias Smalt.POWL2.LawCompiler
  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.Reticle
  alias Smalt.POWL2.Reticle.AST
  alias Smalt.POWL2.ChangeFeed
  alias Smalt.Powl2.HsmSigner
  alias Smalt.PPlan.ReceiptEngine

  @pk "gl7-orders"

  # ---------------------------------------------------------------------------
  # The three laws (TTL strings — the RDF edits)
  # ---------------------------------------------------------------------------

  @law_v1 ~s(ex:OrderShape a sh:NodeShape ;
      sh:targetClass ex:Order ;
      sh:property [
          sh:path "totalAmount" ;
          sh:maxInclusive 10000 ;
          sh:message "GL7: order total exceeds the 10000 settlement ceiling" ;
      ] .)

  @law_v2 ~s(ex1:OrderShape a sh:NodeShape ;
      sh:targetClass ex1:Order ;
      sh:property [
          sh:path "totalAmount" ;
          sh:maxInclusive 20000 ;
          sh:message "GL7: order total exceeds the 20000 settlement ceiling" ;
      ] .)

  @law_v3 ~s(ex2:OrderShape a sh:NodeShape ;
      sh:targetClass ex2:Order ;
      sh:property [
          sh:path "complianceSignature" ;
          sh:minCount 1 ;
          sh:message "GL7: compliance signature required" ;
      ] ,
      [
          sh:path "financeSignature" ;
          sh:minCount 1 ;
          sh:message "GL7: finance signature required" ;
      ] .)

  @order %{"totalAmount" => 15_000, "region" => "US"}

  # ---------------------------------------------------------------------------
  # Courts
  # ---------------------------------------------------------------------------

  @tag :gl7_court
  test "run 1: threshold 10000 — $15k order without signature -> ANDON" do
    {:ok, guard} = LawCompiler.compile_shape("ex:OrderShape", @law_v1)
    board = run_order(guard)

    # Executor's native ANDON envelope names the violated shape rule.
    assert {:error, {:powl2_andon, :validate, rule_id, diag}} = board.exec_status
    assert rule_id == "OrderShape/maxInclusive/totalAmount"
    assert diag =~ "10000 settlement ceiling"

    # The court mints the agent-consumable ANDON receipt from the refusal
    # (Smalt.Powl2.Andon): the digest commits to the exact refused order.
    andon = Andon.format_andon(rule_id, diag, @order, ts: 0, session: "gl7-court")
    assert andon.context_digest == digest(@order)
    assert andon.repair_hint != ""
    assert andon.agent_message =~ "OrderShape/maxInclusive/totalAmount"

    # The walk stopped at validate: intake ran, commit never fired, the
    # ChangeFeed holds no document for the refused order.
    assert [:intake, :validate] = node_path(board.receipt)
    assert board.commit_never_fired
    assert nil == ChangeFeed.etag(board.cf, @pk, board.doc)

    # The persisted receipt carries the refusal; the andon ledger names it.
    assert {:error, {:powl2_andon, :validate, ^rule_id, ^diag}} = board.receipt.status
    assert %{} = andon_row(board)

    sealed = seal(board.receipt)
    assert sealed.step_count == length(board.receipt.steps)
    assert sealed.phi_lease_final == sealed.step_count
    assert byte_size(sealed.merkle_root) == 32
  end

  @tag :gl7_court
  test "run 2: threshold 20000 (TTL edit only) — same $15k order admits" do
    {:ok, guard} = LawCompiler.compile_shape("ex1:OrderShape", @law_v2)
    board = run_order(guard)

    assert :ok = board.exec_status
    assert [:intake, :validate, :commit, :settle, :done] = node_path(board.receipt)
    assert {:ok, 201, etag} = board.commit_cas
    assert etag == ChangeFeed.etag(board.cf, @pk, board.doc)
  end

  @tag :gl7_court
  test "run 3: two signatures required (TTL edit only) — ANDON returns" do
    {:ok, guard} = LawCompiler.compile_shape("ex2:OrderShape", @law_v3)
    board = run_order(guard)

    assert {:error, {:powl2_andon, :validate, rule_id, diag}} = board.exec_status
    # Fail-closed: the first required-signature violation halts the line.
    assert rule_id == "OrderShape/minCount/complianceSignature"
    assert diag =~ "compliance signature required"

    assert board.commit_never_fired
    assert nil == ChangeFeed.etag(board.cf, @pk, board.doc)
  end

  @tag :gl7_court
  test "property: net topology is identical across all three laws" do
    models =
      for {ttl, subject} <- [ {@law_v1, "ex:OrderShape"}, {@law_v2, "ex1:OrderShape"}, {@law_v3, "ex2:OrderShape"} ] do
        {:ok, guard} = LawCompiler.compile_shape(subject, ttl)
        net(guard)
      end

    # Same AST topology: same transition ids, same edges, same guards, same
    # start/end — only the guard closures inside validate's op differ.
    topologies = Enum.map(models, &topology/1)
    assert length(Enum.uniq(topologies)) == 1
    assert [topo, topo, topo] = topologies

    # The guards themselves DID change: v1 refuses 15k, v2 admits it,
    # v3 refuses it on the missing signature.
    {:ok, guard1} = LawCompiler.compile_shape("ex:OrderShape", @law_v1)
    {:ok, guard2} = LawCompiler.compile_shape("ex1:OrderShape", @law_v2)
    {:ok, guard3} = LawCompiler.compile_shape("ex2:OrderShape", @law_v3)
    assert match?({:violation, _, _}, guard1.(@order))
    assert :ok = guard2.(@order)
    assert match?({:violation, _, _}, guard3.(@order))
  end

  # ---------------------------------------------------------------------------
  # Orchestration under court
  # ---------------------------------------------------------------------------

  defp run_order(guard) do
    cf = :"gl7_change_feed_#{System.unique_integer([:positive])}"
    {:ok, _} = ChangeFeed.start_link(base: cf)

    dets = :"gl7_dets_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{dets}.dets")
    File.mkdir_p!(Path.dirname(path))
    # OTP-29 dets: the open option is `file` (charlist); `path` is badarg.
    {:ok, ^dets} = :dets.open_file(dets, file: String.to_charlist(path), repair: true)
    on_exit(fn -> File.rm(path) end)

    doc = "order-#{System.unique_integer([:positive])}"
    instance_id = :"gl7_#{System.unique_integer([:positive])}"

    %{net: model} = net(guard)
    assert :ok = Reticle.admit(model)

    ctx = %{cf: cf, pk: @pk, doc: doc, order: @order}

    _exec_return = Executor.execute_admitted(instance_id, {:ok, model}, ctx, dets, self())

    {status, receipt, ctx_out} =
      receive do
        {:orchestration_completed, ^instance_id, ctx2, receipt} ->
          {:ok, receipt, ctx2}

        {:orchestration_refused, ^instance_id, andon} ->
          [{_, r}] = :dets.lookup(dets, {:powl2_receipt, instance_id})
          {{:error, andon}, r, %{}}
      after
        5_000 -> flunk("orchestration did not terminate")
      end

    steps = receipt.steps
    commit_never_fired = not Enum.any?(steps, &(&1.node == :commit))

    %{
      exec_status: status,
      receipt: receipt,
      cf: cf,
      dets: dets,
      doc: doc,
      commit_never_fired: commit_never_fired,
      commit_cas: Map.get(ctx_out, :commit_cas)
    }
  end

  # The net: ONE settlement topology, parameterized only by the law guard.
  defp net(guard) do
    net = %AST.ChoiceGraph{
      children: %{
        intake: %AST.Transition{id: :intake, label: :intake, op: intake_op()},
        # The law rides the executor's native guard seam: a
        # {:graphlaw_guard, shape, fun} op. Swapping the TTL swaps only this
        # tuple's fun — the net's ids, edges and guards are untouched.
        validate:
          %AST.Transition{
            id: :validate,
            label: :validate,
            # Fixed net-side adapter (identical across all three laws): the
            # executor hands the guard the walk ctx; the law reads the order.
            op: {:graphlaw_guard, "OrderShape", fn ctx -> guard.(ctx.order) end}
          },
        commit: %AST.Transition{id: :commit, label: :commit, op: commit_op()},
        settle: %AST.Transition{id: :settle, label: :settle, op: settle_op()},
        done: %AST.Transition{id: :done, label: :done, op: tau_op()},
        # Silent entry place: the executor enters the walk by picking an edge
        # FROM start (start itself is never evaluated), so the net begins with
        # a tau entry node whose edge fires intake.
        begin: %AST.Transition{id: :begin, label: :begin, op: tau_op()}
      },
      start: :begin,
      end: :done,
      edges: [
        {:begin, :intake},
        {:intake, :validate},
        {:validate, :commit},
        {:commit, :settle},
        {:settle, :done}
      ],
      # Unguarded fallback edges only: the law is enforced at the validate
      # node's guard, not by edge guards (guards map is empty in every law).
      guards: %{}
    }

    %{net: net, guard: guard}
  end

  defp topology(%{net: %AST.ChoiceGraph{} = net}) do
    %{
      ids: net.children |> Map.keys() |> Enum.sort(),
      transition_ids:
        net.children |> Enum.map(fn {_k, %AST.Transition{id: id}} -> id end) |> Enum.sort(),
      start: net.start,
      end: net.end,
      edges: Enum.sort(net.edges),
      guards: net.guards
    }
  end

  # -- ops ----------------------------------------------------------------------

  defp intake_op, do: fn ctx -> {:ok, Map.put(ctx, :intake, :ok), :intake_ok} end

  defp commit_op do
    fn ctx ->
      case ChangeFeed.put_item(ctx.cf, ctx.pk, ctx.doc, ctx.order) do
        {:ok, status, etag} ->
          {:ok, Map.put(ctx, :commit_cas, {:ok, status, etag}), :committed}

        {:error, 412, current} ->
          {:error, {:cas_stale, current}}

        other ->
          {:error, {:unexpected_cas_result, other}}
      end
    end
  end

  defp settle_op, do: fn ctx -> {:ok, Map.put(ctx, :settled, true), :settled} end
  defp tau_op, do: fn ctx -> {:ok, ctx} end

  # -- helpers ---------------------------------------------------------------------

  defp digest(term),
    do: Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(term)), case: :lower)

  defp node_path(receipt), do: Enum.map(receipt.steps, & &1.node)

  defp andon_row(board) do
    case :dets.lookup(board.dets, {:powl2_andon, :validate}) do
      [{_, row}] -> row
      [] -> flunk("no andon row persisted for :validate")
    end
  end

  # Receipt seal: one provenance step per executor step, HSM-signed.
  defp seal(receipt) do
    hsm = :"gl7_hsm_#{System.unique_integer([:positive])}"
    {:ok, _} = HsmSigner.start_link(name: hsm)
    on_exit(fn -> if pid = Process.whereis(hsm), do: GenServer.stop(pid) end)

    run_id = "gl7-run-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{run_id}.dets")
    File.mkdir_p!(Path.dirname(path))
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)

    Enum.with_index(receipt.steps, 1)
    |> Enum.each(fn {step, epoch} ->
      ReceiptEngine.record_step(run_id, %{epoch: epoch, act: "gl7.#{step.node}", delta: step})
    end)

    signer = fn digest ->
      {:ok, sig} = HsmSigner.sign_digest(hsm, digest)
      sig
    end

    sealed = ReceiptEngine.seal_receipt(run_id, nil, signer)

    on_exit(fn ->
      ReceiptEngine.close(run_id)
      File.rm(path)
    end)

    sealed
  end
end
