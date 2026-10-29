defmodule Smalt.GraphLawAgentBoundingTest do
  @moduledoc """
  GL-5 "stochastic agent bounding" court (spec §2).

  A real agent process proposes 500 state transitions at a settlement net
  guarded by the landed graphlaw seam:

    * GL-1 (admission law) — every proposal must pass
      `Smalt.GraphLaw.Validator.validate_resource/2` (real compiled SHACL
      shapes from priv/shacl/smalt-shapes.ttl via Smalt.Registry bindings)
      BEFORE any mutation of the ETS data plane.
    * GL-2 (ANDON law) — every refusal mints an ANDON receipt into a
      dedicated ETS log naming the violated rule(s): constraint and shape
      path (`minCount:location`, `closed:zzz`,
      `type_not_admitted:<type>`).

  The proposal stream is deterministic (seeded :rand.exsss); ~30% of the
  500 proposals violate policy via four rotating violation classes. The
  court recomputes the expected post-run data plane from the same seed,
  so the deep state check is FULL-TABLE equality, not a count.

  Contracts asserted:
    1. zero violating transitions mutated the ETS data plane
    2. every violation produced an ANDON receipt naming the rule
    3. all lawful proposals executed (exact ref set + exact payloads)
    4. receipts collectively name every distinct rule family hit
  """

  use ExUnit.Case, async: false

  @n_proposals 500
  @seed {500_005, 777, 13}

  @lawful_kinds [:lawful_rg, :lawful_vnet, :lawful_nsg, :lawful_vm]
  @violation_classes [:missing_location, :missing_prefixes, :closed_extra, :unadmitted_type]

  # ------------------------------------------------------------------
  # deterministic stochastic agent
  # ------------------------------------------------------------------

  defp build_proposals(seed, n) do
    :rand.seed(:exsss, seed)

    for i <- 1..n do
      violating? = :rand.uniform(10) <= 3
      {kind, payload} = proposal_body(i, violating?)
      {i, kind, payload}
    end
  end

  # Paths are TOP-LEVEL because the compiled shapes declare bare paths
  # (smalt:location, smalt:addressPrefixes, smalt:vmSize). The NSG shape
  # is sh:closed true over {location, tags, securityRules}; every other
  # shape used here is sh:closed false.
  defp proposal_body(i, false) do
    case rem(i, 4) do
      0 ->
        {:lawful_rg, %{"location" => "eastus"}}

      1 ->
        {:lawful_vnet, %{"location" => "eastus", "addressPrefixes" => ["10.0.0.0/16"]}}

      2 ->
        {:lawful_nsg, %{"location" => "eastus", "tags" => %{}, "securityRules" => []}}

      _ ->
        {:lawful_vm, %{"location" => "westus2", "vmSize" => "Standard_D2s_v3"}}
    end
  end

  defp proposal_body(i, true) do
    case rem(i, 4) do
      0 ->
        {:missing_location, %{"name" => "rg-" <> Integer.to_string(i)}}

      1 ->
        {:missing_prefixes, %{"location" => "eastus"}}

      2 ->
        {:closed_extra, %{"location" => "eastus", "zzz" => 1}}

      _ ->
        {:unadmitted_type, %{"location" => "eastus"}}
    end
  end

  defp violating_kind?(kind), do: kind not in @lawful_kinds

  defp type_for_kind(kind) do
    case kind do
      :lawful_rg -> "Microsoft.Resources/resourceGroups"
      :lawful_vnet -> "Microsoft.Network/virtualNetworks"
      :lawful_nsg -> "Microsoft.Network/networkSecurityGroups"
      :lawful_vm -> "Microsoft.Compute/virtualMachines"
      :missing_location -> "Microsoft.Resources/resourceGroups"
      :missing_prefixes -> "Microsoft.Network/virtualNetworks"
      :closed_extra -> "Microsoft.Network/networkSecurityGroups"
      :unadmitted_type -> "Microsoft.Fabric/bogusInstances"
    end
  end

  # Expected rule family prefix per violation class (court-side
  # structural knowledge, independent of the guard).
  defp expected_family(:missing_location), do: "minCount"
  defp expected_family(:missing_prefixes), do: "minCount"
  defp expected_family(:closed_extra), do: "closed"
  defp expected_family(:unadmitted_type), do: "type_not_admitted"

  # ------------------------------------------------------------------
  # settlement net (the GL-1 / GL-2 seam)
  # ------------------------------------------------------------------

  @doc false
  def settle(dataplane, andon, {ref, kind, payload}) do
    type = type_for_kind(kind)

    # GL-1: admission law. Validate against the real compiled SHACL
    # shapes BEFORE any mutation. No write precedes the verdict.
    case Smalt.GraphLaw.Validator.validate_resource(type, payload) do
      {:ok} ->
        :ets.insert(dataplane, {ref, type, payload})
        {:settled, ref}

      {:invalid, violations} ->
        rules = Enum.map(violations, fn v -> v.constraint <> ":" <> v.path end)
        :ets.insert(andon, {ref, kind, rules})
        {:refused, ref, rules}

      {:refused, :type_not_admitted} ->
        rules = ["type_not_admitted:" <> type]
        :ets.insert(andon, {ref, kind, rules})
        {:refused, ref, rules}
    end
  end

  # ------------------------------------------------------------------
  # the agent process (real collaborator, not a mock)
  # ------------------------------------------------------------------

  defp run_agent(proposals, dataplane, andon) do
    task =
      Task.async(fn ->
        Enum.map(proposals, fn proposal -> settle(dataplane, andon, proposal) end)
      end)

    Task.await(task, 60_000)
  end

  # ------------------------------------------------------------------
  # court
  # ------------------------------------------------------------------

  describe "GL-5 stochastic agent bounding" do
    @tag :graphlaw_agent_bounding
    test "500 seeded proposals: zero violating mutations, full ANDON coverage, lawful completion" do
      dataplane = :ets.new(:gl5_dataplane, [:set, :public])
      andon = :ets.new(:gl5_andon, [:set, :public])

      proposals = build_proposals(@seed, @n_proposals)
      violating = Enum.count(proposals, fn {_r, k, _p} -> violating_kind?(k) end)
      lawful = @n_proposals - violating

      # ~30% seeded-distribution fence (deterministic seed, bounded window)
      assert violating in 120..180,
             "expected ~30% violating of 500, got #{violating}"

      results = run_agent(proposals, dataplane, andon)

      # premise: exactly one verdict per proposal, refs in order
      assert length(results) == @n_proposals

      Enum.each(Enum.with_index(results, 1), fn
        {{:settled, ref}, i} -> assert ref == i
        {{:refused, ref, _rules}, i} -> assert ref == i
      end)

      settled = Enum.count(results, &match?({:settled, _}, &1))
      refused = Enum.count(results, &match?({:refused, _r, _rules}, &1))
      assert settled == lawful
      assert refused == violating

      # (1) DEEP STATE CHECK — full-table equality against the
      # lawful-only replay computed independently in the court.
      expected_rows =
        proposals
        |> Enum.reject(fn {_r, k, _p} -> violating_kind?(k) end)
        |> Enum.map(fn {ref, kind, payload} ->
          {ref, type_for_kind(kind), payload}
        end)
        |> Enum.sort()

      actual_rows = dataplane |> :ets.tab2list() |> Enum.sort()

      assert actual_rows == expected_rows,
             "deep state check failed: #{length(actual_rows)} data-plane rows " <>
               "vs #{length(expected_rows)} lawful-only expected"

      # (2) EVERY violation produced an ANDON receipt naming the rule.
      andon_rows = :ets.tab2list(andon)

      assert length(andon_rows) == violating,
             "ANDON receipts #{length(andon_rows)} != violations #{violating}"

      andon_by_ref = Map.new(andon_rows, fn {ref, kind, rules} -> {ref, {kind, rules}} end)

      Enum.each(proposals, fn {ref, kind, _p} ->
        if violating_kind?(kind) do
          assert {^kind, rules} = Map.fetch!(andon_by_ref, ref)
          assert rules != [], "ANDON receipt for proposal #{ref} names no rule"

          assert Enum.any?(rules, fn rule ->
                   String.starts_with?(rule, expected_family(kind) <> ":")
                 end),
                 "receipt #{inspect(rules)} does not name family " <> expected_family(kind)
        end
      end)

      # (3) ALL lawful proposals executed — ref-set equality plus the
      # exact payload equality already proven by (1).
      lawful_refs =
        proposals
        |> Enum.reject(fn {_r, k, _p} -> violating_kind?(k) end)
        |> Enum.map(fn {ref, _k, _p} -> ref end)
        |> MapSet.new()

      executed_refs = MapSet.new(actual_rows, fn {ref, _t, _p} -> ref end)
      assert executed_refs == lawful_refs

      # (4) SELF-CORRECTION CONTRACT — the receipts collectively name
      # EVERY distinct rule family hit, so the agent can read exactly
      # what it violated.
      named_families =
        andon_rows
        |> Enum.flat_map(fn {_ref, _k, rules} -> rules end)
        |> Enum.map(fn rule -> hd(String.split(rule, ":")) end)
        |> Enum.uniq()
        |> Enum.sort()

      expected_families =
        @violation_classes |> Enum.map(&expected_family/1) |> Enum.uniq() |> Enum.sort()

      assert named_families == expected_families,
             "receipts named #{inspect(named_families)}, " <>
               "expected families #{inspect(expected_families)}"
    end
  end
end
