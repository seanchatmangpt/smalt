# W3C-C — the ACP (Solid Access Control Policy) ethics-wall matcher shapes
# proven through the existing sieve: graphlaw.wasm (purrdf::shapes 2.0.2) and
# the smalt LawCompiler over the SAME law files.
#
# Law files (single source of truth):
#   docs/jira/v26.10.22/law/shapes.ttl   (acp:PolicyShape, acp:AccessRequestShape)
#   docs/jira/v26.10.22/law/rules.n3     (C1 conflicted-class, C2 deny)
#
# Mapping (full table in the receipt):
#   acp:allow  -> sh:in (acp:Read acp:Write)         [InConstraintComponent, probed]
#   acp:allOf  -> sh:minCount 1 on acp:agent/client  [required presence]
#   acp:noneOf -> sh:not over the conflicted-class
#                 membership shape (ev:conflictedMatter) [NotConstraintComponent, probed]
#
# Legs:
#   A. graphlaw.wasm (real execution, packet-4 stdio):
#      - policy shape: policy without acp:allow refuses (minCount)
#      - conforming presenter P-1 (allowed matter M-100) → law op admits,
#        ev:Admissible derived (3 facts: BatesWellFormed, admittedBy, Admissible)
#      - conflicted-class presenter P-2 (carries ev:conflictedMatter even though
#        its matter IS credential-allowed) → sh:not violation at the shacl step,
#        typed NotAdmitted — 0 bytes past the sieve
#      - wrong-matter presenter P-3 (M-999, credential allows M-100) → sieve
#        conforms, n3 wall derives no Admissible → fail-closed quarantine
#      - standalone n3 op: C1/C2 derive acp:ConflictedAgent and acp:Deny for
#        P-2 only
#   B. smalt LawCompiler compiles the SAME shapes.ttl; guards admit P-1/P-3,
#      refuse P-2 with rule "…/not/…" naming the ACP noneOf reduction; a
#      bad-mode context refuses with rule "…/in/mode".
#   C. GLD-7-class 0-byte refusal gate: production commits only P-1 through a
#      real ChangeFeed CAS; the conflicted presenter is refused at review with
#      a typed {:law, rule, diag} ANDON and an explicit 0-byte refusal leaf in
#      a sealed ReceiptEngine run; the wrong-matter document never commits.
#
# Run:
#   MIX_BUILD_ROOT=_build-w3cc mix run --no-start test/integration/w3cc_acp_court.exs
# Exit 0 = PASS. No Process.sleep (bounded receive windows only).

defmodule W3cc.Wasm do
  @moduledoc "packet-4 stdio driver for graphlaw-run-eh (same discipline as ATH-3)."

  @graphlaw_root System.get_env("GRAPHLAW_ROOT", "../graphlaw")
  @runner Path.expand(@graphlaw_root <> "/target/release/graphlaw-run-eh")
  @wasm Path.expand(@graphlaw_root <> "/target/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm")

  def with_session(fun) do
    port =
      Port.open({:spawn_executable, @runner}, [
        :binary,
        :stream,
        :exit_status,
        :use_stdio
      ])

    try do
      fun.(%{port: port, buf: <<>>})
    after
      Port.close(port)
    end
  end

  def call(s, req) do
    body = Jason.encode!(req)
    :erlang.port_command(s.port, <<byte_size(body)::32-big, body::binary>>)
    recv_reply(s.port, s.buf, mono_ms() + 60_000)
  end

  defp recv_reply(port, buf, deadline) do
    case decode_frame(buf) do
      {:ok, reply, _rest} ->
        reply

      :need_more ->
        receive do
          {^port, {:data, bytes}} -> recv_reply(port, buf <> bytes, deadline)
          {^port, {:exit_status, code}} -> raise "W3C-C COURT FAIL: graphlaw-run-eh exited #{code}"
        after
          _ = max(deadline - mono_ms(), 0) -> raise "W3C-C COURT FAIL: graphlaw-run-eh frame timeout"
        end
    end
  end

  defp decode_frame(<<len::32-big, body::binary-size(len), _rest::binary>>),
    do: {:ok, Jason.decode!(body), <<>>}
  defp decode_frame(_), do: :need_more

  defp mono_ms, do: System.monotonic_time(:millisecond)
end

defmodule W3cc.Facts do
  @moduledoc """
  Presenter corpus: P-1 conforming on allowed matter, P-2 conflicted-class
  presenter (matter IS allowed — only the wall refuses), P-3 wrong matter.
  """

  @ns "https://smalt.local/ev#"
  @acp "http://www.w3.org/ns/solid/acp#"

  def ns, do: @ns

  def doc_ttl("P-1") do
    """
    @prefix ev: <#{@ns}> .
    @prefix acp: <#{@acp}> .
    <https://ev.local/doc/P-1> a ev:Document, acp:AccessRequest ;
      ev:batesId "ATH-100101" ; ev:bates "ATH-100101" ;
      ev:sha256Digest "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" ;
      ev:custodian "jane doe" ; ev:matterId "M-100" ;
      acp:agent <https://id.local/alice> ; acp:client <https://app.local/app1> ; acp:mode acp:Read .
    <https://ev.local/cred-1> a ev:Credential ; ev:allowedMatter "M-100" .
    """
  end

  def doc_ttl("P-2") do
    """
    @prefix ev: <#{@ns}> .
    @prefix acp: <#{@acp}> .
    <https://ev.local/doc/P-2> a ev:Document, acp:AccessRequest ;
      ev:batesId "ATH-100202" ; ev:bates "ATH-100202" ;
      ev:sha256Digest "60303ae22b998861bce3b28f33eec1be758a213c86c93c076dbe9f558c11c752" ;
      ev:custodian "john roe" ; ev:matterId "M-100" ;
      acp:agent <https://id.local/bob> ; acp:client <https://app.local/app1> ; acp:mode acp:Read ;
      ev:conflictedMatter <https://ev.local/matter/M-100> .
    <https://ev.local/cred-1> a ev:Credential ; ev:allowedMatter "M-100" .
    """
  end

  def doc_ttl("P-3") do
    """
    @prefix ev: <#{@ns}> .
    @prefix acp: <#{@acp}> .
    <https://ev.local/doc/P-3> a ev:Document, acp:AccessRequest ;
      ev:batesId "ATH-100303" ; ev:bates "ATH-100303" ;
      ev:sha256Digest "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae" ;
      ev:custodian "richard roe" ; ev:matterId "M-999" ;
      acp:agent <https://id.local/carol> ; acp:client <https://app.local/app1> ; acp:mode acp:Read .
    <https://ev.local/cred-1> a ev:Credential ; ev:allowedMatter "M-100" .
    """
  end

  def bates("P-1"), do: "ATH-100101"
  def bates("P-2"), do: "ATH-100202"
  def bates("P-3"), do: "ATH-100303"

  # smalt LawCompiler guard context (binary keys = sh:path local names).
  def guard_ctx("P-1"),
    do: %{
      "agent" => "alice",
      "client" => "app1",
      "mode" => "Read",
      "matterId" => "M-100",
      "batesId" => "ATH-100101",
      "sha256Digest" => "9f86d081884c7d659a2feaa0c55ad015",
      "custodian" => "jane doe"
    }

  def guard_ctx("P-2"),
    do: %{
      "agent" => "bob",
      "client" => "app1",
      "mode" => "Read",
      "matterId" => "M-100",
      "conflictedMatter" => "M-100",
      "batesId" => "ATH-100202",
      "sha256Digest" => "60303ae22b998861bce3b28f33eec1be",
      "custodian" => "john roe"
    }

  def guard_ctx("P-3"),
    do: %{
      "agent" => "carol",
      "client" => "app1",
      "mode" => "Read",
      "matterId" => "M-999",
      "batesId" => "ATH-100303",
      "sha256Digest" => "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
      "custodian" => "richard roe"
    }

  def policy_ctx, do: %{"allow" => "Read"}
  def policy_ctx_missing_allow, do: %{}
end

defmodule W3cc.Court do
  @moduledoc "W3C-C: ACP matcher shapes proven through the sieve (graphlaw + LawCompiler + 0-byte gate)."

  @law_dir Path.expand("docs/jira/v26.10.22/law", File.cwd!())
  @presenters ["P-1", "P-2", "P-3"]

  defp assert!(true, msg), do: IO.puts("  ok  " <> msg)
  defp assert!(false, msg), do: raise("W3C-C COURT FAIL: " <> msg)

  def run do
    IO.puts("W3C-C ACP LAW COURT")

    shapes_ttl = File.read!(Path.join(@law_dir, "shapes.ttl"))
    n3_rules = File.read!(Path.join(@law_dir, "rules.n3"))

    # ============ Leg A: graphlaw.wasm (real execution) ============
    IO.puts("  -- leg A: graphlaw.wasm sieve (packet-4)")
    leg_a = W3cc.Wasm.with_session(fn s -> leg_a(s, shapes_ttl, n3_rules) end)

    # ============ Leg B: smalt LawCompiler over the same file ============
    IO.puts("  -- leg B: smalt LawCompiler over the same shapes.ttl")
    leg_b(shapes_ttl)

    # ============ Leg C: GLD-7-class 0-byte refusal gate ============
    IO.puts("  -- leg C: ChangeFeed + sealed 0-byte ethics-wall refusal")
    leg_c(leg_a, shapes_ttl)

    IO.puts("W3C-C COURT: PASS")
    :ok
  end

  # ------------------------------------------------------------------
  defp leg_a(s, shapes_ttl, n3_rules) do
    cap = W3cc.Wasm.call(s, %{"op" => "capabilities"})
    assert!(cap["ok"] == true, "graphlaw.wasm capabilities op ok")

    doc_data = fn id -> %{"text" => W3cc.Facts.doc_ttl(id), "dialect" => "turtle"} end

    # -- policy shape: acp:allow required (acp:PolicyShape minCount) --
    policy_ttl = """
    @prefix acp: <http://www.w3.org/ns/solid/acp#> .
    <https://pol.local/pol-1> a acp:Policy ; acp:allow acp:Read, acp:Write .
    <https://pol.local/pol-2> a acp:Policy .
    """

    pol = W3cc.Wasm.call(s, %{"op" => "shacl", "data" => %{"text" => policy_ttl, "dialect" => "turtle"}, "shapes" => shapes_ttl})
    assert!(pol["ok"] == true, "policy graph validates through the sieve")

    pr = pol["result"]["results"]
    assert!(pol["result"]["conforms"] == false, "policy without acp:allow refuses (acp:PolicyShape minCount)")

    assert!(
      Enum.any?(pr, &(&1["focus"] =~ "pol-2")),
      "violation names the allow-less policy node (pol-2)"
    )

    # -- sieve per presenter: P-1 conforms; P-2 sh:not violation; P-3 conforms --
    p1 = W3cc.Wasm.call(s, %{"op" => "shacl", "data" => doc_data.("P-1"), "shapes" => shapes_ttl})
    assert!(p1["ok"] == true and p1["result"]["conforms"] == true, "P-1 (conforming, allowed matter) conforms")

    p2 = W3cc.Wasm.call(s, %{"op" => "shacl", "data" => doc_data.("P-2"), "shapes" => shapes_ttl})

    assert!(
      p2["ok"] == true and p2["result"]["conforms"] == false and
        Enum.any?(p2["result"]["results"], &(&1["component"] =~ "NotConstraintComponent")),
      "P-2 (conflicted-class presenter) refuses with NotConstraintComponent (sh:not)"
    )

    p3 = W3cc.Wasm.call(s, %{"op" => "shacl", "data" => doc_data.("P-3"), "shapes" => shapes_ttl})
    assert!(p3["ok"] == true and p3["result"]["conforms"] == true, "P-3 (wrong matter) conforms at the sieve — the wall is the n3 layer's job")

    # -- law op (admit:shacl -> derive:n3) --
    law_req = fn id ->
      %{
        "op" => "law",
        "data" => doc_data.(id),
        "steps" => [
          %{"step" => "shacl", "shapes" => shapes_ttl},
          %{"step" => "n3", "rules" => n3_rules}
        ]
      }
    end

    inwall = W3cc.Wasm.call(s, law_req.("P-1"))
    assert!(inwall["ok"] == true, "law op: conforming P-1 admitted through admit:shacl -> derive:n3")

    nq = inwall["result"]["nquads"]
    assert!(nq =~ "Admissible" and nq =~ "doc/P-1", "P-1: ev:Admissible derived over the allowed-matter intersection")

    receipts = inwall["result"]["receipts"]
    assert!(length(receipts) == 2, "law receipt chain: 2 steps (admit:shacl, derive:n3)")

    [r1, r2] = receipts
    assert!(r2["added"] == 3 and r2["parent"] == r1["child"], "derive:n3 added 3 facts; blake3 parent == shacl child")

    wall = W3cc.Wasm.call(s, law_req.("P-2"))
    code = wall["result"]["error"]["details"]["code"]
    assert!(code == "NotAdmitted", "P-2 conflicted-class presenter: typed NotAdmitted at the shacl step (0 bytes past the sieve)")

    wrong = W3cc.Wasm.call(s, law_req.("P-3"))
    assert!(wrong["ok"] == true, "law op: P-3 shapes-admitted (structurally clean)")

    wnq = wrong["result"]["nquads"]
    assert!(wnq =~ "BatesWellFormed" and not (wnq =~ "Admissible"), "P-3: bates witnessed, Admissible NEVER derived (wrong matter) => fail-closed quarantine")

    # -- standalone n3 op: C1/C2 derive the deny leaf for P-2 only --
    prog = n3_rules <> W3cc.Facts.doc_ttl("P-1") <> W3cc.Facts.doc_ttl("P-2") <> W3cc.Facts.doc_ttl("P-3")
    n3r = W3cc.Wasm.call(s, %{"op" => "n3", "text" => prog})
    assert!(n3r["ok"] == true, "n3 op fixed point reached over rules.n3 + presenter corpus")

    closure = n3r["result"]["derived"]
    lines = String.split(closure, "\n")

    assert!(Enum.any?(lines, &(&1 =~ "doc/P-2" and &1 =~ "ConflictedAgent")), "C1: P-2 derives acp:ConflictedAgent")
    assert!(Enum.any?(lines, &(&1 =~ "doc/P-2" and &1 =~ "Deny")), "C2: P-2 derives acp:Deny (typed deny leaf)")
    assert!(not Enum.any?(lines, &(&1 =~ "doc/P-1" and (&1 =~ "Deny" or &1 =~ "ConflictedAgent"))), "P-1 derives no deny")
    assert!(not Enum.any?(lines, &(&1 =~ "doc/P-3" and (&1 =~ "Deny" or &1 =~ "ConflictedAgent"))), "P-3 derives no deny")

    %{"P-1" => :admit, "P-2" => :wall_refused, "P-3" => :quarantine}
  end

  # ------------------------------------------------------------------
  defp leg_b(shapes_ttl) do
    alias Smalt.POWL2.LawCompiler

    {:ok, req_guard} = LawCompiler.compile_shape("acp:AccessRequestShape", shapes_ttl)
    assert!(is_function(req_guard, 1), "LawCompiler compiled acp:AccessRequestShape from the law file")

    assert!(req_guard.(W3cc.Facts.guard_ctx("P-1")) == :ok, "P-1 context passes the compiled ACP guard")

    assert!(req_guard.(W3cc.Facts.guard_ctx("P-3")) == :ok, "P-3 context passes (the matter wall is the n3 layer's job)")

    {:violation, rule_not, diag_not} = req_guard.(W3cc.Facts.guard_ctx("P-2"))
    assert!(String.starts_with?(rule_not, "AccessRequestShape/not"), "P-2 refuses with rule #{rule_not}")
    assert!(diag_not =~ "noneOf", "P-2 refusal names the acp:noneOf breach: #{diag_not}")

    {:violation, rule_in, _diag} = req_guard.(%{"mode" => "Delete", "agent" => "a", "client" => "c"})
    assert!(String.starts_with?(rule_in, "AccessRequestShape/in"), "bad mode refuses with rule #{rule_in}")

    {:ok, pol_guard} = LawCompiler.compile_shape("acp:PolicyShape", shapes_ttl)
    assert!(pol_guard.(W3cc.Facts.policy_ctx()) == :ok, "PolicyShape guard admits a policy context")

    {:violation, rule_pol, _diag} = pol_guard.(W3cc.Facts.policy_ctx_missing_allow())
    assert!(String.starts_with?(rule_pol, "PolicyShape/minCount"), "allow-less policy refuses with rule #{rule_pol}")
  end

  # ------------------------------------------------------------------
  defp leg_c(verdicts, shapes_ttl) do
    alias Smalt.POWL2.ChangeFeed
    alias Smalt.POWL2.LawCompiler
    alias Smalt.Powl2.HsmSigner
    alias Smalt.PPlan.ReceiptEngine

    {:ok, req_guard} = LawCompiler.compile_shape("acp:AccessRequestShape", shapes_ttl)

    cf = :"w3cc_change_feed_#{System.unique_integer([:positive])}"
    {:ok, _} = ChangeFeed.start_link(base: cf)

    {:ok, hsm} = HsmSigner.start_link(name: :"w3cc_hsm_#{System.unique_integer([:positive])}")
    run_id = "w3cc-run-#{System.unique_integer([:positive])}"
    seal_path = Path.join(System.tmp_dir!(), "#{run_id}.dets")
    {:ok, ^run_id} = ReceiptEngine.open(run_id, seal_path)

    signer = fn digest ->
      {:ok, sig} = HsmSigner.sign_digest(hsm, digest)
      sig
    end

    ingest_events =
      Enum.map(@presenters, fn doc -> %{"doc" => doc, "bates" => W3cc.Facts.bates(doc), "act" => "w3cc.ingest"} end)

    Enum.each(Enum.with_index(ingest_events, 1), fn {ev, epoch} ->
      ReceiptEngine.record_step(run_id, %{epoch: epoch, act: "w3cc.ingest", delta: ev})
    end)

    # execute per presenter: guard + law verdict -> commit | typed refusal
    results =
      Enum.map(@presenters, fn doc ->
        guard = req_guard.(W3cc.Facts.guard_ctx(doc))
        verdict = Map.fetch!(verdicts, doc)

        case {guard, verdict} do
          {:ok, :admit} ->
            {:ok, status, etag} = ChangeFeed.put_item(cf, "w3cc-docs", "doc-#{doc}", %{"doc" => doc, "bates" => W3cc.Facts.bates(doc)})
            ReceiptEngine.record_step(run_id, %{epoch: 10_000, act: "w3cc.step.production", delta: %{"doc" => doc, "etag" => etag, "status" => status}})
            {doc, {:committed, etag}}

          {:ok, :quarantine} ->
            # sieve-clean but no Admissible derivation: fail-closed, nothing committed
            ReceiptEngine.record_step(run_id, %{epoch: 10_001, act: "w3cc.refusal.quarantine", delta: %{"doc" => doc, "bytes_committed" => 0}})
            {doc, :quarantined}

          {:ok, :wall_refused} ->
            raise "W3C-C COURT FAIL: #{doc} sieve-clean but law-refused (sieve must refuse)"

          {{:violation, rule_id, diagnostic}, :wall_refused} ->
            # GLD-7-class ethics-wall ANDON: typed refusal, 0 bytes committed
            ReceiptEngine.record_step(run_id, %{
              epoch: 10_002,
              act: "w3cc.refusal.ethics-wall",
              delta: %{"doc" => doc, "rule" => rule_id, "diagnostic" => diagnostic, "bytes_committed" => 0}
            })

            {doc, {:wall_refused, rule_id}}

          {other, verdict} ->
            raise "W3C-C COURT FAIL: #{doc} guard/verdict mismatch: #{inspect(other)} vs #{inspect(verdict)}"
        end
      end)

    by_doc = Map.new(results, fn {d, r} -> {d, r} end)

    {:committed, etag1} = by_doc["P-1"]
    assert!(is_binary(etag1), "P-1 committed through real ChangeFeed CAS")

    {:wall_refused, rule2} = by_doc["P-2"]
    assert!(String.starts_with?(rule2, "AccessRequestShape/not"), "P-2: typed ANDON names #{rule2}")

    assert!(by_doc["P-3"] == :quarantined, "P-3: fail-closed quarantine, 0 bytes")

    assert!(
      is_binary(ChangeFeed.etag(cf, "w3cc-docs", "doc-P-1")) and
        ChangeFeed.etag(cf, "w3cc-docs", "doc-P-2") == nil and
        ChangeFeed.etag(cf, "w3cc-docs", "doc-P-3") == nil,
      "ChangeFeed holds exactly the 1 admitted presenter (0-byte refusals for wall + quarantine)"
    )

    sealed = ReceiptEngine.seal_receipt(run_id, nil, signer)

    assert!(sealed.step_count == 6, "sealed receipt holds 6 leaves (3 ingest + 1 production + 2 refusal leaves), got #{sealed.step_count}")

    acts = ReceiptEngine.steps(run_id) |> Enum.map(& &1.act_iri)

    assert!(Enum.count(acts, &String.contains?(&1, "refusal.ethics-wall")) == 1, "sealed receipt carries exactly 1 ethics-wall refusal leaf")

    assert!(Enum.count(acts, &String.contains?(&1, "refusal.quarantine")) == 1, "sealed receipt carries exactly 1 quarantine refusal leaf")

    assert!(byte_size(sealed.merkle_root) == 32 and sealed.signature != nil, "sealed Merkle root is 32 bytes and HSM-signed")

    all_hashes = ReceiptEngine.steps(run_id) |> Enum.map(& &1.hash)

    assert!(
      ReceiptEngine.merkle_root(all_hashes) != ReceiptEngine.merkle_root(List.delete_at(all_hashes, 0)),
      "non-vacuity: dropping a leaf changes the Merkle root"
    )

    ReceiptEngine.close(run_id)
    File.rm(seal_path)

    IO.puts("presenters: 3 | admitted: P-1 | wall-refused: P-2 (0-byte ANDON) | quarantined: P-3 (0-byte)")
    IO.puts("sealed leaves: #{sealed.step_count}  merkle_root: #{Base.encode16(sealed.merkle_root, case: :lower)}")
    :ok
  end
end

case W3cc.Court.run() do
  :ok -> System.stop(0)
  other ->
    IO.puts("W3C-C COURT: FAIL #{inspect(other)}")
    System.stop(1)
end
