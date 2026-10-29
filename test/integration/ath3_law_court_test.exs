# ATH-3 — the evidence law law files -> graphlaw.wasm + smalt LawCompiler + GLD-7-class end-to-end court.
#
# Law files (the ONLY domain-aware artifacts):
#   docs/jira/v26.10.22/law/shapes.ttl
#   docs/jira/v26.10.22/law/rules.n3
#   docs/jira/v26.10.22/law/workflow.powl.ttl
#
# Legs:
#   A. graphlaw.wasm (real execution via graphlaw-run-eh, packet-4 stdio):
#      op `shacl` validates shapes.ttl (conforming batch conforms; the
#      shape-incomplete document refuses with its sh:message named);
#      op `law` (admit:shacl -> derive:n3 over rules.n3) admits the in-wall
#      document (Admissible derived; derive:n3 added 3 facts; blake3
#      parent==shacl-child chain) and fail-closes the ethical-wall breach
#      (BatesWellFormed derived, Admissible NEVER derived). op `n3` reaches
#      the same partition standalone.
#   B. smalt GL-2 Smalt.POWL2.LawCompiler compiles shapes.ttl into guard
#      predicates; guards + GL-7-class guard-pointer swap on a live ETS table.
#   C. workflow.powl.ttl parses into the Reticle AST (integer node ids), passes
#      Reticle.admit (SESE non-vacuity: a trapped child is refused), then the
#      POWL2 executor runs the net per document with ops bound to domain-blind
#      substrate actions. Verdicts are LAW-DERIVED: the production/quarantine
#      partition comes from leg A's engine outputs (Admissible derived or
#      not), never fixture-asserted. Production commits via real ChangeFeed
#      CAS; the wall breach routes the quarantine branch (0-byte refusal:
#      ChangeFeed untouched); the shape violation ANDONs at review(2) naming
#      the compiled rule. ONE ReceiptEngine run seals ingest + every executor
#      step + one explicit 0-byte refusal leaf; partition asserted exact.
#
# Run:
#   MIX_BUILD_ROOT=_build-ath3 mix test test/integration/ath3_law_court_test.exs
# Exit 0 = PASS. No Process.sleep (bounded receive windows only).

defmodule Ath3.Wasm do
  @moduledoc "packet-4 stdio driver for graphlaw-run-eh (GWS-18 runner)."

  # GRAPHLAW_ROOT env override; default assumes the sibling canonical checkout.
  @graphlaw_root System.get_env("GRAPHLAW_ROOT", "../graphlaw")
  @runner Path.expand(@graphlaw_root <> "/target/release/graphlaw-run-eh")
  @wasm Path.expand(@graphlaw_root <> "/target/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm")

  def runner, do: @runner
  def wasm_path, do: @wasm

  def with_session(fun) do
    port =
      Port.open({:spawn_executable, @runner}, [:binary, :stream, :exit_status, :use_stdio, :hide])

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
          {^port, {:exit_status, code}} -> raise "ATH-3 COURT FAIL: graphlaw-run-eh exited #{code}"
        after
          _ = max(deadline - mono_ms(), 0) -> raise "ATH-3 COURT FAIL: graphlaw-run-eh frame timeout"
        end
    end
  end

  defp decode_frame(<<len::32-big, body::binary-size(len), _rest::binary>>),
    do: {:ok, Jason.decode!(body), <<>>}

  defp decode_frame(_), do: :need_more

  defp mono_ms, do: System.monotonic_time(:millisecond)
end

defmodule Ath3.Facts do
  @moduledoc "Fixed document corpus: D-1 in-wall, D-2 wall breach, D-3 shape-incomplete."

  @ns "https://smalt.local/ev#"

  def ns, do: @ns

  def doc_ttl("D-1") do
    """
    @prefix ev: <#{@ns}> .
    <https://ev.local/doc/D-1> a ev:Document ;
      ev:batesId "ATH-000101" ; ev:bates "ATH-000101" ;
      ev:sha256Digest "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08" ;
      ev:custodian "jane doe" ; ev:matterId "M-100" .
    ev:cred-1 a ev:Credential ; ev:allowedMatter "M-100" .
    """
  end

  def doc_ttl("D-2") do
    """
    @prefix ev: <#{@ns}> .
    <https://ev.local/doc/D-2> a ev:Document ;
      ev:batesId "ATH-000202" ; ev:bates "ATH-000202" ;
      ev:sha256Digest "60303ae22b998861bce3b28f33eec1be758a213c86c93c076dbe9f558c11c752" ;
      ev:custodian "jane doe" ; ev:matterId "M-999" .
    ev:cred-1 a ev:Credential ; ev:allowedMatter "M-100" .
    """
  end

  def doc_ttl("D-3") do
    """
    @prefix ev: <#{@ns}> .
    <https://ev.local/doc/D-3> a ev:Document ; ev:batesId "ATH-000303" .
    """
  end

  def bates("D-1"), do: "ATH-000101"
  def bates("D-2"), do: "ATH-000202"
  def bates("D-3"), do: "ATH-000303"

  # smalt LawCompiler guard context (binary keys = sh:path local names).
  def guard_ctx("D-1"),
    do: %{
      "batesId" => "ATH-000101",
      "sha256Digest" => "9f86d081884c7d659a2feaa0c55ad015",
      "custodian" => "jane doe",
      "matterId" => "M-100"
    }

  def guard_ctx("D-2"),
    do: %{
      "batesId" => "ATH-000202",
      "sha256Digest" => "60303ae22b998861bce3b28f33eec1be",
      "custodian" => "jane doe",
      "matterId" => "M-999"
    }

  def guard_ctx("D-3"), do: %{"batesId" => "ATH-000303"}
end

defmodule Ath3.PowlTtl do
  @moduledoc """
  Real text parser: workflow.powl.ttl bytes -> Smalt.POWL2.Reticle.AST model
  with integer node ids. The TTL file is the net's source of truth; this
  parser reads only the vocabulary that file declares.
  """

  alias Smalt.POWL2.Reticle.AST

  def parse!(ttl) do
    start = int!(~r/powl:start\s+"(\d+)"/, ttl)
    end_ = int!(~r/powl:end\s+"(\d+)"/, ttl)

    children_ids =
      ttl
      |> block("powl:children")
      |> scan_ints()
      |> Enum.map(&String.to_integer/1)
      |> Kernel.++(tau_ids(ttl))
      |> Enum.uniq()

    labels =
      ttl
      |> scan_pairs("powl:label")
      |> Map.new(fn {n, v} -> {String.to_integer(n), String.to_atom(v)} end)

    ops =
      ttl
      |> scan_pairs("powl:opName")
      |> Map.new(fn {n, v} -> {String.to_integer(n), String.to_atom(v)} end)

    {edges, guards} =
      ttl
      |> scan_edges()
      |> Enum.reduce({[], %{}}, fn {f, t, g}, {es, gs} ->
        {[{f, t} | es], if(g, do: Map.put(gs, t, String.to_atom(g)), else: gs)}
      end)

    %AST.ChoiceGraph{
      start: start,
      end: end_,
      children:
        Map.new(children_ids, fn id ->
          {id,
           %AST.Transition{
             id: id,
             label: Map.get(labels, id, :tau),
             op: op_placeholder(Map.get(ops, id, :tau))
           }}
        end),
      edges: Enum.reverse(edges),
      guards: guards
    }
  end

  def tau_ids(ttl), do: ttl |> block("powl:tau") |> scan_ints() |> Enum.map(&String.to_integer/1)

  # The parsed op is the op NAME; the court binds it to a real substrate
  # function via Ath3.Court.bind_ops/4 before execution.
  defp op_placeholder(name), do: {:powl_op_name, name}

  defp int!(re, ttl) do
    case Regex.run(re, ttl) do
      [_, n] -> String.to_integer(n)
      _ -> raise "ATH-3 COURT FAIL: workflow.powl.ttl missing #{inspect(re.source)}"
    end
  end

  defp block(ttl, key) do
    case :binary.split(ttl, key) do
      [_, rest] -> hd(:binary.split(rest, ";"))
      _ -> raise "ATH-3 COURT FAIL: workflow.powl.ttl missing #{key}"
    end
  end

  defp scan_ints(text), do: Regex.scan(~r/"(\d+)"/, text) |> Enum.map(&hd(tl(&1)))

  # [ powl:node "N"^^xsd:integer ; powl:label|opName "v" ] blocks.
  defp scan_pairs(ttl, val_key) do
    ~r/\[\s*powl:node\s+"(\d+)"[^\]]*?#{val_key}\s+"(\w+)"\s*\]/s
    |> Regex.scan(ttl)
    |> Enum.map(fn [_, n, v] -> {n, v} end)
  end

  # [ powl:from "F" ; powl:to "T" ; (powl:guard "g")? ] blocks.
  defp scan_edges(ttl) do
    ~r/\[\s*powl:from\s+"(\d+)"[^\]]*?powl:to\s+"(\d+)"(?:[^\]]*?powl:guard\s+"(\w+)")?[^\]]*\]/s
    |> Regex.scan(ttl)
    |> Enum.map(fn
      [_, f, t] -> {String.to_integer(f), String.to_integer(t), nil}
      [_, f, t, g] -> {String.to_integer(f), String.to_integer(t), g}
    end)
  end
end

defmodule Ath3.Court do
  @moduledoc "ATH-3: law files proven through the graphlaw + smalt law chain."

  @law_dir Path.expand("docs/jira/v26.10.22/law", File.cwd!())

  alias Smalt.POWL2.ChangeFeed
  alias Smalt.POWL2.Executor
  alias Smalt.POWL2.LawCompiler
  alias Smalt.POWL2.Reticle
  alias Smalt.Powl2.HsmSigner
  alias Smalt.PPlan.ReceiptEngine

  @pk "ath3-docs"
  @docs ["D-1", "D-2", "D-3"]

  defp assert!(true, msg), do: IO.puts("  ok  " <> msg)
  defp assert!(false, msg), do: raise("ATH-3 COURT FAIL: " <> msg)

  def run do
    IO.puts("ATH-3 LAW COURT")

    shapes_ttl = File.read!(Path.join(@law_dir, "shapes.ttl"))
    n3_rules = File.read!(Path.join(@law_dir, "rules.n3"))
    powl_ttl = File.read!(Path.join(@law_dir, "workflow.powl.ttl"))

    # ============ Leg A: graphlaw.wasm (real execution) ============
    IO.puts("  -- leg A: graphlaw.wasm via graphlaw-run-eh (packet-4)")

    wasm_sha =
      Ath3.Wasm.wasm_path() |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

    assert!(byte_size(wasm_sha) == 64,
      "graphlaw.wasm artifact identity: sha256 #{String.slice(wasm_sha, 0, 12)}..."
    )

    leg_a = Ath3.Wasm.with_session(fn s -> leg_a(s, shapes_ttl, n3_rules) end)

    # ============ Leg B: smalt GL-2 LawCompiler over the same file ============
    IO.puts("  -- leg B: smalt LawCompiler compiles shapes.ttl")
    leg_b(shapes_ttl)

    # ============ Leg C: workflow.powl.ttl -> Reticle -> executor ============
    IO.puts("  -- leg C: POWL net (intake -> review -> production | quarantine)")
    leg_c(powl_ttl, shapes_ttl, leg_a)

    IO.puts("ATH-3 COURT: PASS")
    :ok
  end

  # ------------------------------------------------------------------
  # Leg A — graphlaw.wasm ops over the law files.
  # Returns the LAW-DERIVED wall verdicts that leg C executes under:
  #   %{doc => :compliant | :wall_breach | :andon}
  # ------------------------------------------------------------------
  defp leg_a(s, shapes_ttl, n3_rules) do
    cap = Ath3.Wasm.call(s, %{"op" => "capabilities"})
    assert!(cap["ok"] == true, "graphlaw.wasm capabilities op ok")

    doc_data = fn id -> %{"text" => Ath3.Facts.doc_ttl(id), "dialect" => "turtle"} end

    # SHACL preflight
    good = Ath3.Wasm.call(s, %{"op" => "shacl", "data" => doc_data.("D-1"), "shapes" => shapes_ttl})
    assert!(good["ok"] == true and good["result"]["conforms"] == true, "shacl: conforming D-1 conforms")

    bad = Ath3.Wasm.call(s, %{"op" => "shacl", "data" => doc_data.("D-3"), "shapes" => shapes_ttl})

    assert!(
      bad["ok"] == true and bad["result"]["conforms"] == false and
        Enum.any?(bad["result"]["results"], &(&1["message"] =~ "custodian")),
      "shacl non-vacuity: D-3 missing fields refuse with named sh:message (custodian)"
    )

    # law op: admit:shacl -> derive:n3
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

    inwall = Ath3.Wasm.call(s, law_req.("D-1"))
    assert!(inwall["ok"] == true, "law op (admit:shacl -> derive:n3): in-wall D-1 admitted")

    nq = inwall["result"]["nquads"]
    assert!(nq =~ "Admissible" and nq =~ "https://ev.local/doc/D-1",
      "in-wall D-1: ev:Admissible derived over the credential-allowed-matter intersection"
    )

    receipts = inwall["result"]["receipts"]
    assert!(length(receipts) == 2, "law receipt chain: 2 steps receipted (admit:shacl, derive:n3)")

    [r1, r2] = receipts
    assert!(r1["step"] == "admit:shacl" and r2["step"] == "derive:n3", "receipt steps are admit:shacl then derive:n3")

    assert!(r2["added"] == 3 and r2["parent"] == r1["child"],
      "derive:n3 added 3 facts (BatesWellFormed, admittedBy, Admissible); blake3 parent == shacl child"
    )

    breach = Ath3.Wasm.call(s, law_req.("D-2"))
    assert!(breach["ok"] == true, "law op: wall-breach D-2 shapes admitted (structurally complete)")

    bnq = breach["result"]["nquads"]
    assert!(bnq =~ "BatesWellFormed" and bnq =~ "https://ev.local/doc/D-2",
      "breach D-2: bates pattern ATH-[0-9]{6} witnessed (BatesWellFormed derived)"
    )

    assert!(not (bnq =~ "Admissible"),
      "breach D-2 fail-closed: Admissible NEVER derived (no allowed-matter intersection) => quarantine"
    )

    # standalone n3 op reaches the same partition
    prog = n3_rules <> Ath3.Facts.doc_ttl("D-1") <> Ath3.Facts.doc_ttl("D-2")
    n3r = Ath3.Wasm.call(s, %{"op" => "n3", "text" => prog})
    assert!(n3r["ok"] == true, "n3 op fixed point reached over rules.n3 + facts")

    closure = n3r["result"]["derived"]
    d2_adm = Enum.any?(String.split(closure, "\n"), &(&1 =~ "doc/D-2" and &1 =~ "Admissible"))

    assert!(closure =~ "doc/D-1" and closure =~ "Admissible" and not d2_adm,
      "n3 op partition == law op partition (D-1 Admissible, D-2 not)"
    )

    # shape-incomplete document: typed NotAdmitted at the shacl step
    refused = Ath3.Wasm.call(s, law_req.("D-3"))
    code = get_in(refused, ["result", "error", "details", "code"])

    assert!(
      code == "NotAdmitted" and Enum.count(get_in(refused, ["result", "error", "details", "violations"]) || []) == 3,
      "law op on D-3: typed NotAdmitted refusal, 3 minCount violations named (0 bytes past the sieve)"
    )

    # LAW-DERIVED verdicts for leg C
    %{"D-1" => :compliant, "D-2" => :wall_breach, "D-3" => :andon}
  end

  # ------------------------------------------------------------------
  # Leg B — smalt LawCompiler over shapes.ttl
  # ------------------------------------------------------------------
  defp leg_b(shapes_ttl) do
    {:ok, doc_guard} = LawCompiler.compile_shape("ev:DocumentShape", shapes_ttl)
    assert!(is_function(doc_guard, 1), "LawCompiler compiled DocumentShape guard from the law file")

    assert!(doc_guard.(Ath3.Facts.guard_ctx("D-1")) == :ok, "D-1 context passes the compiled guard")

    assert!(doc_guard.(Ath3.Facts.guard_ctx("D-2")) == :ok,
      "D-2 context passes the compiled guard (the wall is the rules.n3 layer's job)"
    )

    {:violation, rule3, _diag} = doc_guard.(Ath3.Facts.guard_ctx("D-3"))
    assert!(String.starts_with?(rule3, "DocumentShape/minCount"), "D-3 context refuses with rule #{rule3}")

    {:ok, matter_guard} = LawCompiler.compile_shape("ev:MatterShape", shapes_ttl)
    assert!(matter_guard.(%{"matterId" => "M-100"}) == :ok, "MatterShape guard admits a matter context")

    table = LawCompiler.guard_table!(:ath3_guards)
    {:ok, swapped} = LawCompiler.swap_guard(table, "ev:DocumentShape", shapes_ttl)

    assert!(is_function(swapped, 1) and LawCompiler.lookup_guard(table, "ev:DocumentShape") == {:ok, swapped},
      "GL-7 guard-pointer swap installs and reads back the compiled guard"
    )
  end

  # ------------------------------------------------------------------
  # Leg C — workflow.powl.ttl -> Reticle -> POWL2 executor -> seal
  # ------------------------------------------------------------------
  defp leg_c(powl_ttl, shapes_ttl, wall_verdicts) do
    model = Ath3.PowlTtl.parse!(powl_ttl)

    assert!(model.start == 0 and model.end == 5, "net parsed: start 0, end 5 (integer node ids)")
    assert!(MapSet.new(Map.keys(model.children)) == MapSet.new([0, 1, 2, 3, 4, 5]), "children parsed: tau 0/5 + 1,2,3,4")

    assert!(
      model.children[1].label == :intake and model.children[2].label == :review and
        model.children[3].label == :production and model.children[4].label == :quarantine,
      "labels parsed: intake, review, production, quarantine"
    )

    assert!(MapSet.new(model.edges) == MapSet.new([{0, 1}, {1, 2}, {2, 3}, {2, 4}, {3, 5}, {4, 5}]),
      "edges parsed: 0->1->2, review branch 2->3 | 2->4, exits 3->5, 4->5"
    )

    assert!(model.guards == %{3 => :compliant, 4 => :wall_breach, 5 => :always},
      "guards parsed: 2->3 :compliant, 2->4 :wall_breach, exits :always"
    )

    assert!(Reticle.admit(model) == :ok, "Reticle.admit: SESE workflow net admitted")

    trapped =
      Map.update!(model, :children, &Map.put(&1, 9, %Smalt.POWL2.Reticle.AST.Transition{id: 9, label: :trapped, op: nil}))
      |> Map.update!(:edges, &(&1 ++ [{1, 9}]))

    assert!(match?({:error, {:shacl_violation, "trapped" <> _}}, Reticle.admit(trapped)),
      "SESE non-vacuity: trapped child 9 refused by Reticle.admit"
    )

    # ---- execute the net per document, verdicts from leg A ----
    cf = :"ath3_change_feed_#{System.unique_integer([:positive])}"
    {:ok, _} = ChangeFeed.start_link(base: cf)

    dets = :"ath3_dets_#{System.unique_integer([:positive])}"
    dets_path = Path.join(System.tmp_dir!(), "#{dets}.dets")
    {:ok, ^dets} = :dets.open_file(dets, file: String.to_charlist(dets_path), repair: true)

    {:ok, doc_guard} = LawCompiler.compile_shape("ev:DocumentShape", shapes_ttl)

    results =
      Enum.map(@docs, fn doc ->
        iid = :"ath3_#{doc}_#{System.unique_integer([:positive])}"
        m = bind_ops(Ath3.PowlTtl.parse!(powl_ttl), doc, doc_guard, Map.fetch!(wall_verdicts, doc), cf)
        :ok = Reticle.admit(m)

        Executor.execute_admitted(iid, {:ok, m}, %{doc: doc}, dets, self())

        receive do
          {:orchestration_completed, ^iid, ctx, receipt} -> {doc, {:settled, receipt, ctx}}
          {:orchestration_failed, ^iid, outcome} ->
            [{_k, receipt}] = :dets.lookup(dets, {:powl2_receipt, iid})
            {doc, {:andon, receipt, outcome}}
        after
          15_000 -> raise("ATH-3 COURT FAIL: orchestration for #{doc} did not terminate")
        end
      end)

    settled = Enum.filter(results, fn {_d, r} -> elem(r, 0) == :settled end)
    andons = Enum.filter(results, fn {_d, r} -> elem(r, 0) == :andon end)

    # ---- per-document chain assertions ----
    by_doc = Map.new(results, fn {d, r} -> {d, r} end)

    # D-1: production chain 1 -> 2 -> 3 -> 5
    {:settled, receipt1, ctx1} = by_doc["D-1"]
    nodes1 = Enum.map(receipt1.steps, & &1.node)

    assert!(nodes1 == [1, 2, 3, 5], "D-1 chain: intake(1) -> review(2) -> production(3) -> exit(5)")
    assert!(match?({:ok, 201, _}, ctx1.commit_cas), "D-1: commit CAS 201 into the ChangeFeed")
    assert!(is_binary(ChangeFeed.etag(cf, @pk, "doc-D-1")), "D-1 document present in ChangeFeed")

    # D-2: quarantine branch 1 -> 2 -> 4 -> 5, 0-byte refusal
    {:settled, receipt2, _ctx2} = by_doc["D-2"]
    nodes2 = Enum.map(receipt2.steps, & &1.node)
    assert!(nodes2 == [1, 2, 4, 5], "D-2 chain: intake(1) -> review(2) -> QUARANTINE(4) -> exit(5)")

    qstep = Enum.find(receipt2.steps, &(&1.node == 4))
    assert!(qstep.outcome == :quarantined, "D-2: quarantine transition outcome :quarantined")
    assert!(ChangeFeed.etag(cf, @pk, "doc-D-2") == nil, "D-2 ethical-wall breach: 0-byte refusal (ChangeFeed untouched)")

    # D-3: ANDON at review(2), compiled rule named
    {:andon, receipt3, outcome3} = by_doc["D-3"]
    {:transition_failed, 2, {:andon, {:law, rule_id, _diag}}} = outcome3

    assert!(String.starts_with?(rule_id, "DocumentShape/minCount"),
      "D-3: ANDON at review(2) names compiled rule #{rule_id}"
    )

    nodes3 = Enum.map(receipt3.steps, & &1.node)
    assert!(nodes3 == [1, 2], "D-3 chain stops at review(2): intake(1) -> review(2) ANDON")
    assert!(ChangeFeed.etag(cf, @pk, "doc-D-3") == nil, "D-3: commit never fired (ChangeFeed untouched)")

    assert!(
      is_binary(ChangeFeed.etag(cf, @pk, "doc-D-1")) and ChangeFeed.etag(cf, @pk, "doc-D-2") == nil and
        ChangeFeed.etag(cf, @pk, "doc-D-3") == nil,
      "ChangeFeed holds exactly the 1 production document (0-byte refusals for breach + ANDON)"
    )

    # ---- seal: ONE ReceiptEngine run over ingest + all executor steps ----
    hsm = :"ath3_hsm_#{System.unique_integer([:positive])}"
    {:ok, _} = HsmSigner.start_link(name: hsm)

    run_id = "ath3-run-#{System.unique_integer([:positive])}"
    seal_path = Path.join(System.tmp_dir!(), "#{run_id}.dets")
    {:ok, ^run_id} = ReceiptEngine.open(run_id, seal_path)

    ingest_events =
      Enum.map(@docs, fn doc -> %{"doc" => doc, "bates" => Ath3.Facts.bates(doc), "act" => "ath3.ingest"} end)

    Enum.each(Enum.with_index(ingest_events, 1), fn {ev, epoch} ->
      ReceiptEngine.record_step(run_id, %{epoch: epoch, act: "ath3.ingest", delta: ev})
    end)

    next_epoch = length(ingest_events) + 1

    Enum.reduce(results, next_epoch, fn {_doc, res}, e ->
      steps = elem(res, 1).steps

      steps
      |> Enum.with_index(e)
      |> Enum.each(fn {step, epoch} ->
        ReceiptEngine.record_step(run_id, %{epoch: epoch, act: "ath3.step.#{step.node}", delta: step})
      end)

      e + length(steps)
    end)

    # D-2 quarantine refusal leaf: an explicit 0-byte refusal act
    ReceiptEngine.record_step(run_id, %{
      epoch: 9_999,
      act: "ath3.refusal.quarantine",
      delta: %{
        "doc" => "D-2",
        "reason" => "ethical-wall: matterId M-999 not in the presenting credential's allowed-matter set",
        "bytes_committed" => 0
      }
    })

    signer = fn digest ->
      {:ok, sig} = HsmSigner.sign_digest(hsm, digest)
      sig
    end

    sealed = ReceiptEngine.seal_receipt(run_id, nil, signer)

    total_steps = Enum.reduce(results, 0, fn {_d, r}, acc -> acc + length(elem(r, 1).steps) end)
    expected_leaves = length(ingest_events) + total_steps + 1

    assert!(sealed.step_count == expected_leaves,
      "sealed receipt holds #{expected_leaves} leaves (3 ingest + #{total_steps} executor steps + 1 refusal leaf)"
    )

    assert!(byte_size(sealed.merkle_root) == 32 and sealed.signature != nil,
      "sealed Merkle root is 32 bytes and HSM-signed"
    )

    all_hashes = ReceiptEngine.steps(run_id) |> Enum.map(& &1.hash)
    acts = ReceiptEngine.steps(run_id) |> Enum.map(& &1.act_iri)

    assert!(Enum.count(acts, &String.contains?(&1, "step.3")) == 1,
      "sealed receipt carries exactly 1 production act (D-1)"
    )

    assert!(Enum.count(acts, &String.contains?(&1, "refusal.quarantine")) == 1,
      "sealed receipt carries exactly 1 quarantine refusal leaf (D-2, 0-byte)"
    )

    assert!(Enum.count(acts, &String.contains?(&1, "step.2")) == 3,
      "review acts sealed for all 3 documents (1 produced, 1 quarantined, 1 ANDON)"
    )

    assert!(ReceiptEngine.merkle_root(all_hashes) != ReceiptEngine.merkle_root(List.delete_at(all_hashes, 0)),
      "non-vacuity: dropping a leaf changes the Merkle root"
    )

    File.rm(dets_path)
    ReceiptEngine.close(run_id)
    File.rm(seal_path)

    IO.puts("documents: 3 | production: D-1 | quarantined: D-2 (0-byte) | andon: D-3")
    IO.puts("sealed leaves: #{sealed.step_count}  merkle_root: #{Base.encode16(sealed.merkle_root, case: :lower)}")
    :ok
  end

  # ---- op binding: parsed op NAMES -> domain-blind substrate functions ----
  defp bind_ops(model, doc, doc_guard, verdict, cf) do
    Map.update!(model, :children, fn children ->
      Map.new(children, fn
        {1, t} -> {1, %{t | op: fn ctx -> {:ok, ctx, :intake_ok} end}}
        {2, t} -> {2, %{t | op: review_op(doc, doc_guard, verdict)}}
        {3, t} -> {3, %{t | op: production_op(doc, cf)}}
        {4, t} -> {4, %{t | op: fn ctx -> {:ok, Map.put(ctx, :quarantined, true), :quarantined} end}}
        {id, t} -> {id, %{t | op: fn ctx -> {:ok, ctx, :tau} end}}
      end)
    end)
  end

  defp review_op(doc, doc_guard, verdict) do
    fn ctx ->
      case doc_guard.(Ath3.Facts.guard_ctx(doc)) do
        :ok when verdict == :compliant or verdict == :wall_breach ->
          {:ok, Map.put(ctx, :wall_verdict, verdict), verdict}

        :ok ->
          {:error, {:andon, {:law, "ath3/no-wall-verdict", "no derivation from the law engine"}}}

        {:violation, rule_id, diagnostic} ->
          {:error, {:andon, {:law, rule_id, diagnostic}}}
      end
    end
  end

  defp production_op(doc, cf) do
    fn ctx ->
      case ChangeFeed.put_item(cf, @pk, "doc-#{doc}", %{"doc" => doc, "bates" => Ath3.Facts.bates(doc)}) do
        {:ok, status, etag} -> {:ok, Map.put(ctx, :commit_cas, {:ok, status, etag}), :committed}
        {:error, 412, current} -> {:error, {:cas_stale, current}}
        other -> {:error, {:unexpected_cas_result, other}}
      end
    end
  end
end

# BK-POWLH4: converted from self-exiting script (System.stop at load) to an
# ExUnit case so `mix test test/integration` runs it instead of dropping the
# batch. Court legs unchanged; the run/0 verdict is asserted, not halted on.
defmodule Ath3LawCourtTest do
  use ExUnit.Case, async: false

  test "ATH-3 evidence-law court (wasm law + LawCompiler + POWL settlement)" do
    case Ath3.Court.run() do
      :ok -> :ok
      other -> flunk("ATH-3 COURT: FAIL #{inspect(other)}")
    end
  end
end
