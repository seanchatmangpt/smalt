defmodule Smalt.GCP.TerraformStsAuthTest do
  @moduledoc """
  Verifies that a token minted via `POST /oauth2/v2.0/token`
  (`grant_type=client_credentials`) on the ARM STS (`:9443`) is accepted by
  `Smalt.Auth.Bearer` and `Smalt.EgressRouter` (`:8443`) across `gcp_family/1`
  endpoints, and that missing/invalid tokens return `401`.
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias Smalt.ArmGateway.Router, as: ArmRouter
  alias Smalt.Auth.Bearer
  alias Smalt.EgressRouter

  @gcp_endpoints [
    {:cloud_run_v2, :get, "/v2/projects/tf-p1/locations/us-central1/services", nil},
    {:kms, :post, "/v1/projects/tf-p1/locations/global/keyRings", "{}"} ,
    {:secrets, :get, "/v1/projects/tf-p1/secrets", nil},
    {:storage, :get, "/storage/v1/b?project=tf-p1", nil},
    {:pubsub, :get, "/v1/projects/tf-p1/topics", nil}
  ]

  setup do
    prev_auth = Application.get_env(:smalt, :auth_mode)
    Application.put_env(:smalt, :auth_mode, :enforce)

    on_exit(fn ->
      if is_nil(prev_auth) do
        Application.delete_env(:smalt, :auth_mode)
      else
        Application.put_env(:smalt, :auth_mode, prev_auth)
      end
    end)

    :ok
  end

  defp mint_sts_token do
    conn =
      :post
      |> conn("/oauth2/v2.0/token", %{
        "grant_type" => "client_credentials",
        "client_id" => "tf-client",
        "client_secret" => "tf-secret"
      })
      |> Map.put(:host, "127.0.0.1")
      |> Map.put(:port, 9443)
      |> ArmRouter.call([])

    assert conn.status == 200
    %{"access_token" => token, "token_type" => "Bearer"} = Jason.decode!(conn.resp_body)
    assert is_binary(token) and byte_size(token) > 0
    token
  end

  defp egress_call(method, path, body, headers) do
    c =
      conn(method, path, body)
      |> Map.put(:host, "127.0.0.1")
      |> Map.put(:port, 8443)

    c =
      Enum.reduce(headers, c, fn {k, v}, acc ->
        put_req_header(acc, k, v)
      end)

    EgressRouter.call(c, [])
  end

  test "STS token minted via /oauth2/v2.0/token is accepted by Smalt.Auth.Bearer and invalid/missing tokens return 401" do
    token = mint_sts_token()

    ok_conn =
      conn(:get, "/v1/projects/tf-p1/topics")
      |> Map.put(:host, "127.0.0.1")
      |> Map.put(:port, 8443)
      |> put_req_header("authorization", "Bearer #{token}")
      |> Bearer.call([])

    refute ok_conn.halted

    missing_conn =
      conn(:get, "/v1/projects/tf-p1/topics")
      |> Map.put(:host, "127.0.0.1")
      |> Map.put(:port, 8443)
      |> Bearer.call([])

    assert missing_conn.halted
    assert missing_conn.status == 401

    invalid_conn =
      conn(:get, "/v1/projects/tf-p1/topics")
      |> Map.put(:host, "127.0.0.1")
      |> Map.put(:port, 8443)
      |> put_req_header("authorization", "Bearer invalid.jwt.token")
      |> Bearer.call([])

    assert invalid_conn.halted
    assert invalid_conn.status == 401
  end

  for {family, method, path, body} <- @gcp_endpoints do
    test "EgressRouter accepts STS token on #{family} (#{path})" do
      token = mint_sts_token()

      path =
        if unquote(family) == :kms do
          "#{unquote(path)}?keyRingId=kr-#{System.unique_integer([:positive])}"
        else
          unquote(path)
        end

      resp =
        egress_call(unquote(method), path, unquote(body), [
          {"authorization", "Bearer #{token}"}
        ])

      assert resp.status in [200, 201, 204]
    end

    test "EgressRouter returns 401 on #{family} (#{path}) when token is missing or invalid" do
      missing = egress_call(unquote(method), unquote(path), unquote(body), [])
      assert missing.status == 401

      invalid =
        egress_call(unquote(method), unquote(path), unquote(body), [
          {"authorization", "Bearer invalid.jwt.token"}
        ])

      assert invalid.status == 401
    end
  end
end
