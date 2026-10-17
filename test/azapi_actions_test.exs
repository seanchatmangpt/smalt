defmodule Smalt.AzapiActionsTest do
  @moduledoc """
  Conformance fence for the azapi surface an external consumer's terraform uses — a mirror
  of the `Smalt.ArmErrorCorpusTest` pattern: every row drives a minimal
  Plug.Test request against the REAL `Smalt.ArmGateway.Router`, pins the
  actual {status, envelope shape}, and cites the router file:line of the
  call site it pins. api-versions come from `Smalt.Registry.latest_version/1`
  (registry-driven, not hand-copied).
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router
  alias Smalt.Registry
  alias Smalt.Store

  @opts Router.init([])
  @sub "sub-1"
  @rg "test-rg"

  setup do
    ensure_store()
    Store.clear()
    :ok
  end

  # ===========================================================================
  # (1) POST .../blobServices/default/containers/{c}/immutabilityPolicies/
  #     default/lock with If-Match -> 200
  # ===========================================================================

  describe "azapi lock action (immutability policy)" do
    @tag azapi: "lock"
    test "POST .../immutabilityPolicies/default/lock with matching If-Match -> 200 lock envelope" do
      # lib/smalt/arm_gateway/router.ex:1791 (POST .../providers/*glob)
      #   -> :876 handle_action ("lock" in @actions at :45)
      #   -> :936 action_envelope("lock")
      put_policy(immutability_policy_path())

      conn =
        conn(:post, lock_path())
        |> put_req_header("if-match", Router.lock_policy_etag(lock_request_path()))
        |> Router.call(@opts)

      assert conn.status == 200

      body = body(conn)
      # envelope id is conn.request_path (no query string) — router.ex:970
      assert body["id"] == lock_request_path()
      assert body["name"] == "default"
      assert body["type"] == "Microsoft.Authorization/locks"
      assert body["properties"]["level"] == "CanNotDelete"
      assert body["properties"]["notes"] == "smalt azapi action"
    end

    @tag azapi: "lock-if-match"
    test "POST lock without If-Match -> 412 PreconditionFailed (If-Match enforced)" do
      # Enforcement flip (2026-10-14, coordinator/lane-70 addition): the lock
      # action now requires If-Match; missing header -> inline 412 envelope
      # (sent via send_json, not send_arm_error, so the arm_error_corpus
      # pinned (status, code) set is unchanged).
      conn = conn(:post, lock_path()) |> Router.call(@opts)

      assert conn.status == 412
      assert body(conn)["error"]["code"] == "PreconditionFailed"
    end

    @tag azapi: "lock-if-match"
    test "POST lock with wrong (non-matching) If-Match -> 412 PreconditionFailed (value-verified)" do
      # Enforcement flip (2026-10-14, lane-20, WO V261014-20 decision (a)): the
      # lock action now VALUE-verifies If-Match against the policy etag
      # (Router.lock_policy_etag/1); `*` is honored as always-match (RFC 7232).
      # Same call site as above; header present but mismatched -> inline 412.
      conn =
        conn(:post, lock_path())
        |> put_req_header("if-match", "\"0xDEADBEEF00000001\"")
        |> Router.call(@opts)

      assert conn.status == 412
      assert body(conn)["error"]["code"] == "PreconditionFailed"
    end

    @tag azapi: "lock-if-match"
    test "POST lock with If-Match * -> 200 (always-match per RFC 7232)" do
      put_policy(immutability_policy_path())

      conn =
        conn(:post, lock_path())
        |> put_req_header("if-match", "*")
        |> Router.call(@opts)

      assert conn.status == 200
      assert body(conn)["properties"]["level"] == "CanNotDelete"
    end
  end

  # ===========================================================================
  # (2) POST .../containers/{c}/setLegalHold body {"tags": ["..."]} -> 2xx
  # ===========================================================================

  describe "azapi setLegalHold action" do
    @tag azapi: "setlegalhold"
    test "POST setLegalHold with tags body -> 200 legal-hold envelope" do
      # lib/smalt/arm_gateway/router.ex:1791 (resourceGroups POST *glob route)
      #   -> :876 handle_action -> :948 action_envelope("setlegalhold")
      conn =
        conn(:post, legal_hold_path(), %{"tags" => ["retention-7yr", "sox"]})
        |> Router.call(@opts)

      assert conn.status == 200

      body = body(conn)
      # envelope id is conn.request_path (no query string) — router.ex:984
      assert body["id"] == legal_hold_request_path()
      assert body["name"] == "c-1"
      assert body["type"] == "Microsoft.Storage/storageAccounts/blobServices/containers"
      assert body["properties"]["legalHoldState"] == "locked"
      # :952-:957 — the If-Match header is echoed into properties.ifMatch
      # (absent header -> empty list in the envelope)
      assert body["properties"]["ifMatch"] == []
    end

    @tag azapi: "setlegalhold"
    test "POST setLegalHold echoes a present If-Match into properties.ifMatch" do
      conn =
        conn(:post, legal_hold_path(), %{"tags" => ["retention-7yr"]})
        |> put_req_header("if-match", "W/\"datetime='2026-10-14T00%3A00%3A00Z'\"")
        |> Router.call(@opts)

      assert conn.status == 200

      assert body(conn)["properties"]["ifMatch"] == [
               "W/\"datetime='2026-10-14T00%3A00%3A00Z'\""
             ]
    end
  end

  # ===========================================================================
  # (3) PUT containers child @2023-05-01 -> 201 envelope
  # ===========================================================================

  describe "blob container child PUT" do
    @tag azapi: "container-put"
    test "PUT container child @latest containers api-version -> 201 record envelope" do
      # lib/smalt/arm_gateway/router.ex:1460 (containers child PUT route)
      #   -> :689 handle_child_put; version gate :986 via
      #      Registry.latest_version("Microsoft.Storage/storageAccounts/blobServices/containers")
      conn = put_container()

      assert conn.status == 201

      rec = body(conn)
      assert rec["id"] =~ "/storageAccounts/sa-1/blobServices/default/containers/c-1"
      assert rec["name"] == "c-1"
      assert rec["type"] == "Microsoft.Storage/storageAccounts/blobServices/containers"
      assert rec["location"] == "smalt-local"
      assert rec["properties"]["provisioningState"] == "Succeeded"
      assert rec["properties"]["publicAccess"] == "None"
    end

    @tag azapi: "container-put"
    test "re-PUT of the same container -> 200 (idempotent update, not 201)" do
      assert put_container().status == 201
      assert put_container().status == 200
    end

    @tag azapi: "container-put"
    test "PUT container with stale api-version -> 400 InvalidApiVersionParameter naming the latest" do
      # lib/smalt/arm_gateway/router.ex:1018-1038 (check_version mismatch)
      path = put_container_path() <> "?api-version=2019-01-01"

      conn = conn(:put, path, %{"location" => "smalt-local", "properties" => %{}}) |> Router.call(@opts)

      assert conn.status == 400
      assert body(conn)["error"]["code"] == "InvalidApiVersionParameter"
      assert body(conn)["error"]["message"] =~ "2023-05-01"
    end
  end

  # ===========================================================================
  # (4) PUT vaults/{v}/keys/{k} @2023-07-01 (SKR key with release policy)
  #     -> 201 + GET round-trip
  # ===========================================================================

  describe "Key Vault SKR key with release policy" do
    @tag azapi: "skr-key"
    test "PUT key with properties.release_policy -> 201, then GET round-trips the policy" do
      # lib/smalt/arm_gateway/router.ex:1388 (vault keys child PUT)
      #   -> :689 handle_child_put ("Microsoft.KeyVault/vaults/keys",
      #      DefaultShape, closed=false -> release_policy passes through)
      # GET round-trip: :717 handle_child_get
      conn =
        conn(:put, key_path(), %{
          "location" => "smalt-local",
          "properties" => %{
            "kty" => "RSA-HSM",
            "key_size" => 3072,
            "key_ops" => ["encrypt", "decrypt", "wrapKey", "unwrapKey"],
            "release_policy" => %{
              "data" =>
                "<condition>cnsentence1</condition>",
              "content_type" => "text/plain;charset=utf-8",
              "dataObjectEncoding" => "base64url"
            }
          }
        })
        |> Router.call(@opts)

      assert conn.status == 201

      rec = body(conn)
      assert rec["name"] == "skr-key-1"
      assert rec["type"] == "Microsoft.KeyVault/vaults/keys"
      assert rec["properties"]["provisioningState"] == "Succeeded"
      assert rec["properties"]["release_policy"]["content_type"] == "text/plain;charset=utf-8"
      assert is_binary(rec["properties"]["release_policy"]["data"])

      get_conn = conn(:get, key_path()) |> Router.call(@opts)
      assert get_conn.status == 200

      round_tripped = body(get_conn)
      assert round_tripped["id"] == rec["id"]
      assert round_tripped["properties"]["release_policy"] == rec["properties"]["release_policy"]
    end

    @tag azapi: "skr-key"
    test "key PUT gated on Microsoft.KeyVault/vaults/keys latest api-version" do
      # :986 check_version -> Registry.latest_version("Microsoft.KeyVault/vaults/keys")
      path = key_path() <> "?api-version=2021-04-01"

      conn =
        conn(:put, path, %{"location" => "smalt-local", "properties" => %{}}) |> Router.call(@opts)

      assert conn.status == 400
      assert body(conn)["error"]["message"] =~ "2023-07-01"
    end
  end

  # ===========================================================================
  # (5) PUT Microsoft.DevTestLab/schedules/{name} @2018-09-15 -> 201
  # ===========================================================================

  describe "DevTestLab schedules" do
    @tag azapi: "devtest-schedule"
    test "PUT schedule via generic route @2018-09-15 -> 201" do
      # lib/smalt/arm_gateway/router.ex:1798 (generic provider PUT)
      #   -> :611 handle_resource_put; admitted via Registry :27,
      #      api-version 2018-09-15 (Registry :110)
      conn =
        conn(:put, schedule_path(), %{
          "location" => "smalt-local",
          "properties" => %{
            "status" => "Enabled",
            "taskType" => "LabVmsShutdownTask",
            "dailyRecurrence" => %{"time" => "19:00"},
            "timeZoneId" => "Pacific Standard Time"
          }
        })
        |> Router.call(@opts)

      assert conn.status == 201

      rec = body(conn)
      assert rec["name"] == "shutdown-19h"
      assert rec["type"] == "Microsoft.DevTestLab/schedules"
      assert rec["properties"]["provisioningState"] == "Succeeded"
      assert rec["properties"]["taskType"] == "LabVmsShutdownTask"
    end
  end

  # ===========================================================================
  # (6) roleAssignments PUT at RG scope -> 201 + DELETE
  # ===========================================================================

  describe "role assignments at RG scope" do
    @tag azapi: "role-assignment"
    test "PUT roleAssignment at RG scope -> 201, then DELETE -> 200" do
      # lib/smalt/arm_gateway/router.ex:1798 (generic PUT),
      # :1829 (generic DELETE); admitted via Registry :20,
      # api-version 2022-04-01 (Registry :103)
      conn =
        conn(:put, role_assignment_path(), %{
          "location" => "smalt-local",
          "properties" => %{
            "roleDefinitionId" =>
              "/subscriptions/#{@sub}/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c",
            "principalId" => "00000000-0000-0000-0000-000000000001",
            "principalType" => "ServicePrincipal"
          }
        })
        |> Router.call(@opts)

      assert conn.status == 201

      rec = body(conn)
      assert rec["name"] == "11111111-2222-3333-4444-555555555555"
      assert rec["type"] == "Microsoft.Authorization/roleAssignments"
      assert rec["properties"]["principalId"] == "00000000-0000-0000-0000-000000000001"

      del_conn = conn(:delete, role_assignment_path()) |> Router.call(@opts)
      assert del_conn.status == 200
    end
  end

  # ===========================================================================
  # (7) diagnosticSettings PUT on a resource id -> 201
  # ===========================================================================

  describe "diagnostic settings" do
    @tag azapi: "diagnostic-settings"
    test "PUT diagnosticSettings (RG-scoped) -> 201" do
      # lib/smalt/arm_gateway/router.ex:1798 (generic provider PUT
      # :provider_ns/:resource_type/:resource_name); admitted via Registry :33,
      # api-version 2021-05-01-preview (Registry :116)
      path = diagnostic_settings_path()

      conn =
        conn(:put, path, %{
          "location" => "smalt-local",
          "properties" => %{
            "workspaceId" => "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.OperationalInsights/workspaces/ws-1",
            "logs" => [%{"category" => "StorageRead", "enabled" => true}],
            "metrics" => [%{"category" => "Transaction", "enabled" => true}]
          }
        })
        |> Router.call(@opts)

      assert conn.status == 201

      rec = body(conn)
      assert rec["name"] == "diag-1"
      assert rec["type"] == "Microsoft.Insights/diagnosticSettings"
      refute rec["properties"]["workspaceId"] =~ "Microsoft.Insights/diagnosticSettings"
      assert rec["properties"]["workspaceId"] =~ "Microsoft.OperationalInsights/workspaces/ws-1"
    end

    @tag azapi: "diagnostic-settings"
    test "PUT diagnosticSettings nested under a resource id -> 201 (nested-provider route landed)" do
      # The azurerm_monitor_diagnostic_setting wire form is
      #   {resourceId}/providers/Microsoft.Insights/diagnosticSettings/{name}
      # (7 segments after providers/). The nested-provider PUT route has
      # landed in the router: the PUT now creates the settings record (201).
      # Contract drift from the previously pinned 404 RouteNotFound gap row.
      path =
        "#{storage_account_path()}/providers/Microsoft.Insights/diagnosticSettings/diag-1?api-version=#{Registry.latest_version("Microsoft.Insights/diagnosticSettings")}"

      conn =
        conn(:put, path, %{
          "location" => "smalt-local",
          "properties" => %{"logs" => [%{"category" => "StorageRead", "enabled" => true}]}
        })
        |> Router.call(@opts)

      assert conn.status == 201
      assert body(conn)["name"] == "diag-1"
    end
  end

  # ===========================================================================
  # Registry seam: the versions this fence depends on are the projected ones
  # ===========================================================================

  test "404 ActionNotFound precedence: unknown action fires BEFORE the api-version gate (no api-version still 404, not 400)" do
    # lib/smalt/arm_gateway/router.ex handle_action: @actions membership is
    # checked before check_api_version — an unknown action returns
    # ActionNotFound regardless of api-version presence. Pinned precedence.
    conn =
      conn(
        :post,
        "#{container_base()}/c-1/notanaction"
      )
      |> Router.call(@opts)

    assert {404, "ActionNotFound"} = {conn.status, body(conn)["error"]["code"]}
  end

  test "fence api-versions match Smalt.Registry.latest_version (drift falsifier)" do
    # lib/smalt/registry.ex:100-139 (@api_versions)
    assert Registry.latest_version("Microsoft.Storage/storageAccounts/blobServices/containers") == "2023-05-01"
    assert Registry.latest_version("Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies") ==
             "2023-05-01"
    assert Registry.latest_version("Microsoft.KeyVault/vaults/keys") == "2023-07-01"
    assert Registry.latest_version("Microsoft.DevTestLab/schedules") == "2018-09-15"
    assert Registry.latest_version("Microsoft.Authorization/roleAssignments") == "2022-04-01"
    assert Registry.latest_version("Microsoft.Insights/diagnosticSettings") == "2021-05-01-preview"
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp container_base do
    "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/sa-1/blobServices/default/containers"
  end

  defp put_container_path, do: "#{container_base()}/c-1?api-version=#{Registry.latest_version("Microsoft.Storage/storageAccounts/blobServices/containers")}"
  defp lock_path, do: "#{container_base()}/c-1/immutabilityPolicies/default/lock?api-version=2023-05-01"
  defp lock_request_path, do: lock_path() |> String.split("?") |> List.first()

  defp legal_hold_path, do: "#{container_base()}/c-1/setLegalHold?api-version=2023-05-01"

  defp legal_hold_request_path, do: legal_hold_path() |> String.split("?") |> List.first()

  defp diagnostic_settings_path do
    type = "Microsoft.Insights/diagnosticSettings"

    "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Insights/diagnosticSettings/diag-1?api-version=#{Registry.latest_version(type)}"
  end

  defp key_path,
    do:
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.KeyVault/vaults/kv-1/keys/skr-key-1?api-version=#{Registry.latest_version("Microsoft.KeyVault/vaults/keys")}"

  defp schedule_path,
    do:
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.DevTestLab/schedules/shutdown-19h?api-version=#{Registry.latest_version("Microsoft.DevTestLab/schedules")}"

  defp role_assignment_path,
    do:
      "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Authorization/roleAssignments/11111111-2222-3333-4444-555555555555?api-version=#{Registry.latest_version("Microsoft.Authorization/roleAssignments")}"

  defp storage_account_path,
    do: "/subscriptions/#{@sub}/resourceGroups/#{@rg}/providers/Microsoft.Storage/storageAccounts/sa-1"

  defp put_container do
    conn(:put, put_container_path(), %{
      "location" => "smalt-local",
      "properties" => %{"publicAccess" => "None"}
    })
    |> Router.call(@opts)
  end

  # Seed an immutability policy so the lock action targets an existing policy.
  defp put_policy(path) do
    conn(:put, path, %{"location" => "smalt-local", "properties" => %{"immutabilityPeriodSinceCreationInDays" => 30}})
    |> Router.call(@opts)
    |> tap(&assert(&1.status == 201))
  end

  defp immutability_policy_path do
    type = "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies"

    "#{container_base()}/c-1/immutabilityPolicies/ip-1?api-version=#{Registry.latest_version(type)}"
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  # The router is stateless over public ETS; the Store GenServer is started
  # defensively so this file also runs under `mix test --no-start` when the
  # shared tree's application start is blocked by a concurrent lane.
  defp ensure_store do
    SmaltTest.Lifecycle.ensure_store_up()

    :ok
  end
end
