# EXPL10-R2 court (v26.10.22): repairs F4/F5/F10 from
# docs/jira/v26.10.22/receipts/expl10-pipeline-powl-errc.md.
#
# Chicago discipline: real compiled modules and the real Plug face, assertions
# on returned/final state, no mocks, no sleeps. Falsifier legs:
#   F4  scope '/smalt/prod' vs source '/smalt/prod2/x' -> NOT matched;
#       '/smalt/prod' vs '/smalt/prod/x' -> matched (segment boundary).
#   F5  truncated TTL (no final '.') -> typed {:error, {:parse_error, _}},
#       never a compiled guard; full TTL still compiles (positive control).
#   F10 PUT /eventgrid/subscriptions with nil name / nil scope / string
#       ttl_seconds -> typed 400, never a FunctionClauseError 500.
#
# Context: solo (internal tier, in-process wire faces).

defmodule Smalt.Test.Internal.Expl10r2CourtTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.EventGrid.PushRouter
  alias Smalt.EventGrid.PushRouterPlug
  alias Smalt.POWL2.LawCompiler

  @ttl """
  ex:BillingShape a sh:NodeShape ;
    sh:property [ sh:path "total" ; sh:maxInclusive 10000 ] .
  """

  @truncated """
  ex:BillingShape a sh:NodeShape ;
    sh:property [ sh:path "total" ; sh:maxInclusive 10000 ] .
  ex:CutShape a sh:NodeShape ;
    sh:property [ sh:path "total" ; sh:maxInclusive
  """

  setup do
    Application.put_env(:smalt, :eventgrid_push,
      wal_dir: Path.join(System.tmp_dir!(), "expl10r2-wal-#{System.unique_integer([:positive])}")
    )

    PushRouter.reset()
    on_exit(fn ->
      Application.delete_env(:smalt, :eventgrid_push)
      PushRouter.reset()
    end)
    :ok
  end

  # -- F4: segment-boundary scope match -------------------------------------------

  describe "F4 PushRouter scope matching" do
    test "scope /smalt/prod does NOT match source /smalt/prod2/x" do
      {:ok, sub} = PushRouter.put_subscription("f4-no", "/smalt/prod", shape_ref(), %{"type" => "wal"})
      assert sub.scope == "/smalt/prod"

      {:ok, summary} =
        PushRouter.ingest(%{
          "specversion" => "1.0",
          "id" => "e1",
          "source" => "/smalt/prod2/x",
          "data" => %{"total" => 5}
        })

      assert summary.matched == 0
      assert summary.no_match_events == 1
      assert PushRouter.deliveries("f4-no") == []
    end

    test "scope /smalt/prod DOES match source /smalt/prod/x (child path)" do
      {:ok, _} = PushRouter.put_subscription("f4-yes", "/smalt/prod", shape_ref(), %{"type" => "wal"})

      {:ok, summary} =
        PushRouter.ingest(%{
          "specversion" => "1.0",
      "id" => "e2",
          "source" => "/smalt/prod/x",
          "data" => %{"total" => 5}
        })

      assert summary.matched == 1
      assert summary.delivered == 1
      assert [%{"subscription" => "f4-yes"}] = PushRouter.deliveries("f4-yes")
    end

    test "scope matches its own exact source (baseline)" do
      {:ok, _} = PushRouter.put_subscription("f4-self", "/smalt/prod", shape_ref(), %{"type" => "wal"})

      {:ok, summary} =
        PushRouter.ingest(%{
          "specversion" => "1.0",
          "id" => "e3",
          "source" => "/smalt/prod",
          "data" => %{"total" => 5}
        })

      assert summary.matched == 1
      assert summary.delivered == 1
    end
  end

  # -- F5: truncated TTL is a typed parse refusal ---------------------------------

  describe "F5 LawCompiler split_statements" do
    test "truncated TTL (no final '.') is {:error, {:parse_error, _}}, never a guard" do
      assert {:error, {:parse_error, desc}} = LawCompiler.compile_shape("ex:CutShape", @truncated)
      assert desc =~ "truncated"
    end

    test "truncated-only TTL (single unterminated statement) refuses" do
      assert {:error, {:parse_error, _}} =
               LawCompiler.compile_shape("ex:BillingShape", "ex:BillingShape a sh:NodeShape ;")
    end

    test "trailing garbage after the last '.' refuses" do
      assert {:error, {:parse_error, _}} =
               LawCompiler.compile_shape(
                 "ex:BillingShape",
                 @ttl <> " ex:Orphan a sh:NodeShape"
               )
    end

    test "full TTL still compiles and the guard enforces the ceiling (positive control)" do
      {:ok, guard} = LawCompiler.compile_shape("ex:BillingShape", @ttl)
      assert :ok = guard.(%{"total" => 999})
      assert {:violation, rule, _} = guard.(%{"total" => 99_999})
      assert rule =~ "maxInclusive"
    end
  end

  # -- F10: Plug param validation before dispatch ----------------------------------

  describe "F10 PushRouterPlug param validation" do
    defp plug_put(body) do
      Plug.Test.conn(:put, "/eventgrid/subscriptions", Jason.encode!(body))
      |> PushRouterPlug.call(nil)
    end

    defp status_of(conn), do: conn.status
    defp code_of(conn) do
      {:ok, %{"error" => %{"code" => code}}} = Jason.decode(conn.resp_body)
      code
    end

    test "nil name -> typed 400 InvalidSubscriptionName (never a 500)" do
      conn = plug_put(%{"scope" => "/smalt/prod", "shape_ref" => shape_ref(), "destination" => %{"type" => "wal"}})
      assert status_of(conn) == 400, "got: #{inspect(conn.status)} #{inspect(conn.resp_body)}"
      assert code_of(conn) == "InvalidSubscriptionName"
    end

    test "nil scope -> typed 400 InvalidScope" do
      conn = plug_put(%{"name" => "f10a", "shape_ref" => shape_ref(), "destination" => %{"type" => "wal"}})
      assert status_of(conn) == 400
      assert code_of(conn) == "InvalidScope"
    end

    test "string ttl_seconds -> typed 400 InvalidDestination" do
      conn =
        plug_put(%{
          "name" => "f10b",
          "scope" => "/smalt/prod",
          "shape_ref" => shape_ref(),
          "destination" => %{"type" => "wal", "ttl_seconds" => "300"}
        })

      assert status_of(conn) == 400
      assert code_of(conn) == "InvalidDestination"
    end

    test "valid body still answers 201 (positive control)" do
      conn =
        plug_put(%{
          "name" => "f10-ok",
          "scope" => "/smalt/prod",
          "shape_ref" => shape_ref(),
          "destination" => %{"type" => "wal"}
        })

      assert status_of(conn) == 201
      assert {:ok, %{name: "f10-ok"}} = PushRouter.get_subscription("f10-ok")
    end
  end

  defp shape_ref do
    %{"shape" => "BillingShape", "ttl" => @ttl}
  end
end
