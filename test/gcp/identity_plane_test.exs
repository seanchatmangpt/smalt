defmodule Smalt.GCP.IdentityPlaneTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn
  alias Smalt.GCP.{Identity, IAM, Router}

  defp req(method, host, path, body \\ nil, headers \\ []) do
    {ct, b} =
      case body do
        nil -> {nil, nil}
        m when is_map(m) -> {"application/json", Jason.encode!(m)}
        s -> {"application/x-www-form-urlencoded", s}
      end

    c = conn(method, path, b) |> Map.put(:host, host)
    c = if ct, do: put_req_header(c, "content-type", ct), else: c
    c = Enum.reduce(headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    Router.call(c, [])
  end

  defp assertion(email, key, overrides \\ %{}) do
    now = System.os_time(:second)

    claims =
      Map.merge(
        %{"iss" => email, "scope" => "https://www.googleapis.com/auth/cloud-platform", "aud" => Identity.token_uri(), "iat" => now, "exp" => now + 3600},
        overrides
      )

    {_, jws} = JOSE.JWT.sign(key, %{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()
    jws
  end

  defp grant(a),
    do: req("POST", "oauth2.googleapis.com", "/token", URI.encode_query(%{"grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion" => a}))

  test "jwt-bearer grant mints a token that tokeninfo and IAM accept; forged is refused" do
    email = "sa#{System.unique_integer([:positive])}@p1.iam.gserviceaccount.com"
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    :ok = Identity.register_service_account(email, pem)

    ok = grant(assertion(email, key))
    assert ok.status == 200
    %{"access_token" => "ya29." <> _ = tok, "token_type" => "Bearer"} = Jason.decode!(ok.resp_body)

    ti = req("GET", "oauth2.googleapis.com", "/tokeninfo?access_token=" <> URI.encode_www_form(tok))
    assert ti.status == 200
    assert %{"email" => ^email} = Jason.decode!(ti.resp_body)

    forged = grant(assertion(email, JOSE.JWK.generate_key({:rsa, 2048})))
    assert forged.status == 400
    assert %{"error" => "invalid_grant"} = Jason.decode!(forged.resp_body)

    assert grant(assertion(email, key, %{"aud" => "https://evil"})).status == 400
    assert grant(assertion(email, key, %{"exp" => 1})).status == 400
  end

  test "metadata server demands the flavor header and serves token/email/identity" do
    h = "169.254.169.254"
    assert req("GET", h, "/computeMetadata/v1/instance/service-accounts/default/email").status == 403
    fl = [{"metadata-flavor", "Google"}]
    e = req("GET", h, "/computeMetadata/v1/instance/service-accounts/default/email", nil, fl)
    assert e.status == 200
    assert get_resp_header(e, "metadata-flavor") == ["Google"]
    t = req("GET", h, "/computeMetadata/v1/instance/service-accounts/default/token", nil, fl)
    %{"access_token" => tok} = Jason.decode!(t.resp_body)
    assert {:ok, %{"email" => em}} = Identity.verify(tok)
    assert em == e.resp_body
    assert req("GET", h, "/computeMetadata/v1/instance/service-accounts/default/identity", nil, fl).status == 400
    id = req("GET", h, "/computeMetadata/v1/instance/service-accounts/default/identity?audience=x", nil, fl)
    assert id.status == 200
  end

  test "IAM policy etag CAS, testIamPermissions, SA create, RM v3, and auth required" do
    proj = "proj#{System.unique_integer([:positive])}"
    IAM.register_project(proj)
    tok = Identity.mint("t@x.iam.gserviceaccount.com", "s").access_token
    auth = [{"authorization", "Bearer " <> tok}]
    crm = fn m, p, b -> req(m, "cloudresourcemanager.googleapis.com", p, b, auth) end

    assert req("GET", "cloudresourcemanager.googleapis.com", "/v3/projects/#{proj}").status == 401
    assert crm.("GET", "/v3/projects/#{proj}", nil).status == 200
    assert crm.("GET", "/v3/projects/nope", nil).status == 403
    assert %{"projects" => ps} = Jason.decode!(crm.("GET", "/v3/projects:search", nil).resp_body)
    assert Enum.any?(ps, &(&1["projectId"] == proj))

    p0 = Jason.decode!(crm.("POST", "/v3/projects/#{proj}:getIamPolicy", %{}).resp_body)
    pol = %{"etag" => p0["etag"], "bindings" => [%{"role" => "roles/viewer", "members" => ["user:a@x.com"]}]}
    s1 = crm.("POST", "/v3/projects/#{proj}:setIamPolicy", %{"policy" => pol})
    assert s1.status == 200
    new_etag = Jason.decode!(s1.resp_body)["etag"]
    assert new_etag != p0["etag"]

    stale = crm.("POST", "/v3/projects/#{proj}:setIamPolicy", %{"policy" => pol})
    assert stale.status == 409
    assert %{"error" => %{"status" => "ABORTED"}} = Jason.decode!(stale.resp_body)

    tp = crm.("POST", "/v3/projects/#{proj}:testIamPermissions?member=user:a@x.com", %{"permissions" => ["resourcemanager.projects.get", "iam.serviceAccounts.create"]})
    assert %{"permissions" => ["resourcemanager.projects.get"]} = Jason.decode!(tp.resp_body)

    c = req("POST", "iam.googleapis.com", "/v1/projects/#{proj}/serviceAccounts", %{"accountId" => "bot"}, auth)
    assert %{"email" => em} = Jason.decode!(c.resp_body)
    g = req("GET", "iam.googleapis.com", "/v1/projects/#{proj}/serviceAccounts/#{em}", nil, auth)
    assert g.status == 200
  end

  test "dialect routing and non-GCP passthrough" do
    assert Router.dialect("iam.googleapis.com:443") == :iam
    assert Router.dialect("management.azure.com") == :none
    c = conn(:get, "/x") |> Map.put(:host, "management.azure.com")
    refute Router.call(c, []).halted
  end
end
