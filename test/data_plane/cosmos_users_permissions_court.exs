# USERS500 court (v26.10.21): real wire-shape court for the Cosmos
# users/permissions surface (CosmosAuthzPlug over the real CosmosAuthz ETS
# store — no mocks, final-state assertions). Witnessed defect report: POST
# /dbs/{db}/users[/permissions] returned empty-body 500 on the recycled
# shared beam; PB-6 wire probes against the CURRENT shared beam (pid 85369)
# answered 201 on both creates, so the court fences the healthy shape:
#   1. create-user 201 with Azure record fields (_etag/_rid/_self/_ts/id)
#   2. duplicate create-user -> 409 UserConflict
#   3. create-permission 201 (Read + All modes) with resource + _self
#   4. typed errors: 400 missing id / bad permissionMode / missing resource,
#      404 unknown user, 405 wrong method
# A regression of any leg flips its assertion and exits 1.
defmodule Smalt.Test.DataPlane.CosmosUsersPermissionsCourtTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.CosmosAuthzPlug

  @created 201
  @ok 200

  setup_all do
    {:ok, _} = Application.ensure_all_started(:smalt)
    :ok
  end

  setup do
    %{db: "u500-db-" <> Integer.to_string(System.unique_integer([:positive]))}
  end

  defp req(method, path, body \\ nil) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    CosmosAuthzPlug.call(Plug.Conn.fetch_query_params(conn), [])
  end

  defp body(conn), do: Jason.decode!(conn.resp_body || "{}")

  test "create-user 201 + duplicate 409 + feed", %{db: db} do
    conn = req(:post, "/dbs/#{db}/users", %{"id" => "alice"})
    assert conn.status == @created
    rec = body(conn)
    assert rec["id"] == "alice"
    assert is_binary(rec["_etag"]) and is_binary(rec["_rid"]) and is_binary(rec["_self"])
    assert is_integer(rec["_ts"])

    conn = req(:post, "/dbs/#{db}/users", %{"id" => "alice"})
    assert conn.status == 409
    assert body(conn)["code"] == "UserConflict"

    conn = req(:get, "/dbs/#{db}/users")
    assert conn.status == @ok
    assert body(conn)["_count"] >= 1
  end

  test "create-permission 201 Read + All, typed errors", %{db: db} do
    assert req(:post, "/dbs/#{db}/users", %{"id" => "bob"}).status == @created

    for {mode, i} <- [{"Read", 1}, {"All", 2}] do
      conn =
        req(:post, "/dbs/#{db}/users/bob/permissions", %{
          "id" => "perm#{i}",
          "permissionMode" => mode,
          "resource" => "dbs/#{db}/colls/c1"
        })

      assert conn.status == @created
      rec = body(conn)
      assert rec["permissionMode"] == mode
      assert rec["resource"] == "dbs/#{db}/colls/c1"
      assert rec["_self"] =~ "/permissions/perm#{i}/"
    end

    bad_mode =
      req(:post, "/dbs/#{db}/users/bob/permissions", %{
        "id" => "p",
        "permissionMode" => "Bogus",
        "resource" => "dbs/#{db}/colls/c1"
      })

    assert bad_mode.status == 400
    assert body(bad_mode)["code"] == "BadRequest"

    # permissionMode defaults to "All" by design (cosmos_authz.ex)
    default_mode =
      req(:post, "/dbs/#{db}/users/bob/permissions", %{
        "id" => "p2",
        "resource" => "dbs/#{db}/colls/c1"
      })

    assert default_mode.status == @created
    assert body(default_mode)["permissionMode"] == "All"

    no_res =
      req(:post, "/dbs/#{db}/users/bob/permissions", %{
        "id" => "p5",
        "permissionMode" => "Read"
      })

    assert no_res.status == 400
    assert body(no_res)["code"] == "BadRequest"

    no_id =
      req(:post, "/dbs/#{db}/users/bob/permissions", %{"id" => "p3", "permissionMode" => "All"})

    assert no_id.status == 400

    no_user =
      req(:post, "/dbs/#{db}/users/nosuchuser/permissions", %{
        "id" => "p4",
        "permissionMode" => "Read",
        "resource" => "dbs/#{db}/colls/c1"
      })

    assert no_user.status == 404
    assert body(no_user)["code"] == "NotFound"

    assert req(:put, "/dbs/#{db}/users/bob").status == 405
  end
end
