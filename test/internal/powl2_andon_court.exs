defmodule Smalt.Powl2.AndonCourtTest do
  use ExUnit.Case, async: true

  alias Smalt.Powl2.Andon

  @ts 1_760_000_000_000_000_000
  @ctx %{order: "8921", plan: %{steps: ["sign", "execute"]}, risk_officer: nil}

  test "format stability: same inputs + injected ts/session -> byte-identical receipt" do
    a = Andon.format_andon("risk_officer_signature", "Missing Risk Officer signature for Order #8921", @ctx, ts: @ts, session: "s1")
    b = Andon.format_andon("risk_officer_signature", "Missing Risk Officer signature for Order #8921", @ctx, ts: @ts, session: "s1")

    assert a == b
    assert Andon.ntriples(a) == Andon.ntriples(b)
  end

  test "digest binds the context snapshot" do
    r = Andon.format_andon("risk_officer_signature", "Missing Risk Officer signature for Order #8921", @ctx, ts: @ts)
    expected = Base.encode16(:crypto.hash(:sha256, :erlang.term_to_binary(@ctx)), case: :lower)

    assert r.context_digest == expected
    assert String.length(r.context_digest) == 64

    # Any perturbation of the context flips the digest.
    r2 = Andon.format_andon("risk_officer_signature", "Missing Risk Officer signature for Order #8921", %{order: "8922"}, ts: @ts)
    refute r2.context_digest == r.context_digest
  end

  test "ntriples well-formed: one triple per line, terminating dot, parseable IRIs/literals" do
    r =
      Andon.format_andon("risk_officer_signature", ~s(Missing signature with "quote"),
        @ctx, ts: @ts, session: "sess7")

    lines = String.split(Andon.ntriples(r), "\n")
    assert length(lines) == 10

    Enum.each(lines, fn line ->
      assert String.ends_with?(line, " .")
      assert String.contains?(line, "<urn:smalt:")
      # balanced angle brackets
      assert Enum.count(String.graphemes(line), &(&1 == "<")) == Enum.count(String.graphemes(line), &(&1 == ">"))
    end)

    assert String.contains?(Enum.at(lines, 3), "<http://www.w3.org/ns/prov#wasInvalidatedBy>")
    assert String.contains?(Enum.at(lines, 0), "<http://www.w3.org/ns/prov#Entity>")
    assert String.contains?(Enum.at(lines, 1), "<http://www.w3.org/ns/prov#Activity>")
    assert String.contains?(Enum.at(lines, 2), "<http://www.w3.org/ns/prov#Agent>")
    # escaped quote survives as valid literal syntax
    assert String.contains?(Enum.at(lines, 8), "\\\"quote\\\"")
  end

  test "agent-consumable diagnostic carries rule id + repair hint" do
    r = Andon.format_andon("risk_officer_signature", "Missing Risk Officer signature for Order #8921", @ctx, ts: @ts)

    assert r.agent_message == "[ANDON risk_officer_signature] Missing Risk Officer signature for Order #8921 — repair: obtain the Risk Officer signature on the plan, then resubmit"
    assert String.contains?(r.agent_message, "risk_officer_signature")
    assert String.contains?(r.agent_message, "#8921")
    # the same message must be reachable from the ntriples block alone
    assert String.contains?(Andon.ntriples(r), "[ANDON risk_officer_signature]")
  end

  test "prov vocabulary: receipt is prov:Entity invalidated by the refused activity" do
    r = Andon.format_andon("order_capacity", "Order exceeds tick capacity", @ctx, ts: @ts, session: "s9")
    nt = Andon.ntriples(r)

    assert String.contains?(nt, "<urn:smalt:andon:s9:order_capacity:#{r.context_digest}>")
    assert String.contains?(nt, "<urn:smalt:act:s9:order_capacity>")
    assert String.contains?(nt, "<urn:smalt:act:s9:order_capacity> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Activity> .")
    # vocabulary shared with PPlan.ReceiptEngine's serialization
    assert String.contains?(nt, "http://www.w3.org/ns/prov#")
  end
  # -- GAP-6a Agent chain legs -------------------------------------------------
  # Falsifier (w3ca census GAP-6a): a prov:Activity with no wasAssociatedWith
  # edge to a typed prov:Agent.

  test "GAP-6a: every ntriples leaf carries the full Entity/Activity/Agent chain" do
    r = Andon.format_andon("risk_officer_signature", "Missing signature", @ctx, ts: @ts, session: "s1")
    nt = Andon.ntriples(r)

    agent = "urn:smalt:agent:s1"
    assert r.agent == agent
    assert String.contains?(nt, "<#{agent}> <http://www.w3.org/1999/02/22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Agent> .")
    assert String.contains?(nt, "<urn:smalt:act:s1:risk_officer_signature> <http://www.w3.org/ns/prov#wasAssociatedWith> <#{agent}> .")
    assert String.contains?(nt, "<urn:smalt:andon:s1:risk_officer_signature:#{r.context_digest}> <http://www.w3.org/ns/prov#wasAttributedTo> <#{agent}> .")

    # the fail-closed verifier admits a full-chain leaf...
    assert Andon.verify_ntriples(nt) == :ok

    # ...and refuses any leaf missing ANY chain term (typed, not silent).
    chain_terms = [
      "22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Entity>",
      "22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Activity>",
      "22-rdf-syntax-ns#type> <http://www.w3.org/ns/prov#Agent>",
      "prov#wasInvalidatedBy>",
      "prov#wasAssociatedWith>",
      "prov#wasAttributedTo>"
    ]

    Enum.each(chain_terms, fn term ->
      tampered =
        nt
        |> String.split("\n")
        |> Enum.reject(&String.contains?(&1, term))
        |> Enum.join("\n")

      assert {:error, [_ | _]} = Andon.verify_ntriples(tampered)
    end)

    # :agent opt override is honored, domain-blind.
    r2 = Andon.format_andon("risk_officer_signature", "Missing signature", @ctx, ts: @ts, session: "s1", agent: "urn:smalt:agent:operator-7")
    assert Andon.verify_ntriples(Andon.ntriples(r2)) == :ok
    assert String.contains?(Andon.ntriples(r2), "urn:smalt:agent:operator-7")
  end

  test "GAP-6a: json_ld carries the Agent chain terms" do
    r = Andon.format_andon("order_capacity", "over capacity", @ctx, ts: @ts, session: "s3")
    ld = Jason.decode!(r.json_ld)

    assert ld["prov:wasAssociatedWith"] == "urn:smalt:agent:s3"
    assert ld["prov:wasAttributedTo"] == "urn:smalt:agent:s3"
    assert ld["andon:agent"] == %{"@id" => "urn:smalt:agent:s3", "@type" => "prov:Agent"}
  end

  # -- GL-3 refinement leg (GRAPHLAW-SPEC §GL-3): JSON-LD serialization -------
  # Falsifier: missing @type / failedConstraint / repair action.

  @ld_ctx ["https://www.w3.org/ns/prov.jsonld", %{"andon" => "https://smalt.io/ontology/andon#"}]

  test "GL-3: json_ld serializes the refusal as andon:RefusalReceipt with every spec field" do
    diag =
      "Transaction value $50,000 exceeds threshold $10,000 without authorized signature"

    r =
      Andon.format_andon("OrderShape/maxInclusive/orderTotal", diag, @ctx,
        ts: @ts, session: "s1"
      )

    ld = Jason.decode!(r.json_ld)

    assert ld["@type"] == "andon:RefusalReceipt"
    assert ld["@context"] == Jason.decode!(Jason.encode!(@ld_ctx))
    assert ld["andon:refusalId"] == "urn:smalt:andon:s1:OrderShape/maxInclusive/orderTotal:#{r.context_digest}"
    assert ld["andon:violatingActivity"] == "urn:smalt:act:s1:OrderShape/maxInclusive/orderTotal"
    assert ld["andon:failedConstraint"] == "OrderShape/maxInclusive/orderTotal"
    assert ld["andon:shapeClass"] == "maxInclusive"
    assert ld["andon:detail"] == diag
    assert ld["andon:suggestedRepairAction"] == "urn:smalt:action:repair_OrderShape_maxInclusive_orderTotal"
    assert ld["prov:atTime"] == "2025-10-09T08:53:20Z"
    assert ld["prov:wasInvalidatedBy"] == "urn:smalt:actor:s1"
  end

  test "GL-3: json_ld is byte-identical for identical injected inputs" do
    a = Andon.format_andon("risk_officer_signature", "Missing signature", @ctx, ts: @ts, session: "s1")
    b = Andon.format_andon("risk_officer_signature", "Missing signature", @ctx, ts: @ts, session: "s1")

    assert a.json_ld == b.json_ld
  end

  test "GL-3: repair_action override pins andon:suggestedRepairAction; unknown rule ids degrade shapeClass" do
    r =
      Andon.format_andon("mystery_rule", "unmapped rule", @ctx,
        ts: @ts,
        session: "s2",
        repair_action: "urn:smalt:action:request_compliance_signature"
      )

    ld = Jason.decode!(r.json_ld)
    assert ld["andon:suggestedRepairAction"] == "urn:smalt:action:request_compliance_signature"
    assert ld["andon:shapeClass"] == "RuleViolation"

    assert ld["andon:suggestedRepairAction"] != "urn:smalt:action:repair_mystery_rule"
  end
end
