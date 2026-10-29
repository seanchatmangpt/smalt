# Integration-tier witness: the microsoft.insights/diagnosticSettings
# surface (CONVERGENCE lane V12).
#
# Chicago discipline: the real heir'd ETS store, real validation law, real
# wire rendering — no mocks. Every claim in this file is exercised against
# the live module in-process.

defmodule Smalt.Internal.DiagnosticSettingsTest do
  use ExUnit.Case, async: false

  alias Smalt.ArmGateway.DiagnosticSettings

  @sub_scope "/subscriptions/sub-diag"
  @rg_scope "/subscriptions/sub-diag/resourceGroups/rg-diag"
  @res_scope "/subscriptions/sub-diag/resourceGroups/rg-diag/providers/Microsoft.Storage/storageAccounts/stgdiag"

  test "put -> get round-trip echoes the submitted properties at the ARM shape" do
    name = "export-la-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    body = %{
      "workspaceId" =>
        "/subscriptions/sub-diag/resourceGroups/rg-diag/providers/Microsoft.OperationalInsights/workspaces/ws-heartbeat",
      "logs" => [
        %{"category" => "StorageRead", "enabled" => true},
        %{"category" => "StorageWrite", "enabled" => false}
      ],
      "metrics" => [%{"category" => "Transaction", "enabled" => true}]
    }

    assert {:ok, put_wire} = DiagnosticSettings.put(@res_scope, name, body)

    assert put_wire["id"] ==
             "#{@res_scope}/providers/microsoft.insights/diagnosticSettings/#{name}"

    assert put_wire["name"] == name
    assert put_wire["type"] == "Microsoft.Insights/diagnosticSettings"
    assert put_wire["location"] == "global"
    assert put_wire["properties"]["workspaceId"] == body["workspaceId"]
    assert put_wire["properties"]["logs"] == body["logs"]

    assert {:ok, get_wire} = DiagnosticSettings.get(@res_scope, name)
    assert get_wire == put_wire
  end

  test "list is per-scope: sibling scopes do not leak into each other" do
    base = "export-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    {:ok, _} = DiagnosticSettings.put(@sub_scope, base <> "-sub", %{"workspaceId" => "w1"})
    {:ok, _} = DiagnosticSettings.put(@rg_scope, base <> "-rg", %{"storageAccountId" => "s1"})

    sub_names =
      DiagnosticSettings.list(@sub_scope) |> Enum.map(& &1["name"])

    rg_names = DiagnosticSettings.list(@rg_scope) |> Enum.map(& &1["name"])

    assert base <> "-sub" in sub_names
    refute base <> "-rg" in sub_names
    assert base <> "-rg" in rg_names
    refute base <> "-sub" in rg_names
  end

  test "delete removes the setting; a second delete is a typed 404" do
    name = "export-del-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    {:ok, _} = DiagnosticSettings.put(@rg_scope, name, %{"workspaceId" => "w2"})

    assert :ok = DiagnosticSettings.delete(@rg_scope, name)
    assert {:error, :not_found} = DiagnosticSettings.get(@rg_scope, name)
    assert {:error, :not_found} = DiagnosticSettings.delete(@rg_scope, name)
  end

  test "get on an unknown setting is a typed 404" do
    assert {:error, :not_found} =
             DiagnosticSettings.get(@sub_scope, "never-existed-#{System.unique_integer()}")
  end

  test "put is replace-all: an omitted destination is cleared, not merged" do
    name = "export-rep-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    {:ok, _} = DiagnosticSettings.put(@rg_scope, name, %{"workspaceId" => "w3"})

    {:ok, replaced} =
      DiagnosticSettings.put(@rg_scope, name, %{"storageAccountId" => "s3"})

    assert replaced["properties"] == %{"storageAccountId" => "s3"}
    assert {:ok, get_wire} = DiagnosticSettings.get(@rg_scope, name)
    assert get_wire["properties"] == %{"storageAccountId" => "s3"}
  end

  test "validation: no destination refuses typed; bad category shapes refuse typed" do
    name = "export-bad-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"

    assert {:error, :no_destination} = DiagnosticSettings.put(@rg_scope, name, %{"logs" => []})
    assert {:error, :bad_body} = DiagnosticSettings.put(@rg_scope, name, "not-a-map")

    assert {:error, :bad_logs} =
             DiagnosticSettings.put(@rg_scope, name, %{
               "workspaceId" => "w4",
               "logs" => [%{"enabled" => true}]
             })

    assert {:error, :bad_metrics} =
             DiagnosticSettings.put(@rg_scope, name, %{
               "workspaceId" => "w4",
               "metrics" => "Transaction"
             })

    # A refused PUT never lands a row.
    assert {:error, :not_found} = DiagnosticSettings.get(@rg_scope, name)
  end
end
