defmodule Smalt.Integration.GraphSurfaceTest do
  # AZURE-FIDELITY lane 13 wire court: the Microsoft Graph v1.0 stub surface
  # (Smalt.Egress.GraphRoutes). Chicago discipline — the real router, the real
  # STS bearer verifier (Smalt.Auth.Bearer.verify_bearer/1), real STS-minted
  # tokens (Smalt.Auth.StsKey.mint/1). Assertions on actual wire responses:
  # documented-conformant {value, @odata.context} envelopes, the STS-minted
  # workspace-console SP present in the listing, documented Graph 401/404
  # error shapes. Never call counts.
  use ExUnit.Case, async: false

  @aud "https://management.azure.com"

  defp call(method, path, opts \\ []) do
    conn =
      Plug.Test.conn(method, path, nil)
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> then(fn c ->
        case opts[:auth] do
          nil -> c
          token -> Plug.Conn.put_req_header(c, "authorization", "Bearer #{token}")
        end
      end)

    Smalt.Egress.GraphRoutes.call(conn, [])
  end

  defp mint_valid_token do
    now = System.system_time(:second)

    claims = %{
      "aud" => @aud,
      "iss" => "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0",
      "exp" => now + 600,
      "nbf" => now,
      "tid" => "00000000-0000-0000-0000-000000000000"
    }

    {:ok, token} = Smalt.Auth.StsKey.mint(claims)
    token
  end

  defp err_body(conn) do
    %{"error" => err} = Jason.decode!(conn.resp_body)
    err
  end

  test "servicePrincipals listing: documented envelope, STS-minted workspace-console SP present" do
    conn = call(:get, "/v1.0/servicePrincipals", auth: mint_valid_token())

    assert conn.status == 200

    body = Jason.decode!(conn.resp_body)
    assert %{"@odata.context" => ctx, "value" => sps} = body
    assert ctx =~ "$metadata#servicePrincipals"

    console = Enum.find(sps, &(&1["displayName"] == "workspace-console"))
    assert console
    # The STS mint appid (issue_token/2) is the console SP's appId.
    assert console["appId"] == "00000000-0000-0000-0000-000000000000"
    assert console["servicePrincipalType"] == "Application"
    assert is_binary(console["id"])
  end

  test "servicePrincipals/{id}: single object 200, unknown id -> documented Graph 404" do
    list = call(:get, "/v1.0/servicePrincipals", auth: mint_valid_token())
    %{"value" => [%{"id" => id} | _]} = Jason.decode!(list.resp_body)

    one = call(:get, "/v1.0/servicePrincipals/#{id}", auth: mint_valid_token())
    assert one.status == 200

    body = Jason.decode!(one.resp_body)
    assert body["id"] == id
    assert body["displayName"] == "workspace-console"

    missing = call(:get, "/v1.0/servicePrincipals/ffffffff-ffff-ffff-ffff-ffffffffffff", auth: mint_valid_token())
    assert missing.status == 404
    err = err_body(missing)
    assert err["code"] == "NotFoundError"
    assert is_binary(err["message"])
    assert %{"request-id" => rid, "client-request-id" => _} = err["innerError"]
    assert is_binary(rid)
  end

  test "applications listing: documented envelope with the console app registration" do
    conn = call(:get, "/v1.0/applications", auth: mint_valid_token())

    assert conn.status == 200

    %{"@odata.context" => ctx, "value" => apps} = Jason.decode!(conn.resp_body)
    assert ctx =~ "$metadata#applications"

    app = Enum.find(apps, &(&1["displayName"] == "workspace-console"))
    assert app
    assert app["appId"] == "00000000-0000-0000-0000-000000000000"
    assert is_binary(app["id"])
    assert app["identifierUris"] == []
  end

  test "oauth2PermissionGrants listing: conformant empty envelope" do
    conn = call(:get, "/v1.0/oauth2PermissionGrants", auth: mint_valid_token())

    assert conn.status == 200

    %{"@odata.context" => ctx, "value" => grants} = Jason.decode!(conn.resp_body)
    assert ctx =~ "$metadata#oauth2PermissionGrants"
    assert grants == []
  end

  test "bad bearer -> documented Graph 401 shape (InvalidAuthenticationToken + innerError)" do
    conn = call(:get, "/v1.0/servicePrincipals", auth: "not.a.jwt")

    assert conn.status == 401
    err = err_body(conn)
    assert err["code"] == "InvalidAuthenticationToken"
    assert is_binary(err["message"])
    assert %{"request-id" => _, "client-request-id" => _} = err["innerError"]
  end

  test "missing bearer -> documented Graph 401 shape (AuthenticationFailed)" do
    conn = call(:get, "/v1.0/servicePrincipals")

    assert conn.status == 401
    err = err_body(conn)
    assert err["code"] == "AuthenticationFailed"
    assert err["message"] =~ "MissingBearerToken"
    assert %{"innerError" => _} = err
  end
end
