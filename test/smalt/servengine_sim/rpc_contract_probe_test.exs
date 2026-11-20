defmodule Smalt.ServengineSim.RpcContractProbeTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.ServengineSim.RpcContractProbe

  @token "local-dev"

  @full_morning_view_fields [
    "generatedAt",
    %{
      "workOrders" => [
        "total",
        %{
          "byStatus" => [
            "draft",
            "ingested",
            "matching",
            "dispatched",
            "inProgress",
            "pendingAudit",
            "completed",
            "invoiced",
            "closedOut",
            "cancelled"
          ]
        }
      ]
    },
    %{
      "invoices" => [
        "total",
        %{
          "byStatus" => [
            "draft",
            "submitted",
            "approved",
            "sent",
            "paid",
            "overdue",
            "disputed",
            "void"
          ]
        },
        "outstandingTotal",
        "overdueTotal",
        "paidTotal",
        "disputedTotal"
      ]
    },
    %{"procurement" => ["supplierCount", "spendTotal"]},
    %{"collections" => ["outstandingCount", "overdueCount", "outstandingTotal", "overdueTotal"]},
    %{
      "onboarding" => [
        "serviceProviderTotal",
        %{"byStatus" => ["onboarding", "active", "suspended", "offboarded"]},
        "bans",
        "doNotUse"
      ]
    },
    %{"sla" => ["openWithDeadline", "pastDeadline", "conformancePct"]}
  ]

  setup do
    RpcContractProbe.reset!()
    seed = RpcContractProbe.default_seed!()
    on_exit(fn -> RpcContractProbe.reset!() end)
    {:ok, seed: seed}
  end

  defp rpc(body, extra_headers \\ []) do
    headers =
      [
        {"authorization", "Bearer #{@token}"},
        {"content-type", "application/json"},
        {"accept", "application/json"}
      ] ++ extra_headers

    c =
      conn(:post, "/internal-api/rpc/run", Jason.encode!(body))
      |> put_headers(headers)
      |> RpcContractProbe.call([])

    {c.status, Jason.decode!(c.resp_body), c}
  end

  defp put_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
  end

  describe "boundary, auth, fields spec guard, and tenant arm" do
    test "OPTIONS preflight returns 204 without auth" do
      c = conn(:options, "/internal-api/rpc/run") |> RpcContractProbe.call([])
      assert c.status == 204
    end

    test "missing or wrong Bearer token returns 401 unauthorized" do
      c1 =
        conn(:post, "/internal-api/rpc/run", ~s({"action":"list_tenants","fields":["id"]}))
        |> put_req_header("content-type", "application/json")
        |> RpcContractProbe.call([])

      assert c1.status == 401
      assert Jason.decode!(c1.resp_body)["error"] == "unauthorized"

      c2 =
        conn(:post, "/internal-api/rpc/run", ~s({"action":"list_tenants","fields":["id"]}))
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer wrong")
        |> RpcContractProbe.call([])

      assert c2.status == 401
    end

    test "malformed JSON returns 400 invalid_json and unknown path returns 404" do
      c1 =
        conn(:post, "/internal-api/rpc/run", "{not-json")
        |> put_req_header("authorization", "Bearer #{@token}")
        |> RpcContractProbe.call([])

      assert c1.status == 400
      assert Jason.decode!(c1.resp_body)["error"] == "invalid_json"

      c2 =
        conn(:post, "/internal-api/rpc/nope", "{}")
        |> put_req_header("authorization", "Bearer #{@token}")
        |> RpcContractProbe.call([])

      assert c2.status == 404
    end

    test "ASH-2 boundary guard refuses non-list fields and invalid elements with 400 invalid_fields_spec", %{seed: seed} do
      for bad_fields <- ["id,name", 123, %{"id" => true}, [123], [true]] do
        {status, body, _} =
          rpc(%{"action" => "morning_view", "tenant" => seed.tenant_slug, "fields" => bad_fields})

        assert status == 400
        assert body["error"] == "invalid_fields_spec"
        assert body["key"] == "fields"
      end

      {status, body, _} =
        rpc(%{
          "action" => "list_clients",
          "tenant" => seed.tenant_slug,
          "fields" => ["id"],
          "metadata_fields" => "bad"
        })

      assert status == 400
      assert body["error"] == "invalid_fields_spec"
      assert body["key"] == "metadata_fields"
    end

    test "tenant arm refuses missing/unknown tenant and allows platform_view actions", %{seed: seed} do
      {400, missing, _} = rpc(%{"action" => "list_clients", "fields" => ["id"]})
      assert missing["error"] == "tenant_required"

      {400, unknown, _} =
        rpc(%{"action" => "list_clients", "tenant" => "ghost-tenant", "fields" => ["id"]})

      assert unknown["error"] == "unknown_tenant"

      {400, bad_hdr, _} =
        rpc(%{"action" => "list_clients", "fields" => ["id"]}, [{"x-tenant-id", "bad-id"}])

      assert bad_hdr["error"] == "unknown_tenant"

      {200, by_hdr, _} =
        rpc(%{"action" => "list_clients", "fields" => ["id"]}, [{"x-tenant-id", seed.tenant_id}])

      assert by_hdr["success"] == true
      assert length(by_hdr["data"]) == 2

      {200, tenants, _} = rpc(%{"action" => "list_tenants", "fields" => ["id", "slug"]})
      assert tenants["success"] == true
      assert length(tenants["data"]) == 2
    end

    test "unknown or missing action returns 200 AshRpcError envelope", %{seed: seed} do
      {200, missing, _} = rpc(%{"tenant" => seed.tenant_slug})
      assert missing["success"] == false
      assert hd(missing["errors"])["type"] == "missing_required_parameter"

      {200, unknown, _} = rpc(%{"action" => "no_such_action", "tenant" => seed.tenant_slug})
      assert unknown["success"] == false
      assert hd(unknown["errors"])["type"] == "action_not_found"
    end
  end

  describe "morning_view required fields selection and live aggregates" do
    test "morning_view refuses when fields is omitted or empty []", %{seed: seed} do
      {200, omitted, _} = rpc(%{"action" => "morning_view", "tenant" => seed.tenant_slug})
      assert omitted["success"] == false
      assert [%{"type" => "missing_required_parameter", "vars" => %{"parameter" => "fields"}}] = omitted["errors"]

      {200, empty, _} = rpc(%{"action" => "morning_view", "tenant" => seed.tenant_slug, "fields" => []})
      assert empty["success"] == false
      assert [%{"type" => "empty_fields_array"}] = empty["errors"]
    end

    test "morning_view rejects invalid nested field specifications", %{seed: seed} do
      {200, bare_map, _} =
        rpc(%{"action" => "morning_view", "tenant" => seed.tenant_slug, "fields" => ["workOrders"]})

      assert bare_map["success"] == false
      assert hd(bare_map["errors"])["type"] == "requires_field_selection"

      {200, prim_nest, _} =
        rpc(%{
          "action" => "morning_view",
          "tenant" => seed.tenant_slug,
          "fields" => [%{"generatedAt" => ["foo"]}]
        })

      assert prim_nest["success"] == false
      assert hd(prim_nest["errors"])["type"] == "field_does_not_support_nesting"

      {200, unknown_nested, _} =
        rpc(%{
          "action" => "morning_view",
          "tenant" => seed.tenant_slug,
          "fields" => [%{"workOrders" => ["nope"]}]
        })

      assert unknown_nested["success"] == false
      assert [%{"type" => "unknown_map_field", "fields" => ["workOrders.nope"]}] = unknown_nested["errors"]

      {200, dup, _} =
        rpc(%{
          "action" => "morning_view",
          "tenant" => seed.tenant_slug,
          "fields" => ["generatedAt", "generatedAt"]
        })

      assert dup["success"] == false
      assert hd(dup["errors"])["type"] == "duplicate_field"
    end

    test "morning_view full fields selection returns live tenant aggregates and respects role redaction", %{seed: seed} do
      {200, res, _} =
        rpc(%{
          "action" => "morning_view",
          "tenant" => seed.tenant_slug,
          "fields" => @full_morning_view_fields
        })

      assert res["success"] == true
      data = res["data"]

      assert Map.keys(data) |> Enum.sort() ==
               ~w(collections generatedAt invoices onboarding procurement sla workOrders)

      assert data["workOrders"]["total"] == 2
      assert data["workOrders"]["byStatus"]["dispatched"] == 1
      assert data["workOrders"]["byStatus"]["inProgress"] == 1
      assert data["workOrders"]["byStatus"]["ingested"] == 0

      assert data["invoices"]["total"] == 2
      assert data["invoices"]["byStatus"]["sent"] == 1
      assert data["invoices"]["byStatus"]["draft"] == 1
      assert data["invoices"]["outstandingTotal"] == nil
      assert data["procurement"]["supplierCount"] == 1
      assert data["procurement"]["spendTotal"] == nil
      assert data["collections"]["outstandingCount"] == 1
      assert data["collections"]["outstandingTotal"] == nil
      assert data["onboarding"]["serviceProviderTotal"] == 2
      assert data["onboarding"]["bans"] == 1
      assert data["onboarding"]["doNotUse"] == 1
      assert data["sla"] == %{"openWithDeadline" => 2, "pastDeadline" => 1, "conformancePct" => "50.00"}

      # Money roles receive real decimal totals instead of nil
      {200, fin, _} =
        rpc(
          %{
            "action" => "morning_view",
            "tenant" => seed.tenant_slug,
            "fields" => @full_morning_view_fields
          },
          [{"x-actor-role", "finance_controller"}]
        )

      assert fin["data"]["invoices"]["outstandingTotal"] == "125.50"
      assert fin["data"]["invoices"]["overdueTotal"] == "0"
      assert fin["data"]["procurement"]["spendTotal"] == "50.00"
      assert fin["data"]["collections"]["outstandingTotal"] == "125.50"

      # Other tenant with zero deadlines gets conformancePct == nil
      {200, other, _} =
        rpc(%{
          "action" => "morning_view",
          "tenant" => seed.other_tenant_slug,
          "fields" => [%{"sla" => ["openWithDeadline", "pastDeadline", "conformancePct"]}]
        })

      assert other["data"] == %{
               "sla" => %{"openWithDeadline" => 0, "pastDeadline" => 0, "conformancePct" => nil}
             }
    end

    test "morning_view projects only the requested subset of nested fields", %{seed: seed} do
      {200, res, _} =
        rpc(%{
          "action" => "morning_view",
          "tenant" => seed.tenant_slug,
          "fields" => ["generatedAt", %{"workOrders" => ["total"]}]
        })

      assert res["success"] == true
      assert Map.keys(res["data"]) |> Enum.sort() == ["generatedAt", "workOrders"]
      assert res["data"]["workOrders"] == %{"total" => 2}
    end
  end

  describe "list_clients parity" do
    test "requires non-empty fields and rejects unknown fields", %{seed: seed} do
      {200, missing, _} = rpc(%{"action" => "list_clients", "tenant" => seed.tenant_slug})
      assert missing["success"] == false
      assert hd(missing["errors"])["type"] == "missing_required_parameter"

      {200, empty, _} = rpc(%{"action" => "list_clients", "tenant" => seed.tenant_slug, "fields" => []})
      assert empty["success"] == false
      assert hd(empty["errors"])["type"] == "empty_fields_array"

      {200, bad, _} =
        rpc(%{"action" => "list_clients", "tenant" => seed.tenant_slug, "fields" => ["id", "nope"]})

      assert bad["success"] == false
      assert hd(bad["errors"])["type"] == "unknown_field"
    end

    test "supports tenant isolation, filter, sort, pagination, and relationship projection", %{seed: seed} do
      {200, all, _} =
        rpc(%{
          "action" => "list_clients",
          "tenant" => seed.tenant_slug,
          "fields" => ["id", "name", "classification", %{"parentPrimaryClient" => ["id", "name"]}],
          "sort" => "name"
        })

      assert all["success"] == true
      assert Enum.map(all["data"], & &1["name"]) == ["Alpha Retail", "Zephyr Broker"]
      [alpha, zephyr] = all["data"]
      assert alpha["parentPrimaryClient"] == nil
      assert zephyr["parentPrimaryClient"]["name"] == "Alpha Retail"
      refute Enum.any?(all["data"], &(&1["id"] == seed.other_client_id))

      {200, filtered, _} =
        rpc(%{
          "action" => "list_clients",
          "tenant" => seed.tenant_slug,
          "fields" => ["name"],
          "filter" => %{"classification" => %{"eq" => "secondary_broker"}}
        })

      assert filtered["data"] == [%{"name" => "Zephyr Broker"}]

      {200, paged, _} =
        rpc(%{
          "action" => "list_clients",
          "tenant" => seed.tenant_slug,
          "fields" => ["name"],
          "sort" => "-name",
          "page" => %{"limit" => 1, "offset" => 0, "count" => true}
        })

      assert paged["data"] == %{
               "results" => [%{"name" => "Zephyr Broker"}],
               "hasMore" => true,
               "limit" => 1,
               "offset" => 0,
               "count" => 2,
               "type" => "offset"
             }
    end
  end

  describe "list_work_orders parity" do
    test "supports search, filter, sort, pagination, and child/parent relationships", %{seed: seed} do
      {200, missing, _} = rpc(%{"action" => "list_work_orders", "tenant" => seed.tenant_slug})
      assert hd(missing["errors"])["type"] == "missing_required_parameter"

      {200, searched, _} =
        rpc(%{
          "action" => "list_work_orders",
          "tenant" => seed.tenant_slug,
          "input" => %{"search" => "compressor"},
          "fields" => ["id", "externalWoNumber", "state", %{"childWorkOrders" => ["externalWoNumber"]}]
        })

      assert searched["success"] == true
      assert length(searched["data"]) == 1
      [wo] = searched["data"]
      assert wo["externalWoNumber"] == "EXT-1001"
      assert wo["childWorkOrders"] == [%{"externalWoNumber" => "EXT-1002"}]

      {200, paged, _} =
        rpc(%{
          "action" => "list_work_orders",
          "tenant" => seed.tenant_slug,
          "fields" => ["externalWoNumber", %{"parentWorkOrder" => ["externalWoNumber"]}],
          "sort" => "-workOrderNumber",
          "page" => %{"limit" => 1, "offset" => 0}
        })

      assert paged["data"]["hasMore"] == true
      assert paged["data"]["results"] == [
               %{"externalWoNumber" => "EXT-1002", "parentWorkOrder" => %{"externalWoNumber" => "EXT-1001"}}
             ]
    end
  end

  describe "check_in and check_out parity" do
    test "check_in enforces cross-tenant refusal, DL-4 mode/window, S-42 geofence, and optional fields", %{seed: seed} do
      # Cross-tenant visit returns not_found
      {200, cross, _} =
        rpc(%{
          "action" => "check_in",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_other_id,
          "input" => %{"internalCheckInAt" => seed.on_site_by}
        })

      assert cross["success"] == false
      assert hd(cross["errors"])["type"] == "not_found"

      # App mode requires externalCheckInAt
      {200, missing_ext, _} =
        rpc(%{
          "action" => "check_in",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_app_id,
          "input" => %{
            "internalCheckInAt" => seed.on_site_by,
            "arrivalLatitude" => 30.2672,
            "arrivalLongitude" => -97.7431
          }
        })

      assert missing_ext["success"] == false
      assert hd(missing_ext["errors"])["message"] == "EXTERNAL_CHECK_IN_REQUIRED_FOR_MODE"

      # External check-in outside expected window refuses
      {:ok, anchor, _} = DateTime.from_iso8601(seed.on_site_by)
      too_late = DateTime.add(anchor, 7200, :second) |> DateTime.to_iso8601()

      {200, outside_win, _} =
        rpc(%{
          "action" => "check_in",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_app_id,
          "input" => %{
            "internalCheckInAt" => seed.on_site_by,
            "externalCheckInAt" => too_late,
            "arrivalLatitude" => 30.2672,
            "arrivalLongitude" => -97.7431
          }
        })

      assert outside_win["success"] == false
      assert hd(outside_win["errors"])["message"] == "EXTERNAL_CHECK_IN_OUTSIDE_WINDOW"

      # Outside geofence refuses even if client attempts to pass geofenceVerified: true
      {200, out_fence, _} =
        rpc(%{
          "action" => "check_in",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_app_id,
          "input" => %{
            "internalCheckInAt" => seed.on_site_by,
            "externalCheckInAt" => seed.on_site_by,
            "arrivalLatitude" => 30.3000,
            "arrivalLongitude" => -97.7431,
            "geofenceVerified" => true
          }
        })

      assert out_fence["success"] == false
      assert hd(out_fence["errors"])["message"] == "GEOFENCE_OUT_OF_FENCE"

      # Unknown field refuses before mutating state
      {200, bad_field, _} =
        rpc(%{
          "action" => "check_in",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_app_id,
          "input" => %{
            "internalCheckInAt" => seed.on_site_by,
            "externalCheckInAt" => seed.on_site_by,
            "arrivalLatitude" => 30.2672,
            "arrivalLongitude" => -97.7431
          },
          "fields" => ["noSuchField"]
        })

      assert bad_field["success"] == false
      assert hd(bad_field["errors"])["type"] == "unknown_field"
      assert RpcContractProbe.snapshot().visits[seed.visit_app_id]["status"] == "en_route"

      # Valid check_in inside fence succeeds and sets geofenceVerified server-side
      {200, ok_ci, _} =
        rpc(%{
          "action" => "check_in",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_app_id,
          "input" => %{
            "internalCheckInAt" => seed.on_site_by,
            "externalCheckInAt" => seed.on_site_by,
            "arrivalLatitude" => 30.2672,
            "arrivalLongitude" => -97.7431
          },
          "fields" => ["id", "status", "geofenceVerified", %{"workOrder" => ["externalWoNumber"]}]
        })

      assert ok_ci["success"] == true
      assert ok_ci["data"] == %{
               "id" => seed.visit_app_id,
               "status" => "on_site",
               "geofenceVerified" => true,
               "workOrder" => %{"externalWoNumber" => "EXT-1001"}
             }

      # Manual mode on unfenced site allows internal-only check-in and omitted fields returns %{}
      {200, ok_manual, _} =
        rpc(%{
          "action" => "check_in",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_manual_id,
          "input" => %{"internalCheckInAt" => seed.on_site_by}
        })

      assert ok_manual == %{"success" => true, "data" => %{}}
      assert RpcContractProbe.snapshot().visits[seed.visit_manual_id]["status"] == "on_site"
      assert RpcContractProbe.snapshot().visits[seed.visit_manual_id]["geofenceVerified"] == false
    end

    test "check_out enforces FSM transition and DL-4 external budget", %{seed: seed} do
      # Cannot check_out directly from en_route
      {200, bad_fsm, _} =
        rpc(%{
          "action" => "check_out",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_app_id,
          "input" => %{"internalCheckOutAt" => seed.on_site_by}
        })

      assert bad_fsm["success"] == false
      assert hd(bad_fsm["errors"])["message"] == "INVALID_VISIT_STATUS_TRANSITION"

      # Move visit into checked-in -> in_progress state
      {:ok, t_in, _} = DateTime.from_iso8601(seed.on_site_by)
      t_over = DateTime.add(t_in, 120 * 60, :second) |> DateTime.to_iso8601()
      t_within = DateTime.add(t_in, 45 * 60, :second) |> DateTime.to_iso8601()

      visit =
        RpcContractProbe.snapshot().visits[seed.visit_app_id]
        |> Map.put("status", "in_progress")
        |> Map.put("externalCheckInAt", seed.on_site_by)

      RpcContractProbe.put_record(:visits, seed.visit_app_id, visit)

      # Exceeds 60-minute proposal budget
      {200, over_budget, _} =
        rpc(%{
          "action" => "check_out",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_app_id,
          "input" => %{
            "internalCheckOutAt" => t_over,
            "externalCheckOutAt" => t_over
          }
        })

      assert over_budget["success"] == false
      assert hd(over_budget["errors"])["message"] == "EXTERNAL_CHECK_OUT_BUDGET_EXCEEDED"

      # Within 60-minute external budget succeeds even if internalCheckOutAt is later
      {200, ok_co, _} =
        rpc(%{
          "action" => "check_out",
          "tenant" => seed.tenant_slug,
          "identity" => seed.visit_app_id,
          "input" => %{
            "internalCheckOutAt" => t_over,
            "externalCheckOutAt" => t_within
          },
          "fields" => ["id", "status", "internalCheckOutAt", "externalCheckOutAt"]
        })

      assert ok_co["success"] == true
      assert ok_co["data"]["status"] == "work_complete"
      assert ok_co["data"]["internalCheckOutAt"] == t_over
      assert ok_co["data"]["externalCheckOutAt"] == t_within
    end
  end

  test "RpcContractProbe.check/0 passes all contract probes in-process" do
    verdict = RpcContractProbe.check()
    assert verdict.name == :servengine_rpc_contract_probe
    assert verdict.pass == true
    assert verdict.checks == 8
    assert verdict.failures == []
  end
end
