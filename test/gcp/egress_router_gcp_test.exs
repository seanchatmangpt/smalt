defmodule Smalt.GCP.EgressRouterGcpTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn

  alias Smalt.EgressRouter
  alias Smalt.GCP.{IAM, Identity}

  defmodule Handlers do
    def echo(data), do: {:ok, %{"echo" => data}}
    def fail(_data), do: {:error, :bad_input}
  end

  @handler_mod "Elixir.Smalt.GCP.EgressRouterGcpTest.Handlers"

  defp uniq, do: "eg#{System.unique_integer([:positive])}"

  defp call_router(method, host, path, body \\ nil, headers \\ []) do
    {ct, raw} =
      case body do
        nil -> {nil, nil}
        m when is_map(m) -> {"application/json", Jason.encode!(m)}
        s when is_binary(s) -> {"application/x-www-form-urlencoded", s}
      end

    c = conn(method, path, raw) |> Map.put(:host, host)
    c = if ct, do: put_req_header(c, "content-type", ct), else: c
    c = Enum.reduce(headers, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    EgressRouter.call(c, EgressRouter.init([]))
  end

  defp auth_header do
    tok = Identity.mint("tester@smalt-local.iam.gserviceaccount.com", "https://www.googleapis.com/auth/cloud-platform").access_token
    [{"authorization", "Bearer " <> tok}]
  end

  test "identity routes (oauth2 + metadata) via EgressRouter preserve fail-closed posture" do
    email = "sa-#{uniq()}@p1.iam.gserviceaccount.com"
    key = JOSE.JWK.generate_key({:rsa, 2048})
    {_, pem} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_pem()
    :ok = Identity.register_service_account(email, pem)

    now = System.os_time(:second)

    claims = %{
      "iss" => email,
      "scope" => "https://www.googleapis.com/auth/cloud-platform",
      "aud" => Identity.token_uri(),
      "iat" => now,
      "exp" => now + 3600
    }

    {_, assertion} = JOSE.JWT.sign(key, %{"alg" => "RS256"}, claims) |> JOSE.JWS.compact()

    tok_conn =
      call_router(
        "POST",
        "oauth2.googleapis.com",
        "/token",
        URI.encode_query(%{
          "grant_type" => "urn:ietf:params:oauth:grant-type:jwt-bearer",
          "assertion" => assertion
        })
      )

    assert tok_conn.status == 200
    %{"access_token" => "ya29." <> _ = tok} = Jason.decode!(tok_conn.resp_body)

    ti_conn = call_router("GET", "oauth2.googleapis.com", "/tokeninfo?access_token=" <> URI.encode_www_form(tok))
    assert ti_conn.status == 200
    assert %{"email" => ^email} = Jason.decode!(ti_conn.resp_body)

    # Metadata server fails closed without Metadata-Flavor: Google
    no_flavor = call_router("GET", "169.254.169.254", "/computeMetadata/v1/instance/service-accounts/default/token")
    assert no_flavor.status == 403

    meta_conn =
      call_router(
        "GET",
        "169.254.169.254",
        "/computeMetadata/v1/instance/service-accounts/default/token",
        nil,
        [{"metadata-flavor", "Google"}]
      )

    assert meta_conn.status == 200
    assert %{"access_token" => "ya29." <> _} = Jason.decode!(meta_conn.resp_body)

    # Path-based metadata route on non-GCP host
    proj_conn =
      call_router("GET", "localhost", "/computeMetadata/v1/project/project-id", nil, [
        {"metadata-flavor", "Google"}
      ])

    assert proj_conn.status == 200
  end

  test "iam and crm routes via EgressRouter enforce Bearer auth fail-closed" do
    p = uniq()
    IAM.register_project(p)
    auth = auth_header()
    bad_auth = [{"authorization", "Bearer ya29.forged"}]

    assert call_router("GET", "iam.googleapis.com", "/v1/projects/#{p}/serviceAccounts").status == 401
    assert call_router("GET", "iam.googleapis.com", "/v1/projects/#{p}/serviceAccounts", nil, bad_auth).status == 401
    assert call_router("GET", "cloudresourcemanager.googleapis.com", "/v3/projects/#{p}").status == 401
    assert call_router("GET", "localhost", "/v1/projects/#{p}/serviceAccounts").status == 401

    sa_conn =
      call_router("POST", "iam.googleapis.com", "/v1/projects/#{p}/serviceAccounts", %{"accountId" => "worker"}, auth)

    assert sa_conn.status == 200
    %{"email" => email} = Jason.decode!(sa_conn.resp_body)

    get_sa = call_router("GET", "localhost", "/v1/projects/#{p}/serviceAccounts/#{email}", nil, auth)
    assert get_sa.status == 200
    assert %{"email" => ^email} = Jason.decode!(get_sa.resp_body)

    crm_conn = call_router("GET", "cloudresourcemanager.googleapis.com", "/v3/projects/#{p}", nil, auth)
    assert crm_conn.status == 200
    assert %{"projectId" => ^p} = Jason.decode!(crm_conn.resp_body)
  end

  test "cloud_tasks routes via EgressRouter enforce Bearer auth and dispatch queues/tasks" do
    p = uniq()
    base = "/v2/projects/#{p}/locations/us-central1/queues"
    auth = auth_header()
    bad_auth = [{"authorization", "Bearer ya29.invalid"}]

    assert call_router("POST", "cloudtasks.googleapis.com", base, %{"name" => "#{base}/q1"}).status == 401
    assert call_router("GET", "localhost", "#{base}/q1", nil, bad_auth).status == 401

    cq = call_router("POST", "cloudtasks.googleapis.com", base, %{"name" => "#{base}/q1"}, auth)
    assert cq.status == 200
    assert %{"state" => "RUNNING"} = Jason.decode!(cq.resp_body)

    gq = call_router("GET", "localhost", "#{base}/q1", nil, auth)
    assert gq.status == 200

    ct1 =
      call_router(
        "POST",
        "cloudtasks.googleapis.com",
        "#{base}/q1/tasks",
        %{
          "task" => %{
            "name" => "#{base}/q1/tasks/t1",
            "functionEntryPoint" => "#{@handler_mod}.echo",
            "payload" => %{"k" => "v"}
          }
        },
        auth
      )

    assert ct1.status == 200

    ct2 =
      call_router(
        "POST",
        "cloudtasks.googleapis.com",
        "#{base}/q1/tasks",
        %{"name" => "t2", "functionEntryPoint" => "#{@handler_mod}.fail"},
        auth
      )

    assert ct2.status == 200

    lt = call_router("GET", "cloudtasks.googleapis.com", "#{base}/q1/tasks", nil, auth)
    assert lt.status == 200
    assert %{"tasks" => [_, _]} = Jason.decode!(lt.resp_body)

    run = call_router("POST", "cloudtasks.googleapis.com", "#{base}/q1/tasks/t1:run", %{}, auth)
    assert run.status == 200
    assert %{"status" => "done", "result" => %{"echo" => %{"k" => "v"}}} = Jason.decode!(run.resp_body)

    drain = call_router("POST", "cloudtasks.googleapis.com", "#{base}/q1:drain", %{}, auth)
    assert drain.status == 200
    assert %{"results" => [%{"task" => "t2", "status" => "failed"}]} = Jason.decode!(drain.resp_body)
  end

  test "functions routes via EgressRouter enforce Bearer auth and execute handlers" do
    p = uniq()
    base = "/v2/projects/#{p}/locations/us-central1/functions"
    auth = auth_header()
    bad_auth = [{"authorization", "Bearer not-a-jwt"}]

    assert call_router("POST", "cloudfunctions.googleapis.com", "#{base}?functionId=fn1", %{"entryPoint" => "#{@handler_mod}.echo"}).status == 401
    assert call_router("GET", "localhost", base, nil, bad_auth).status == 401

    cf =
      call_router(
        "POST",
        "cloudfunctions.googleapis.com",
        "#{base}?functionId=fn1",
        %{"entryPoint" => "#{@handler_mod}.echo"},
        auth
      )

    assert cf.status == 200
    assert %{"state" => "ACTIVE"} = Jason.decode!(cf.resp_body)

    lf = call_router("GET", "localhost", base, nil, auth)
    assert lf.status == 200
    assert %{"functions" => [_]} = Jason.decode!(lf.resp_body)

    gf = call_router("GET", "cloudfunctions.googleapis.com", "#{base}/fn1", nil, auth)
    assert gf.status == 200

    res = call_router("POST", "cloudfunctions.googleapis.com", "#{base}/fn1:call", %{"data" => %{"x" => 42}}, auth)
    assert res.status == 200
    assert %{"result" => %{"echo" => %{"x" => 42}}, "executionId" => "exec-" <> _} = Jason.decode!(res.resp_body)

    del = call_router("DELETE", "cloudfunctions.googleapis.com", "#{base}/fn1", nil, auth)
    assert del.status == 200
    assert call_router("GET", "cloudfunctions.googleapis.com", "#{base}/fn1", nil, auth).status == 404
  end
end
