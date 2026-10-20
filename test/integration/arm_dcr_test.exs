# Integration-tier witness: ARM data collection rules family (v26.10.19 w4-lane).
#
# Chicago discipline: real Store rows, real in-process dispatch through
# Smalt.ArmGateway.Router, real ingest through the real EgressRouter ->
# Sentinel.ingest/4 path. No mocks. The sentinel DCR store shape
# (data_plane/sentinel.ex) is consumed read-only — the ARM family seeds and
# clears the exact `{:dcr_created, name}` marker + stream-meta prefix the
# ingest fence (`:sentinel_dcr_strict`) reads.

defmodule Smalt.Internal.ArmDcrTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.ArmGateway.Router

  @api_version "2021-05-01-preview"
  @rg "/subscriptions/sub-dcr/resourceGroups/rg-dcr"
  @dcr_type "Microsoft.Insights/dataCollectionRules"

  @created 201
  @ok 200
  @not_found 404

  setup do
    # The strict fence is flipped INSIDE the witness tests; guarantee the
    # default (implicit-create) posture is restored even on failure.
    on_exit(fn ->
      Application.put_env(:smalt, :sentinel_dcr_strict, false)
    end)

    :ok
  end

  # b11 enforce witness: PUT DCR 201 -> GET 200 echo -> sentinel ingest against
  # the DCR-id works (strict fence admits the ARM-created rule) -> DELETE ->
  # strict-mode ingest typed-refuses the unknown DCR (404 DCRNotFound).
  # Context: solo (integration tier, in-process dispatch).
  test "b11 enforce: PUT -> GET echo -> strict ingest admits -> DELETE -> strict ingest refuses" do
    Application.put_env(:smalt, :sentinel_dcr_strict, true)
    name = "dcr-witness-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    path = "#{@rg}/providers/#{@dcr_type}/#{name}?api-version=#{@api_version}"

    put_conn = dcr_req(:put, path, dcr_body())

    assert put_conn.status == @created

    put_body = Jason.decode!(put_conn.resp_body)
    assert put_body["name"] == name
    assert put_body["type"] == @dcr_type
    assert put_body["properties"]["provisioningState"] == "Succeeded"

    get_conn = dcr_req(:get, path)

    assert get_conn.status == @ok

    get_body = Jason.decode!(get_conn.resp_body)

    assert get_body["properties"]["streams"] == put_body["properties"]["streams"]
    assert get_body["properties"]["destinations"] == put_body["properties"]["destinations"]

    # Sentinel ingest against the ARM-created DCR-id: the strict fence admits
    # via the {:dcr_created, name} marker the PUT seeded. Real ingest answers
    # 204 No Content — the router seam mirrors it (200-class success).
    # Ingest rides the real data-plane surface (EgressRouter, 8443 twin
    # prefix) — the ARM router does not mount the stream ingest route.
    ingest_conn =
      egress_req(:post,
        "/dataCollectionRules/#{name}/streams/Custom-Logs?api-version=2023-01-01",
        [%{"msg" => "dcr-witness"}]
      )

    # Real Logs Ingestion answers 204 No Content.
    assert ingest_conn.status == 204

    # DELETE removes the rule; strict-mode ingest then typed-refuses.
    del_conn = dcr_req(:delete, path)

    assert del_conn.status == @ok

    missing = dcr_req(:get, path)

    assert missing.status == @not_found
    assert Jason.decode!(missing.resp_body)["error"]["code"] == "ResourceNotFound"

    refused =
      egress_req(:post,
        "/dataCollectionRules/#{name}/streams/Custom-Logs?api-version=2023-01-01",
        [%{"msg" => "post-delete"}]
      )

    assert refused.status == @not_found
    assert Jason.decode!(refused.resp_body)["error"]["code"] == "DCRNotFound"
  end

  test "PUT is idempotent (re-PUT 200) and LIST surfaces the rule" do
    name = "dcr-list-#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    path = "#{@rg}/providers/#{@dcr_type}/#{name}?api-version=#{@api_version}"

    assert dcr_req(:put, path, dcr_body()).status == @created
    assert dcr_req(:put, path, dcr_body()).status == @ok

    list_conn = dcr_req(:get, "#{@rg}/providers/#{@dcr_type}?api-version=#{@api_version}")

    assert list_conn.status == @ok

    names =
      list_conn.resp_body
      |> Jason.decode!()
      |> Map.get("value", [])
      |> Enum.map(& &1["name"])

    assert name in names
  end

  test "missing api-version -> typed MissingApiVersionParameter" do
    put_conn = dcr_req(:put, "#{@rg}/providers/#{@dcr_type}/dcr-noav", %{"location" => "eastus"})

    assert put_conn.status == 400

    assert Jason.decode!(put_conn.resp_body)["error"]["code"] ==
             "MissingApiVersionParameter"
  end

  # -- helpers ------------------------------------------------------------------

  defp dcr_req(method, path, body \\ nil) do
    dispatch(Router, method, path, body)
  end

  defp egress_req(method, path, body) do
    dispatch(Smalt.EgressRouter, method, path, body)
  end

  defp dispatch(router, method, path, body) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    router.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp dcr_body do
    %{
      "location" => "eastus",
      "properties" => %{
        "streams" => ["Custom-Logs"],
        "destinations" => %{"workspace" => "ws-dcr"}
      }
    }
  end
end
