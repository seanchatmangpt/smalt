defmodule Smalt.EXPL5R2CourtTest do
  @moduledoc """
  EXPL-5 R2 repair court (T3/T4/T5, docs/jira/v26.10.22/receipts/expl5-dataplane-errc.md).
  Chicago: real compiled modules, assertions on returned/final values, no mocks.
  Falsifier legs: probed non-map data refused by the compiled SHACL guard (T3),
  non-list ingest typed-refused (T4), KQL error shape back on the documented
  `{:parse | :limit, msg}` contract (T5). Positive controls pin the happy paths.
  """

  use ExUnit.Case, async: false

  alias Smalt.DataPlane.KQL
  alias Smalt.EventGrid.PushRouter
  alias Smalt.POWL2.LawCompiler

  @ttl """
  ex:ApprovalShape a sh:NodeShape ;
    sh:property [ sh:path "actor" ; powl:notEquals "approver" ;
      sh:message "actor may not approve own report" ] .
  """

  # -- T3: LawCompiler guard refuses non-map data ------------------------------

  describe "EXPL5-T3 compiled guard vs non-map data" do
    test "non-map payloads fail the guard (typed violation, never :ok)" do
      {:ok, guard} = LawCompiler.compile_shape("ex:ApprovalShape", @ttl)

      for bad <- [[], ["a"], "str", 42, 3.14, nil, :atom] do
        assert {:violation, rule, detail} = guard.(bad),
               "expected violation for #{inspect(bad)}"

        assert rule =~ "ApprovalShape"
        assert detail =~ "non-map data"
      end
    end

    test "real map events still conform (positive control)" do
      {:ok, guard} = LawCompiler.compile_shape("ex:ApprovalShape", @ttl)
      assert :ok = guard.(%{"actor" => "alice", "approver" => "bob"})
    end

    test "real map events with a real violation still violate (non-vacuity control)" do
      {:ok, guard} = LawCompiler.compile_shape("ex:ApprovalShape", @ttl)
      assert {:violation, rule, _} = guard.(%{"actor" => "a", "approver" => "a"})
      assert rule =~ "notEquals"
    end
  end

  # -- T4: PushRouter.ingest/1 non-list input ----------------------------------

  describe "EXPL5-T4 PushRouter.ingest/1" do
    test "non-list, non-event input is typed-refused, not zero-count success" do
      assert {:error, :invalid_events} = PushRouter.ingest("oops")
      assert {:error, :invalid_events} = PushRouter.ingest(42)
      assert {:error, :invalid_events} = PushRouter.ingest(%{specversion: "1.0"})
    end
  end

  # -- T5: KQL.run/2 error contract --------------------------------------------

  describe "EXPL5-T5 KQL.run/2 error shape" do
    test "non-string query / non-list rows returns the documented tagged shape" do
      assert {:error, {:limit, msg}} = KQL.run(%{}, %{})
      assert is_binary(msg)
      assert {:error, {tag, _}} = KQL.run([%{"a" => 1}], 42)
      assert tag in [:parse, :limit]
    end
  end
end
