defmodule Smalt.GraphLawPowlBusinessNetTest do
  @moduledoc """
  GL-4 integration court: the operator's canonical order/compliance/GDPR
  settlement, end to end over the landed stack.

  SHACL shapes (HighValueOrderShape: totalAmount > 10000 requires
  complianceSignature; EU tenant requires gdprConsent; self-approval
  exclusion) are enforced by guard funs written DIRECTLY in this court —
  the GL-2 law compiler (bounded-poll shape compilation) does not exist in
  the tree yet (grep over lib/ test/ scripts/ docs/jira/v26.10.21: zero
  referents as of 2026-10-21). When GL-2 lands, these funs become its
  compiled output and this note retires.

  The POWL ChoiceGraph (validate -> [commit | compliance_review] -> settle)
  rides the GL-1 seam: `Smalt.POWL2.Executor` selects ChoiceGraph edges by
  exact `ctx.last_outcome` guard match with `:always`/unguarded fallback
  (`guards` map on the ChoiceGraph, never guarded edge tuples). The FOND
  repair edge is a real graph edge ({enter, repair} guarded
  :andon_refused): after an ANDON refusal the court re-enters the SAME
  model with `last_outcome: :andon_refused` seeded in the context, the
  repair transition merges the compliance signature into the order, and
  the retry walks enter -> repair -> validate -> commit -> settle. Note the
  executor treats start/end as pure delimiters (a node's step is recorded
  when it is ENTERED as an edge target; start and end are never entered),
  so they carry tau ops that are structural, never executed.
  The repair is the repair edge, not a court-side reimplementation.

  Execution is via `Smalt.POWL2.Executor.execute_admitted/6` with
  `Smalt.POWL2.ChangeFeed` CAS (If-Match; a stale precondition returns 412
  and the document is untouched) and a `Smalt.PPlan.ReceiptEngine` seal
  (phi_lease_final == step count, 32-byte merkle root, HSM-signed).

  ANDON law: a refused order never reaches the commit transition, so the
  ChangeFeed ETS holds no document for it, and the persisted refusal names
  the exact violated rule.
  """

  use ExUnit.Case, async: false

  alias Smalt.POWL2.ChangeFeed
  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.Reticle
  alias Smalt.POWL2.Reticle.AST
  alias Smalt.Powl2.HsmSigner
  alias Smalt.PPlan.ReceiptEngine

  @pk "gl4-orders"

  # ---------------------------------------------------------------------------
  # Courts
  # ---------------------------------------------------------------------------

  @tag :gl4_court
  test "court 1: $5k order without signature commits (no guard fires)" do
    board = run_order(%{"totalAmount" => 5_000, "region" => "US"})

    assert :ok = board.exec_status
    assert [:validate, :commit, :settle, :exit] = node_path(board.receipt)
    assert [:compliant, :committed, :settled, :tau] = outcomes(board.receipt)

    # The commit really CAS-created the document in the ChangeFeed.
    assert {:ok, 201, etag} = board.commit_cas
    assert etag == ChangeFeed.etag(board.cf, @pk, board.doc)

    sealed = seal(board)
    assert sealed.step_count == length(board.receipt.steps)
    assert sealed.phi_lease_final == sealed.step_count
    assert byte_size(sealed.merkle_root) == 32
  end

  @tag :gl4_court
  test "court 2: $50k order without signature -> ANDON, ETS unchanged, refusal names the rule" do
    board = run_order(%{"totalAmount" => 50_000, "region" => "US"})

    assert {:error,
            {:transition_failed, :validate,
             {:andon, :high_value_requires_compliance_signature}}} = board.exec_status

    # The persisted refusal receipt names the rule.
    assert {:error,
            {:transition_failed, :validate,
             {:andon, :high_value_requires_compliance_signature}}} = board.receipt.status

    # The commit transition never fired, so the ChangeFeed ETS is unchanged.
    assert board.commit_never_fired
    assert nil == ChangeFeed.etag(board.cf, @pk, board.doc)

    # The refusal is persisted under the executor's refusal key.
    assert %{rule: :high_value_requires_compliance_signature} =
             dets_lookup(board, {:gl4_andon, board.instance_id})

    sealed = seal(board)
    assert sealed.step_count == length(board.receipt.steps)
  end

  @tag :gl4_court
  test "court 3: $50k order WITH compliance signature commits" do
    board =
      run_order(%{
        "totalAmount" => 50_000,
        "region" => "US",
        "complianceSignature" => "sig-ops-7"
      })

    assert :ok = board.exec_status
    assert [:validate, :commit, :settle, :exit] = node_path(board.receipt)
    assert {:ok, 201, _etag} = board.commit_cas
    assert :compliant in outcomes(board.receipt)
  end

  @tag :gl4_court
  test "court 4: EU tenant without consent -> ANDON at compliance_review" do
    board =
      run_order(%{
        "totalAmount" => 20_000,
        "region" => "EU",
        "complianceSignature" => "sig-ops-8"
      })

    # Signature present -> validate routes to compliance_review; the review
    # finds the EU tenant without gdprConsent and stops the line.
    assert {:error,
            {:transition_failed, :review,
             {:andon, :eu_requires_gdpr_consent}}} = board.exec_status
    assert board.commit_never_fired
    assert nil == ChangeFeed.etag(board.cf, @pk, board.doc)
    assert :review_required in outcomes(board.receipt)

    assert %{rule: :eu_requires_gdpr_consent} =
             dets_lookup(board, {:gl4_andon, board.instance_id})
  end

  @tag :gl4_court
  test "court 5: FOND repair — signature added to context, retry via the repair edge commits" do
    # First dispatch: $50k, no signature -> ANDON (same law as court 2).
    board = run_order(%{"totalAmount" => 50_000, "region" => "US"})

    assert {:error,
            {:transition_failed, :validate,
             {:andon, :high_value_requires_compliance_signature}}} = board.exec_status

    assert nil == ChangeFeed.etag(board.cf, @pk, board.doc)

    # FOND repair: fix the INPUT (add the signature), re-enter the SAME
    # model with last_outcome: :andon_refused — the guard-selected edge
    # intake -> repair fires, repair merges the signature into the order,
    # and the walk proceeds validate -> commit -> settle -> done.
    ctx2 =
      board.ctx
      |> Map.put(:last_outcome, :andon_refused)
      |> Map.put(:order, Map.put(board.ctx.order, "complianceSignature", "sig-repair-9"))

    :ok = Executor.execute_admitted(board.instance_id, {:ok, board.model}, ctx2, board.dets, self())
    iid = board.instance_id

    receipt =
      receive do
        {:orchestration_completed, ^iid, _ctx3, receipt} -> receipt
      after
        5_000 -> flunk("repaired orchestration did not complete")
      end

    assert [:repair, :validate, :commit, :settle, :exit] = node_path(receipt)
    assert :repaired in outcomes(receipt)

    etag = ChangeFeed.etag(board.cf, @pk, board.doc)
    assert is_binary(etag)

    # The run-1 refusal stays on the ledger as history; the repaired run
    # sealed its own completion receipt.
    assert %{rule: :high_value_requires_compliance_signature} =
             dets_lookup(board, {:gl4_andon, board.instance_id})
  end

  # ---------------------------------------------------------------------------
  # Orchestration under court
  # ---------------------------------------------------------------------------

  defp run_order(order) do
    cf = :"gl4_change_feed_#{System.unique_integer([:positive])}"
    {:ok, _} = ChangeFeed.start_link(base: cf)

    dets = :"gl4_dets_#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{dets}.dets")
    {:ok, ^dets} = :dets.open_file(dets, file: String.to_charlist(path), repair: true)
    on_exit(fn -> File.rm(path) end)

    doc = "order-#{System.unique_integer([:positive])}"
    instance_id = :"gl4_#{System.unique_integer([:positive])}"

    model = business_model(cf, @pk, doc)
    assert :ok = Reticle.admit(model)

    ctx = %{cf: cf, pk: @pk, doc: doc, order: order}

    exec_status = Executor.execute_admitted(instance_id, {:ok, model}, ctx, dets, self())

    {result, receipt, ctx_out} =
      receive do
        {:orchestration_completed, ^instance_id, ctx2, receipt} ->
          {:ok, receipt, ctx2}

        {:orchestration_failed, ^instance_id, outcome} ->
          [{_k, r}] = :dets.lookup(dets, {:powl2_receipt, instance_id})
          # ANDON board entry (court-owned ledger): the line stopped on rule.
          :dets.insert(dets, {{:gl4_andon, instance_id},
                              %{rule: elem(elem(outcome, 2), 1), at_ms: System.system_time(:millisecond)}})
          {:error, r, ctx}
      after
        5_000 -> flunk("orchestration did not terminate")
      end

    steps = receipt.steps
    commit_never_fired = not Enum.any?(steps, &(&1.node == :commit))

    %{
      exec_status: exec_status,
      result: result,
      receipt: receipt,
      ctx: ctx_out,
      cf: cf,
      dets: dets,
      doc: doc,
      instance_id: instance_id,
      model: model,
      commit_never_fired: commit_never_fired,
      commit_cas: Map.get(ctx_out, :commit_cas)
    }
  end

  defp dets_lookup(board, key) do
    case :dets.lookup(board.dets, key) do
      [{^key, value}] -> value
      [] -> flunk("no dets entry for #{inspect(key)}")
    end
  end

  defp node_path(receipt), do: Enum.map(receipt.steps, & &1.node)
  defp outcomes(receipt), do: Enum.map(receipt.steps, & &1.outcome)

  # Receipt seal: one provenance step per executor step, HSM-signed.
  defp seal(board) do
    hsm = :"gl4_hsm_#{System.unique_integer([:positive])}"
    {:ok, _} = HsmSigner.start_link(name: hsm)
    on_exit(fn -> if pid = Process.whereis(hsm), do: GenServer.stop(pid) end)

    run_id = "gl4-run-#{System.unique_integer([:positive])}"
    path = Path.join(System.tmp_dir!(), "#{run_id}.dets")
    {:ok, ^run_id} = ReceiptEngine.open(run_id, path)

    Enum.with_index(board.receipt.steps, 1)
    |> Enum.each(fn {step, epoch} ->
      ReceiptEngine.record_step(run_id, %{epoch: epoch, act: "gl4.#{step.node}", delta: step})
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

  # ---------------------------------------------------------------------------
  # Guard funs (direct-written; GL-2 law compiler absent — see moduledoc)
  # ---------------------------------------------------------------------------

  # HighValueOrderShape: totalAmount > 10000 requires complianceSignature.
  defp high_value_without_signature?(%{"totalAmount" => amount, "complianceSignature" => sig})
       when is_integer(amount) and amount > 10_000,
       do: sig in [nil, ""]

  defp high_value_without_signature?(%{"totalAmount" => amount})
       when is_integer(amount) and amount > 10_000,
       do: true

  defp high_value_without_signature?(_), do: false

  # EU tenant requires gdprConsent.
  defp eu_without_consent?(%{"region" => "EU", "gdprConsent" => consent}),
    do: consent in [nil, ""]

  defp eu_without_consent?(%{"region" => "EU"}), do: true
  defp eu_without_consent?(_), do: false

  # Self-approval exclusion: the approver may never be the requester.
  defp self_approval?(%{"requester" => r, "approver" => a}) when r == a, do: true
  defp self_approval?(_), do: false

  # ---------------------------------------------------------------------------
  # The business net (reticle AST; GL-1 seam = executor ChoiceGraph guards)
  # ---------------------------------------------------------------------------

  # enter -> validate -> [commit | compliance_review] -> settle, plus the
  # FOND repair edge {enter, repair} guarded :andon_refused.
  #
  # Edge-guard law (GL-1 seam): the executor matches a target guard exactly
  # against ctx.last_outcome first, then falls back to :always/unguarded.
  # settle is entered from BOTH commit (:committed) and review (:approved),
  # so settle and done ride UNGUARDED fallback edges — a guard on them
  # could only satisfy one arm.
  defp business_model(cf, pk, doc) do
    %AST.ChoiceGraph{
      children: %{
        enter: %AST.Transition{id: :enter, label: :enter, op: tau_op()},
        exit: %AST.Transition{id: :exit, label: :exit, op: tau_op()},
        validate: %AST.Transition{id: :validate, label: :validate, op: validate_op()},
        repair: %AST.Transition{id: :repair, label: :repair, op: repair_op()},
        commit: %AST.Transition{id: :commit, label: :commit, op: commit_op(cf, pk, doc)},
        review: %AST.Transition{id: :review, label: :review, op: review_op()},
        settle: %AST.Transition{id: :settle, label: :settle, op: settle_op()}
      },
      start: :enter,
      end: :exit,
      edges: [
        {:enter, :validate},
        {:enter, :repair},
        {:validate, :commit},
        {:validate, :review},
        {:review, :settle},
        {:commit, :settle},
        {:repair, :validate},
        {:settle, :exit}
      ],
      guards: %{
        # {intake, validate}: :always fallback arm.
        validate: :always,
        # {intake, repair}: exact-match FOND repair edge, fires only when
        # the context re-enters carrying last_outcome: :andon_refused.
        repair: :andon_refused,
        # {validate, commit} vs {validate, review}: the GL-1 choice seam.
        commit: :compliant,
        review: :review_required
      }
    }
  end

  # NOTE: start/end are pure SESE delimiters in the executor's walk — the
  # seeded :andon_refused last_outcome lives untouched in the ctx when the
  # first pick() runs at start, which is exactly what routes enter -> repair.
  defp validate_op do
    fn ctx ->
      order = Map.fetch!(ctx, :order)

      cond do
        self_approval?(order) ->
          {:error, {:andon, :self_approval_excluded}}

        high_value_without_signature?(order) ->
          {:error, {:andon, :high_value_requires_compliance_signature}}

        true ->
          outcome =
            if eu_without_consent?(order) do
              :review_required
            else
              :compliant
            end

          {:ok, Map.put(ctx, :validated, true), outcome}
      end
    end
  end

  defp repair_op do
    fn ctx ->
      # FOND repair transition: the caller repaired the context (added the
      # signature); record the repair on the ledger and route to validate.
      {:ok, Map.put(ctx, :repaired, true), :repaired}
    end
  end

  defp review_op do
    fn ctx ->
      order = Map.fetch!(ctx, :order)

      cond do
        self_approval?(order) ->
          {:error, {:andon, :self_approval_excluded}}

        eu_without_consent?(order) ->
          {:error, {:andon, :eu_requires_gdpr_consent}}

        true ->
          {:ok, Map.put(ctx, :reviewed_by, "compliance"), :approved}
      end
    end
  end

  defp commit_op(cf, pk, doc) do
    fn ctx ->
      case ChangeFeed.put_item(cf, pk, doc, ctx.order) do
        {:ok, status, etag} ->
          {:ok, Map.put(ctx, :commit_cas, {:ok, status, etag}), :committed}

        {:error, 412, current} ->
          {:error, {:cas_stale, current}}

        {:error, 404, nil} ->
          {:error, :cas_missing}

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
