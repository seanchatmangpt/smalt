defmodule Smalt.Integration.LroEnvelopeParityFenceTest do
  @moduledoc """
  WO-19 byte-parity fence (v26.10.31 lane 14): the BEAM faces must emit the
  envelope shape captured in
  posh/internal/dialect/azure/testdata/lro_golden.json — create face = 202 +
  azure-asyncoperation trio + JSON op body; delete face = 202 + location +
  retry-after ONLY, empty body (per-face table preserved, do NOT unify).
  The posh dialect reproduces these bytes byte-identically
  (lro_parity_test.go, doctor cross-exam 20/20). Together the two courts pin
  BEAM face <-> golden <-> posh dialect on both sides of the move.
  """

  use ExUnit.Case, async: false
  use Plug.Test

  alias Smalt.ArmGateway.Router

  @opts Router.init([])
  @sub "00000000-0000-0000-0000-000000000000"

  defp call(method, uri, body \\ "") do
    method
    |> Plug.Test.conn(uri, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call(@opts)
  end

  defp lro_headers(conn) do
    conn.resp_headers
    |> Enum.filter(fn {k, _} -> k in ["azure-asyncoperation", "location", "retry-after"] end)
    |> Map.new()
  end

  test "create face: 202 + trio + op-record body (storage account)" do
    latest = Smalt.Registry.latest_version("Microsoft.Storage/storageAccounts")

    conn =
      call(:put, "/subscriptions/#{@sub}/resourceGroups/parity-rg2/providers/Microsoft.Storage/storageAccounts/paritysa2?api-version=#{latest}", %{
        "location" => "eastus",
        "properties" => %{}
      })

    assert conn.status == 202
    hdrs = lro_headers(conn)
    assert hdrs["retry-after"] == "1"

    body = Jason.decode!(conn.resp_body)
    assert body["status"] == "InProgress"
    op_id = body["id"]
    assert op_id =~ "/operations/"
    authority = String.trim_trailing(hdrs["azure-asyncoperation"], op_id)
    assert authority != "" and not String.contains?(authority, "/subscriptions")

    assert hdrs["azure-asyncoperation"] == authority <> op_id
    assert hdrs["location"] == authority <> op_id

    assert MapSet.new(Map.keys(body)) ==
             MapSet.new(["delayMs", "endTime", "id", "name", "resourceId", "startTime", "startedAtMs", "status"])

    assert body["resourceId"] =~ "/providers/Microsoft.Storage/storageAccounts/paritysa2"
  end

  test "delete face: 202 + location + retry-after ONLY, empty body (RG delete)" do
    latest = Smalt.Registry.latest_version("Microsoft.Resources/resourceGroups")

    rg =
      call(:put, "/subscriptions/#{@sub}/resourcegroups/parity-rg3?api-version=2023-07-01", %{
        "location" => "delete-loc"
      })

    assert rg.status == 201

    conn = call(:delete, "/subscriptions/#{@sub}/resourcegroups/parity-rg3?api-version=2023-07-01")

    assert conn.status == 202
    hdrs = lro_headers(conn)
    assert hdrs["retry-after"] == "1"
    assert hdrs["location"]
    # Per-face law: no azure-asyncoperation on the delete face.
    refute hdrs["azure-asyncoperation"]
    assert conn.resp_body == ""
  end
end
