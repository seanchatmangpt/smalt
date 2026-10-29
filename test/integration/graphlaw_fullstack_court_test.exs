defmodule Smalt.GraphLawFullstackCourtTest do
  @moduledoc """
  GL-12 full-stack seal court: one law-governed settlement run, end to end.

  The stack under court, in one orchestration:

    * GL-2 — the compliance law is a real SHACL shape compiled by
      `Smalt.POWL2.LawCompiler.compile_shape/2` into a guard predicate
      (`HighValueOrderShape`: totalAmount ceiling 10_000).
    * GL-1 — the guard rides the `Smalt.POWL2.Executor` law-guard seam
      (`law_guard: {shape_id, fun}` on the validate transition), so the
      predicate intercepts the transition before any mutation.
    * Wire — CAS mutations ride `Smalt.POWL2.ChangeFeed.put_item/5` (If-Match
      etag chain: intake creates 201, commit matches the intake etag 200).
    * GL-3 — the mid-run law violation on step 3 (validate: $50k unsigned
      order) fires a fail-closed ANDON: the op never runs, a typed receipt
      persists to the executor DETS, and the FOND repair node merges the
      compliance signature and re-arms the walk (`:compliant` outcome).
    * FOND — the repair is the executor's node-level `:repair` edge, not a
      court-side re-entry: the refusal step and the repair step both appear
      in the run's step list, in order.
    * GL-12 — every step (lawful AND refused) is recorded into a
      `Smalt.PPlan.ReceiptEngine` ledger; the ANDON event is recorded as a
      `Smalt.Powl2.Andon.format_andon/4` receipt (the GL-3 shape) so the
      refusal is first-class audit evidence inside the sealed Merkle token.
    * GL-8 — the SAME refusal serves the wire through
      `Smalt.Powl2.AndonWire.http_envelope/2` (422 + GraphlawRefusal) and
      `amqp_properties/2` (byte-identical body), carrying the identical
      rule_id/diagnostic/context digest the ledger sealed.

  Seal assertions: the ANDON step's delta hash is a Merkle leaf of the final
  receipt (recomputed root over the ledger leaves equals the sealed root —
  the refusal is auditable history, not erased), every lawful step is
  recorded in order, phi_lease_final == step count == ledger length, and the
  HSM signature verifies against the sealed root.
  """

  use ExUnit.Case, async: false

  alias Smalt.POWL2.ChangeFeed
  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.LawCompiler
  alias Smalt.POWL2.Reticle
  alias Smalt.POWL2.Reticle.AST
  alias Smalt.PPlan.ReceiptEngine

  @pk "gl12-orders"
  @ceiling 10_000

  @law_ttl """
  @prefix sh: <http://www.w3.org/ns/shacl#> .
  @prefix ex: <http://smalt.io/shapes#> .

  ex:HighValueOrderShape a sh:NodeShape ;
    sh:targetClass ex:Order ;
    sh:property [
      sh:path totalAmount ;
      sh:maxInclusive #{@ceiling} ;
      sh:message "order total exceeds the compliance ceiling without authorized signature" ;
    ] .
  """

  # ---------------------------------------------------------------------------
  # The court: one run
  # ---------------------------------------------------------------------------

  @tag :gl12_court
  test "full-stack court: SHACL guard ANDONs step 3, FOND repair lands, ledger seals the refusal" do
    board = run_settlement()

    # -- the run completed (the refusal was repaired, not terminal) ----------
    assert :ok = board.exec_status
    refute match?({:error, _}, board.receipt.status)

    # -- step 3 is the ANDON; the path is lawful order + refusal + repair ----
    steps = board.receipt.steps
    assert [%{node: :intake}, %{node: :persist}, andon_step | rest] = steps
    assert match?({:powl2_andon, _, rule_id, _diag} when is_binary(rule_id), andon_step.outcome)
    assert node_path(rest) == [:repair, :commit, :settle, :done]

    # -- GL-2 witness: the refusal names the COMPILED SHACL rule -------------
    # LawCompiler.compile_shape/2 mints rule ids from the shape's LOCAL name
    # (build_guard(local_name(shape_iri), shape) in law_compiler.ex), so the
    # canonical rule id carries no `ex:` prefix. Adjudication GL-8: the
    # prefixed pin was the rival shape; this court re-pins to the compiler.
    {:powl2_andon, _, rule_id, diag} = andon_step.outcome
    assert rule_id == "HighValueOrderShape/maxInclusive/totalAmount"
    # The diagnostic is the shape's sh:message, carried verbatim by the
    # compiled predicate (GL-2 law: caller message wins over the default).
    assert diag == "order total exceeds the compliance ceiling without authorized signature"

    # -- GL-1 fail-closed: the refused op never mutated the wire -------------
    # The only CAS mutations are intake's create and commit's match.
    e0 = board.doc_etag
    assert is_binary(e0)
    e1 = board.commit_etag
    assert is_binary(e1) and e1 != e0
    assert e1 == ChangeFeed.etag(board.cf, @pk, board.doc)

    # -- the executor DETS andon receipt is persisted -------------------------
    assert %{shape_id: "HighValueOrderShape", rule_id: ^rule_id, diagnostic: ^diag, at_ms: at_ms} =
             dets_lookup(board.dets, {:powl2_andon, :validate})

    assert is_integer(at_ms)

    # -- GL-12: seal the ledger ----------------------------------------------
    sealed = seal(board, rule_id, diag, at_ms)

    # phi_lease count matches: sealed == step_count == recorded ledger length
    n = length(steps)
    assert sealed.phi_lease_final == n
    assert sealed.step_count == n
    assert length(ReceiptEngine.steps(board.run_id)) == n
    assert byte_size(sealed.merkle_root) == 32

    # every step is recorded, in order, on the ledger
    ledger_steps = ReceiptEngine.steps(board.run_id)
    assert Enum.map(ledger_steps, & &1.epoch) == Enum.to_list(1..n)

    # -- THE refusal is auditable history, not erased ------------------------
    # The ANDON was recorded as a GL-3 Andon receipt; its delta hash is one
    # of the Merkle leaves, and the root recomputed over ALL leaves (refusal
    # included) equals the sealed root.
    andon_receipt = andon_ledger_delta(board, rule_id, diag, at_ms)
    andon_hash = hex_sha256(:erlang.term_to_binary(andon_receipt))

    andon_ledger_step = Enum.find(ledger_steps, &(&1.delta_hash == andon_hash))

    assert andon_ledger_step != nil, "the ANDON event is missing from the sealed ledger"
    assert andon_ledger_step.epoch == 3
    assert andon_ledger_step.act_iri =~ "gl12.validate"

    leaves = Enum.map(ledger_steps, & &1.hash)
    assert ReceiptEngine.merkle_root(leaves) == sealed.merkle_root

    # The signature verifies against the sealed (refusal-inclusive) root.
    assert Smalt.Powl2.HsmSigner.verify_digest(board.hsm, sealed.merkle_root, sealed.signature)

    # -- GL-8: the wire face serves the SAME refusal shape --------------------
    envelope = Smalt.Powl2.AndonWire.http_envelope(andon_receipt)
    assert envelope.status == 422
    assert envelope.content_type =~ "application/json"

    %{"error" => err} = Jason.decode!(envelope.body)
    assert err["code"] == "GraphlawRefusal"
    assert err["rule_id"] == rule_id
    assert err["diagnostic"] == diag
    assert err["context_digest"] == andon_receipt.context_digest

    # AMQP face: byte-identical body, typed long ts, same rule facts.
    amqp = Smalt.Powl2.AndonWire.amqp_properties(andon_receipt)
    assert amqp.body == envelope.body
    assert amqp.application_properties["andon.rule_id"] == rule_id
    assert amqp.application_properties["andon.context_digest"] == andon_receipt.context_digest
    assert <<ts::signed-size(64)>> = amqp.andon_ts_long
    assert ts == andon_receipt.ts
  end

  @tag :gl12_court
  test "companion: a fully lawful run seals with zero ANDON steps (control)" do
    board = run_settlement(%{"totalAmount" => 5_000, "region" => "US"})

    assert :ok = board.exec_status
    refute Enum.any?(board.receipt.steps, fn s ->
             match?({:powl2_andon, _, _, _}, s.outcome)
           end)

    assert node_path(board.receipt.steps) == [:intake, :persist, :validate, :commit, :settle, :done]

    sealed = seal(board)
    assert sealed.step_count == length(board.receipt.steps)
    assert sealed.phi_lease_final == sealed.step_count
    assert byte_size(sealed.merkle_root) == 32
  end

  # ---------------------------------------------------------------------------
  # Orchestration under court
  # ---------------------------------------------------------------------------

  defp run_settlement(order \\ %{"totalAmount" => 50_000, "region" => "US"}) do
    cf = :"gl12_change_feed_#{System.unique_integer([:positive])}"
    {:ok, _} = ChangeFeed.start_link(base: cf)

    dets = :"gl12_dets_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{dets}.dets")
    {:ok, ^dets} = :dets.open_file(dets, file: String.to_charlist(path))
    on_exit(fn -> File.rm(path) end)

    doc = "order-#{System.unique_integer([:positive])}"
    instance_id = :"gl12_#{System.unique_integer([:positive])}"

    hsm = :"gl12_hsm_#{System.unique_integer([:positive])}"
    {:ok, _} = Smalt.Powl2.HsmSigner.start_link(name: hsm)
    on_exit(fn -> if pid = Process.whereis(hsm), do: GenServer.stop(pid) end)

    run_id = "gl12-run-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{run_id}.dets")
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)
    on_exit(fn ->
      ReceiptEngine.close(run_id)
      File.rm(path)
    end)

    # GL-2: compile the SHACL shape into the guard predicate; the seam fun
    # evaluates it against the ORDER (the law's context is the business
    # document, not the executor plumbing map).
    {:ok, compiled_guard} = LawCompiler.compile_shape("ex:HighValueOrderShape", @law_ttl)
    guard_fun = fn ctx -> compiled_guard.(ctx.order) end

    model = settlement_model(guard_fun, cf, @pk, doc)
    assert :ok = Reticle.admit(model)

    ctx = %{cf: cf, pk: @pk, doc: doc, order: order}

    exec_status = Executor.execute_admitted(instance_id, {:ok, model}, ctx, dets, self())

    {status, receipt, ctx_out} =
      receive do
        {:orchestration_completed, ^instance_id, ctx2, receipt} ->
          {:ok, receipt, ctx2}

        {:orchestration_failed, ^instance_id, outcome} ->
          {:error, outcome, %{}}
      after
        5_000 -> flunk("orchestration did not terminate")
      end

    %{
      exec_status: exec_status,
      result_status: status,
      receipt: receipt,
      ctx: ctx_out,
      cf: cf,
      dets: dets,
      doc: doc,
      instance_id: instance_id,
      doc_etag: Map.get(ctx_out, :doc_etag),
      commit_etag: Map.get(ctx_out, :commit_etag),
      run_id: run_id,
      hsm: hsm
    }
  end

  # intake -> persist -> validate(GL-1 seam, FOND :repair) -> commit -> settle -> done
  defp settlement_model(guard_fun, cf, pk, doc) do
    %AST.ChoiceGraph{
      children: %{
        # Entry delimiter: the executor's ChoiceGraph walk evaluates TARGETS
        # only — the start node is never stepped — so `:entry` is an
        # unevaluated tau delimiter, not a recorded transition.
        entry: %AST.Transition{id: :entry, label: :entry},
        intake: %AST.Transition{id: :intake, label: :intake, op: intake_op()},
        persist: %AST.Transition{id: :persist, label: :persist, op: persist_op(cf, pk, doc)},
        # GL-1 seam: the GL-2 compiled predicate guards the validate
        # transition; the FOND repair node rides the executor's seam fields
        # (`law_guard` / `repair`), overlaid on the AST struct.
        validate:
          %AST.Transition{id: :validate, label: :validate, op: validate_op()}
          |> Map.put(:law_guard, {"HighValueOrderShape", guard_fun})
          |> Map.put(:repair, repair_node()),
        commit: %AST.Transition{id: :commit, label: :commit, op: commit_op(cf, pk, doc)},
        settle: %AST.Transition{id: :settle, label: :settle, op: settle_op()},
        done: %AST.Transition{id: :done, label: :done, op: tau_op()}
      },
      start: :entry,
      end: :done,
      edges: [
        {:entry, :intake},
        {:intake, :persist},
        {:persist, :validate},
        {:validate, :commit},
        {:commit, :settle},
        {:settle, :done}
      ],
      guards: %{
        # commit is the :always fallback arm off validate; after the repair
        # re-arms with :compliant there is exactly one outgoing edge class.
        commit: :always
      }
    }
  end

  defp intake_op,
    do: fn ctx -> {:ok, Map.put(ctx, :intake, :ok), :intake_ok} end

  # CAS create (201) — the document exists before any law evaluation.
  defp persist_op(cf, pk, doc) do
    fn ctx ->
      case ChangeFeed.put_item(cf, pk, doc, ctx.order) do
        {:ok, 201, etag} -> {:ok, Map.put(ctx, :doc_etag, etag), :persisted}
        {:error, 412, current} -> {:error, {:cas_stale, current}}
        other -> {:error, {:unexpected_persist_result, other}}
      end
    end
  end

  # The real transition body: stamp compliance-check metadata. NEVER runs on
  # refusal (GL-1 fail-closed); the ANDON fires in the guard seam first.
  defp validate_op,
    do: fn ctx -> {:ok, Map.put(ctx, :validated, true), :compliant} end

  # FOND repair: merge the compliance signature into the order and re-arm
  # the walk with :compliant so the post-repair edge selection continues.
  defp repair_node do
    %AST.Transition{
      id: :repair,
      label: :repair,
      op: fn ctx ->
        order =
          ctx.order
          |> Map.put("complianceSignature", "sig-gl12-fond-repair")
          |> Map.put("approvedBy", "compliance-officer")

        {:ok, %{ctx | order: order}, :compliant}
      end
    }
  end

  # CAS update conditioned on intake's etag — the etag chain proves the
  # mutation happened AFTER the refusal+repair, on repaired content.
  defp commit_op(cf, pk, doc) do
    fn ctx ->
      case ChangeFeed.put_item(cf, pk, doc, ctx.order, if_match: ctx.doc_etag) do
        {:ok, 200, etag} -> {:ok, Map.put(ctx, :commit_etag, etag), :committed}
        {:error, 412, current} -> {:error, {:cas_stale, current}}
        other -> {:error, {:unexpected_commit_result, other}}
      end
    end
  end

  defp settle_op,
    do: fn ctx -> {:ok, Map.put(ctx, :settled_at, System.system_time(:millisecond)), :settled} end

  defp tau_op, do: fn ctx -> {:ok, ctx} end

  # ---------------------------------------------------------------------------
  # GL-12 seal: every step (lawful AND refused) into the ReceiptEngine ledger
  # ---------------------------------------------------------------------------

  defp seal(board, rule_id \\ nil, diag \\ nil, at_ms \\ nil) do
    hsm = board.hsm
    run_id = board.run_id

    Enum.with_index(board.receipt.steps, 1)
    |> Enum.each(fn {step, epoch} ->
      delta =
        case step.outcome do
          {:powl2_andon, _id, ^rule_id, ^diag} when is_integer(at_ms) ->
            andon_ledger_delta(board, rule_id, diag, at_ms)

          _ ->
            step
        end

      ReceiptEngine.record_step(board.run_id, %{
        epoch: epoch,
        act: "gl12.#{step.node}",
        delta: delta
      })
    end)

    signer = fn digest ->
      {:ok, sig} = Smalt.Powl2.HsmSigner.sign_digest(hsm, digest)
      sig
    end

    ReceiptEngine.seal_receipt(run_id, nil, signer)
  end

  # The GL-3 ANDON receipt shape that rides the ledger as the refusal's delta.
  defp andon_ledger_delta(board, rule_id, diag, at_ms) do
    Smalt.Powl2.Andon.format_andon(rule_id, diag, board.ctx.order,
      ts: at_ms * 1_000_000,
      session: to_string(board.instance_id)
    )
  end

  defp dets_lookup(dets, key) do
    case :dets.lookup(dets, key) do
      [{^key, value}] -> value
      [] -> flunk("no dets entry for #{inspect(key)}")
    end
  end

  defp node_path(steps), do: Enum.map(steps, & &1.node)

  defp hex_sha256(bin), do: Base.encode16(:crypto.hash(:sha256, bin), case: :lower)
end
