defmodule Smalt.ApimTest do
  use ExUnit.Case, async: false
  import Plug.Test
  import Plug.Conn, only: [get_req_header: 2]

  # v26.10.31 inversion (WO-06): Smalt.Apim is the dialect-tier (Azure API
  # Management emulation) policy engine. This court pins the POLICY CHAIN
  # SEMANTICS (transform, rate-limit, jwt refusal order + shapes), not the
  # module's tier location. `@policy_engine` is the seam — the strip wave
  # re-points or deletes this file with its subject; no core-tier assertion
  # lives here.
  @policy_engine Smalt.Apim

  @aud "https://management.azure.com"

  @aud "https://management.azure.com"

  defp conn_get(path) do
    conn(:get, path, nil) |> Map.put(:remote_ip, {127, 0, 0, 1})
  end

  defp with_bearer(conn, token), do: Plug.Conn.put_req_header(conn, "authorization", "Bearer #{token}")

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

  defp decode_body(conn) do
    %{"error" => err} = Jason.decode!(conn.resp_body)
    err
  end

  describe "policy chain" do
    test "all-ok chain admits: no halt, header transform applied" do
      conn =
        conn_get("/anything")
        |> with_bearer(mint_valid_token())
        |> @policy_engine.run([
          {:header_transform, set: [{"x-apim-slice", "on"}]},
          {:rate_limit, limit: 5, scope: "chain-admit"},
          {:jwt, []}
        ])

      refute conn.halted
      assert get_req_header(conn, "x-apim-slice") == ["on"]
    end

    test "rate-limit over quota refuses typed 429" do
      scope = "rl-#{System.unique_integer([:positive])}"
      conn = conn_get("/rl")

      assert %Plug.Conn{halted: false} = @policy_engine.run(conn, [{:rate_limit, limit: 2, scope: scope}])
      assert %Plug.Conn{halted: false} = @policy_engine.run(conn, [{:rate_limit, limit: 2, scope: scope}])

      refused = @policy_engine.run(conn, [{:rate_limit, limit: 2, scope: scope}])

      assert refused.halted
      assert refused.status == 429
      err = decode_body(refused)
      assert err["message"] =~ "limit 2"
    end

    test "jwt-invalid refuses typed 401 SignatureVerificationFailed" do
      conn =
        conn_get("/jwt")
        |> with_bearer("not.a.jwt")

      refused = @policy_engine.run(conn, [{:jwt, []}])

      assert refused.halted
      assert refused.status == 401
      err = decode_body(refused)
      assert err["code"] == "InvalidAuthenticationToken"
      assert err["message"] == "SignatureVerificationFailed"
    end

    test "jwt-missing refuses typed 401 MissingBearerToken" do
      refused = @policy_engine.run(conn_get("/jwt"), [{:jwt, []}])

      assert refused.halted
      assert refused.status == 401
      err = decode_body(refused)
      assert err["code"] == "AuthenticationFailed"
      assert err["message"] == "MissingBearerToken"
    end
  end

  describe "parse_policy document order (C9 cons+reverse at success exit)" do
    @policy_xml """
    <policies>
      <inbound>
        <base />
        <rate-limit calls="10" renewal-period="60" />
        <set-header name="x-a" exists-action="overwrite">1</set-header>
        <validate-jwt header-name="authorization">
          <required-claims>
            <claim name="aud" match="any">
              <value>a</value>
              <value>b</value>
              <value>c</value>
            </claim>
            <claim name="tid">
              <value>t</value>
            </claim>
          </required-claims>
        </validate-jwt>
        <set-header name="x-b" exists-action="overwrite">2</set-header>
        <set-header name="x-c" exists-action="overwrite">3</set-header>
      </inbound>
    </policies>
    """

    test "inbound policies keep document order (5 policies, base skipped)" do
      assert {:ok, parsed} = Smalt.DataPlane.Apim.parse_policy(@policy_xml)
      inbound = parsed["inbound"]

      assert length(inbound) >= 3

      types = Enum.map(inbound, & &1["type"])
      assert types == ["rate-limit", "set-header", "validate-jwt", "set-header", "set-header"]
    end

    test "claim rules keep document order (>= 3 header rules)" do
      assert {:ok, parsed} = Smalt.DataPlane.Apim.parse_policy(@policy_xml)

      jwt = Enum.find(parsed["inbound"], &(&1["type"] == "validate-jwt"))
      claims = jwt["required-claims"]
      assert length(claims) >= 2
      assert Enum.map(claims, & &1["name"]) == ["aud", "tid"]

      # per-claim values keep document order too
      aud = Enum.find(claims, &(&1["name"] == "aud"))
      assert aud["values"] == ["a", "b", "c"]
    end
  end
end
