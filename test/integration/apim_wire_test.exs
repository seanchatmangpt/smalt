defmodule Smalt.Integration.ApimWireTest do
  # PRD-APIM wire court (lane APIMWIRE): Smalt.Apim is wired into the live
  # router as a config-driven route family. Chicago discipline — real
  # Smalt.EgressRouter, real plug chain, real ETS rate-limit table, real JWT
  # verification via Smalt.Auth.Bearer.verify_bearer/1. Assertions on the
  # actual wire responses (status + typed envelope body), never call counts.
  #
  # The route family is DEFAULT-OFF: with no `:smalt, :apim_gateways` entry
  # for the requested api, the plug passes through unchanged (the witness is
  # the same typed 404 the blob catch-all serves for the OFF posture).
  use ExUnit.Case, async: false

  @aud "https://management.azure.com"

  defp unique_api,
    do: "apimwire-" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))

  defp call(method, path, opts \\ []) do
    conn =
      Plug.Test.conn(method, path, opts[:body])
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> then(fn c ->
        case opts[:auth] do
          nil -> c
          token -> Plug.Conn.put_req_header(c, "authorization", "Bearer #{token}")
        end
      end)

    Smalt.EgressRouter.call(conn, [])
  end

  # Scoped config flip with restore — Chicago-real: the flip is Application
  # env on the running node, the router reads it per request.
  defp with_gateway(api, conf, fun) do
    prev = Application.get_env(:smalt, :apim_gateways) || %{}

    :ok =
      Application.put_env(
        :smalt,
        :apim_gateways,
        # config contract: api keys are BINARIES (operator-authored config;
        # never String.to_atom on anything request-shaped).
        Map.put(prev, api, conf)
      )

    try do
      fun.()
    after
      Application.put_env(:smalt, :apim_gateways, prev)
    end
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

  test "default-off: unconfigured api under /apim-gw falls through to the typed 404 face" do
    api = unique_api()
    conn = call(:get, "/apim-gw/#{api}/thing")
    assert conn.status == 404
  end

  test "policy chain admits: echo backend 200 carries the post-transform request header" do
    api = unique_api()

    with_gateway(api, %{policies: [{:header_transform, set: [{"x-apim-slice", "wired"}]}]}, fn ->
      conn = call(:get, "/apim-gw/#{api}/orders/42")

      assert conn.status == 200

      assert %{"api" => ^api, "method" => "GET", "path" => "/apim-gw/" <> _} =
               Jason.decode!(conn.resp_body)

      sent = Jason.decode!(conn.resp_body)
      assert sent["headers"]["x-apim-slice"] == "wired"
    end)
  end

  test "over-quota refuses typed 429 from the live router (VAL-PRD falsifier)" do
    api = unique_api()

    with_gateway(
      api,
      %{policies: [{:rate_limit, limit: 2, window_seconds: 60, scope: "wire-" <> api}]},
      fn ->
        assert call(:get, "/apim-gw/#{api}/x").status == 200
        assert call(:get, "/apim-gw/#{api}/x").status == 200

        refused = call(:get, "/apim-gw/#{api}/x")
        assert refused.status == 429

        err = err_body(refused)
        assert err["code"] == "TooManyRequests"
        assert err["message"] =~ "limit 2"
        assert Plug.Conn.get_resp_header(refused, "retry-after") == ["1"]
      end
    )
  end

  test "invalid JWT refuses typed 401 from the live router (VAL-PRD falsifier)" do
    api = unique_api()

    with_gateway(api, %{policies: [{:jwt, []}]}, fn ->
      refused = call(:get, "/apim-gw/#{api}/x", auth: "not.a.jwt")
      assert refused.status == 401
      err = err_body(refused)
      assert err["code"] == "InvalidAuthenticationToken"

      missing = call(:get, "/apim-gw/#{api}/x")
      assert missing.status == 401
      assert err_body(missing)["code"] == "AuthenticationFailed"
    end)
  end

  test "valid JWT from the emulator STS admits through the jwt policy" do
    api = unique_api()

    with_gateway(api, %{policies: [{:jwt, []}]}, fn ->
      conn = call(:get, "/apim-gw/#{api}/x", auth: mint_valid_token())
      assert conn.status == 200
    end)
  end

  test "chain order: rate_limit + jwt — jwt refusal wins over an admitted rate slot" do
    api = unique_api()

    with_gateway(
      api,
      %{policies: [{:rate_limit, limit: 5, scope: "wire2-" <> api}, {:jwt, []}]},
      fn ->
        refused = call(:get, "/apim-gw/#{api}/x", auth: "garbage")
        assert refused.status == 401
      end
    )
  end
end
