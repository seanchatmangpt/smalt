defmodule SmaltEgressRouterTest do
  use ExUnit.Case
  use Plug.Test

  alias Smalt.EgressRouter
  alias Smalt.Store

  @opts EgressRouter.init([])

  setup do
    ensure_store()
    Store.clear()
    :ok
  end

  # The Store GenServer is started defensively so this file also runs under
  # `mix test --no-start` when the shared tree's application start is blocked
  # by a concurrent lane (EventHubs listener double-start).
  defp ensure_store do
    SmaltTest.Lifecycle.ensure_store_up()

    :ok
  end

  test "Cosmos DB NoSQL Optimistic Concurrency with ETags" do
    db = "test-db"
    coll = "test-coll"
    path = "/dbs/#{db}/colls/#{coll}/docs"

    # Create document
    create_conn = conn(:post, path, %{"id" => "item-1", "name" => "sovereign", "count" => 1})
    create_conn = EgressRouter.call(create_conn, @opts)
    assert create_conn.status == 201

    created_doc = Jason.decode!(create_conn.resp_body)
    etag = created_doc["_etag"]
    assert is_binary(etag)

    # Valid update with matching If-Match header
    update_conn =
      conn(:put, "#{path}/item-1", %{"count" => 2})
      |> put_req_header("if-match", etag)
    update_conn = EgressRouter.call(update_conn, @opts)
    assert update_conn.status == 200

    updated_doc = Jason.decode!(update_conn.resp_body)
    new_etag = updated_doc["_etag"]
    assert new_etag != etag

    # Stale update with old ETag -> HTTP 412 Precondition Failed
    stale_conn =
      conn(:put, "#{path}/item-1", %{"count" => 3})
      |> put_req_header("if-match", etag)
    stale_conn = EgressRouter.call(stale_conn, @opts)
    assert stale_conn.status == 412
    assert Jason.decode!(stale_conn.resp_body)["code"] == "PreconditionFailed"
  end

  # kv_challenge_guard requires a well-formed Bearer header in both auth
  # modes (SDK challenge emulation); attach one unless the conn already
  # carries its own authorization header (R54 pattern). SHIM-COURT-compatible:
  # presence-only check. Legacy SKR requests (x-ms-compliance-status raw
  # header) are exempt — the challenge guard exempts them too, and the SKR
  # release admission honors the legacy header only on a tokenless request.
  defp call(conn) do
    cond do
      List.keyfind(conn.req_headers, "authorization", 0) -> conn
      List.keyfind(conn.req_headers, "x-ms-compliance-status", 0) -> conn
      true -> put_req_header(conn, "authorization", "Bearer test-token")
    end
  end

  test "Key Vault Managed HSM & Attestation-Gated Secure Key Release (SKR)" do
    key_name = "exportable-sec-key"
    create_path = "/keys/#{key_name}/create"
    release_path = "/keys/#{key_name}/release?api-version=7.4"

    # Create exportable key with release policy
    create_conn =
      conn(:post, create_path, %{
      "kty" => "RSA-HSM",
      "key_size" => 2048,
      "release_policy" => %{"claim" => "azure-compliant-cvm"}
    })
    create_conn = EgressRouter.call(call(create_conn), @opts)
    assert create_conn.status == 200

    # Unauthorized release attempt without attestation -> HTTP 403 Forbidden
    # (post-auth: the well-formed Bearer passes the challenge guard; the
    # missing attestation is what is refused).
    unauth_conn = call(conn(:post, release_path, %{}))
    unauth_conn = EgressRouter.call(unauth_conn, @opts)
    assert unauth_conn.status == 403
    assert Jason.decode!(unauth_conn.resp_body)["error"]["code"] == "UnauthorizedAttestation"

    # Authorized release with compliant attestation token -> HTTP 200
    auth_conn =
      conn(:post, release_path, %{})
      |> put_req_header("x-ms-compliance-status", "azure-compliant-cvm")
      |> call()
    auth_conn = EgressRouter.call(auth_conn, @opts)
    assert auth_conn.status == 200
    res = Jason.decode!(auth_conn.resp_body)
    assert res["status"] == "Released"
    assert is_binary(res["value"])
  end

  # ===========================================================================
  # Data-plane precondition + ingestion contracts (lane-owned extensions)
  # ===========================================================================

  test "Cosmos DELETE with stale If-Match -> 412 PreconditionFailed" do
    alias Smalt.DataPlane.Cosmos

    # Create the doc through the real egress route
    path = "/dbs/stale-db/colls/stale-coll/docs"
    create_conn = EgressRouter.call(conn(:post, path, %{"id" => "doc-1", "v" => 1}), @opts)
    assert create_conn.status == 201

    # DELETE with a stale If-Match is refused with 412 (note: the module
    # returns precondition failures as {:ok, 412, headers, error-body})
    result = Cosmos.delete_doc("stale-db", "stale-coll", "doc-1", %{"if-match" => "\"stale\""})
    assert {:ok, 412, _headers, %{"code" => "PreconditionFailed"}} = result

    # DELETE with the current etag succeeds
    {:ok, _status, _headers, doc} = Cosmos.get_doc("stale-db", "stale-coll", "doc-1", %{})
    current_etag = doc["_etag"]

    assert {:ok, 204, _headers, ""} =
             Cosmos.delete_doc("stale-db", "stale-coll", "doc-1", %{"if-match" => current_etag})

    # A bare DELETE (no If-Match) after re-create is unconditional -> 204
    recreate_conn = EgressRouter.call(conn(:post, path, %{"id" => "doc-1", "v" => 2}), @opts)
    assert recreate_conn.status == 201

    assert {:ok, 204, _headers, ""} = Cosmos.delete_doc("stale-db", "stale-coll", "doc-1", %{})
  end

  # Lane-11 conditional-header module must be compiled for this contract;
  # ConditionalHeaders is compiled unconditionally on HEAD (wired into
  # blob_storage.ex); the historical Code.ensure_loaded? scaffold with a
  # body-:ok skip is dead — the test runs unconditionally.
  test "blob PUT with stale If-Match -> 412 precondition failure" do
    alias Smalt.DataPlane.BlobStorage

    {:ok, _} = BlobStorage.create_container("acct", "cond", %{"immutable" => false})

    {:ok, blob} = BlobStorage.put_blob("acct", "cond", "b1", "v1", %{})
    etag = blob["etag"]
    assert is_binary(etag)

    # Stale If-Match on overwrite is refused
    assert {:error, :precondition_failed, msg} =
             BlobStorage.put_blob("acct", "cond", "b1", "v2", %{"if-match" => "\"stale\""})

    assert is_binary(msg)

    # Matching If-Match proceeds
    assert {:ok, _} = BlobStorage.put_blob("acct", "cond", "b1", "v2", %{"if-match" => etag})
  end

  test "Sentinel ingest then empty query -> rows []" do
    alias Smalt.DataPlane.Sentinel

    assert Code.ensure_loaded?(Sentinel)

    # Real Log Analytics contract (C7-gaps): ingest returns 204 empty.
    {:ok, 204, body} = Sentinel.ingest("dcr-1", "stream-1", [%{"msg" => "hello"}], "2023-01-01")
    assert body == ""

    {:ok, 200, result} = Sentinel.query("empty-workspace", %{"query" => "MyTable | take 10"})
    table = Enum.at(result["tables"], 0)
    assert table["name"] == "PrimaryResult"
    assert table["rows"] == []
  end
end
