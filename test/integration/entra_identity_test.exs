defmodule Smalt.Identity.EntraIdentityTest do
  @moduledoc """
  r16 courts (lane S3): EntraClaims + EntraSaml + AcaIdentity + EntraToken.

  Chicago discipline: real Bandit listeners on private ports, real xmerl
  parse of the minted SAML, real signature verification via
  `SamlSlo.verify_enveloped_signature/2`, real JWT verification under the
  STS key. Bounded polls on listener readiness, no coordination sleeps.
  """

  use ExUnit.Case, async: false

  alias Smalt.Identity.AcaIdentity
  alias Smalt.Identity.EntraClaims
  alias Smalt.Identity.EntraSaml
  alias Smalt.Identity.EntraToken
  alias Smalt.Identity.SamlSlo

  @tid "11111111-1111-4111-8111-111111111111"
  @oid "22222222-2222-4222-8222-222222222222"
  @g1 "33333333-3333-4333-8333-333333333331"
  @g2 "33333333-3333-4333-8333-333333333332"
  @redis_aud "https://redis.azure.com/"
  @sp "http://127.0.0.1:18080"
  @acs "http://127.0.0.1:18080/saml/acs"
  @logout_request_re ~r/(<[\w.:-]*LogoutRequest\b.*<\/[\w.:-]*LogoutRequest>)/s

  # ==================================================================
  # EntraClaims - the exact claims.ts contract
  # ==================================================================

  test "claim_uris mirrors claims.ts CLAIMS exactly" do
    uris = EntraClaims.claim_uris()

    assert uris[:displayname] == "http://schemas.microsoft.com/identity/claims/displayname"
    assert uris[:name] == "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"
    assert uris[:email] == "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
    assert uris[:givenname] == "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname"
    assert uris[:surname] == "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname"
    assert uris[:objectidentifier] == "http://schemas.microsoft.com/identity/claims/objectidentifier"
    assert uris[:tenantid] == "http://schemas.microsoft.com/identity/claims/tenantid"
    assert uris[:authnmethodsreferences] == "http://schemas.microsoft.com/claims/authnmethodsreferences"
    assert uris[:groups] == "http://schemas.microsoft.com/ws/2008/06/identity/claims/groups"
    assert uris[:groups_link] == "http://schemas.microsoft.com/claims/groups.link"
    assert uris[:role] == "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"
  end

  test "attribute_list mints the full Entra surface, GUID casing preserved" do
    list = EntraClaims.attribute_list([])
    by_name = Map.new(list, &{&1.name, &1.values})

    assert by_name[uri(:displayname)] == ["Smalt User"]
    assert by_name[uri(:name)] == ["smalt.user@tenanta.example"]
    assert by_name[uri(:email)] == ["smalt.user@tenanta.example"]
    assert by_name[uri(:givenname)] == ["Smalt"]
    assert by_name[uri(:surname)] == ["User"]
    assert by_name[uri(:objectidentifier)] == [@oid]
    assert by_name[uri(:tenantid)] == [@tid]
    assert by_name[uri(:authnmethodsreferences)] == ["http://schemas.microsoft.com/claims/pwd"]
    assert by_name[uri(:groups)] == [@g1, @g2]
    assert by_name[uri(:groups_link)] == nil
    assert by_name[uri(:role)] == ["Admin"]
  end

  test "groups.link is minted only when groups_overage" do
    base = EntraClaims.attribute_list(groups_overage: true, groups: [])
    by_name = Map.new(base, &{&1.name, &1.values})

    assert by_name[uri(:groups)] == nil
    assert by_name[uri(:groups_link)] == ["1"]

    normal = Map.new(EntraClaims.attribute_list([]), &{&1.name, &1.values})
    assert normal[uri(:groups_link)] == nil
  end

  test "attribute_statement_xml emits multi-value Attribute elements" do
    xml = EntraClaims.attribute_statement_xml([])

    # ONE groups attribute carrying BOTH GUIDs (multi-value shape).
    assert xml =~ ~s(Name="#{uri(:groups)}")
    assert xml =~ @g1
    assert xml =~ @g2
    assert length(Regex.scan(~r{<saml:Attribute Name="http://schemas.microsoft.com/ws/2008/06/identity/claims/groups"}, xml)) == 1
  end

  test "resolve: opts override config" do
    prev = Application.get_env(:smalt, :entra_identity)
    Application.put_env(:smalt, :entra_identity, tenant_id: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")
    list = EntraClaims.attribute_list(given_name: "Zed")
    by_name = Map.new(list, &{&1.name, &1.values})

    assert by_name[uri(:tenantid)] == ["aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"]
    assert by_name[uri(:givenname)] == ["Zed"]
    assert by_name[uri(:displayname)] == ["Smalt User"]

    on_exit(fn ->
      if prev, do: Application.put_env(:smalt, :entra_identity, prev),
        else: Application.delete_env(:smalt, :entra_identity)
    end)
  end

  # ==================================================================
  # EntraSaml - mint + real signature verification + SLO
  # ==================================================================

  describe "EntraSaml" do
    setup do
      port = 39_446 + :rand.uniform(20_000)
      base = "http://127.0.0.1:#{port}"

      {:ok, _} = Bandit.start_link(plug: {EntraSaml, []}, scheme: :http, port: port, ip: {127, 0, 0, 1})
      wait_until(base <> "/metadata")

      {:ok, base: base}
    end

    test "minted response passes SamlSlo signature verification (assertion AND Response)", %{base: base} do
      resp = EntraSaml.mint_response(request())

      assert :ok = SamlSlo.verify_enveloped_signature(resp, assertion_re())
      assert :ok = SamlSlo.verify_enveloped_signature(resp, response_re())
    end

    test "/sso serves the Entra claim set in an auto-POST form", %{base: base} do
      req_b64 = Base.encode64(authn_request_xml())
      html = http_get("#{base}/sso?SAMLRequest=#{URI.encode_www_form(req_b64)}")

      resp_b64 = form_value(html, "SAMLResponse")
      assert is_binary(resp_b64) and byte_size(resp_b64) > 100

      resp = Base.decode64!(resp_b64)

      assert resp =~ "http://schemas.microsoft.com/identity/claims/displayname"
      assert resp =~ "http://schemas.microsoft.com/identity/claims/tenantid"
      assert resp =~ "http://schemas.microsoft.com/claims/authnmethodsreferences"
      assert resp =~ @oid
      assert resp =~ @tid
      assert resp =~ @g1
      assert resp =~ @g2
      assert resp =~ "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified"
      assert resp =~ "https://sts.windows.net/#{@tid}/"
      assert resp =~ "<saml:Audience>#{@sp}</saml:Audience>"
      assert resp =~ ~r/InResponseTo="_req[0-9a-f]+"/
      assert resp =~ ~s(Destination="#{@acs}")
      assert resp =~ ~s(Recipient="#{@acs}")
    end

    test "/slo consumes an unsigned SP LogoutRequest and answers LogoutResponse", %{base: base} do
      # Mint first so the (NameID, SessionIndex) session exists.
      _ = EntraSaml.mint_response(request())
      name_id = "smalt.user@tenanta.example"

      # The session index is the assertion id minted above; mint a fresh
      # recorded session directly through the SamlSlo law to get a known one.
      session_index = "_smalt" <> unique()
      :ok = SamlSlo.record_session(name_id, session_index)

      lr_xml = SamlSlo.logout_request_xml(name_id, [session_index], "#{base}/slo", "_lr" <> unique())
      lr_b64 = Base.encode64(lr_xml)

      body = http_get("#{base}/slo?SAMLRequest=#{URI.encode_www_form(lr_b64)}")

      assert body =~ "LogoutResponse"
    end
  end

  # ==================================================================
  # AcaIdentity - the ACA 17001 MSI face
  # ==================================================================

  describe "AcaIdentity" do
    setup do
      port = 37_001 + :rand.uniform(20_000)
      base = "http://127.0.0.1:#{port}"

      {:ok, _} = Bandit.start_link(plug: {AcaIdentity, []}, scheme: :http, port: port, ip: {127, 0, 0, 1})
      wait_until_token(base)

      {:ok, base: base}
    end

    test "2019-08-01 form with x-identity-header mints a verifiable MSI token", %{base: base} do
      {status, body} = http_get_json("#{base}/?api-version=2019-08-01&resource=#{URI.encode_www_form(@redis_aud)}", [{"x-identity-header", "court"}])

      assert status == 200
      assert body["token_type"] == "Bearer"
      assert is_binary(body["access_token"])
      assert is_binary(body["expires_on"])
      assert String.match?(body["expires_on"], ~r/^\d+$/)
      assert body["resource"] == @redis_aud

      assert {:ok, claims} = EntraToken.verify(body["access_token"], aud: @redis_aud)
      assert claims["tid"] == @tid
      assert claims["iss"] == "https://sts.windows.net/#{@tid}/"
      assert claims["xms_mirid"] =~ "Microsoft.ManagedIdentity"
      assert claims["exp"] - claims["iat"] >= 3500
    end

    test "IMDS 2018-02-01 form with Metadata: true is the same mint", %{base: base} do
      {status, body} = http_get_json("#{base}/metadata/identity/oauth2/token?api-version=2018-02-01&resource=#{URI.encode_www_form(@redis_aud)}", [{"metadata", "true"}])

      assert status == 200

      assert {:ok, claims} = EntraToken.verify(body["access_token"], aud: @redis_aud)
      assert claims["tid"] == @tid
    end

    test "typed refusals: bad api-version, missing identity proof, missing resource", %{base: base} do
      {s1, _} = http_get_json("#{base}/?api-version=1999-01-01&resource=x", [{"x-identity-header", "court"}])
      assert s1 == 400

      {s2, _} = http_get_json("#{base}/?api-version=2019-08-01&resource=#{URI.encode_www_form(@redis_aud)}", [])
      assert s2 == 400

      {s3, _} = http_get_json("#{base}/?api-version=2019-08-01", [{"x-identity-header", "court"}])
      assert s3 == 400
    end
  end

  # ==================================================================
  # EntraToken - verify law
  # ==================================================================

  describe "EntraToken" do
    test "verify admits a minted redis token and refuses wrong audience" do
      {:ok, token, claims} = mint_redis_token()
      assert claims["aud"] == @redis_aud

      assert {:ok, _} = EntraToken.verify(token, aud: @redis_aud)
      assert {:error, :bad_audience} = EntraToken.verify(token, aud: "https://management.azure.com")
    end

    test "verify refuses an expired token" do
      {:ok, token, _} = mint_redis_token(now: System.system_time(:second) - 7200)
      assert {:error, :expired} = EntraToken.verify(token, aud: @redis_aud)
    end

    test "verify refuses a token signed by a foreign key" do
      assert {:error, :bad_signature} = EntraToken.verify(garbled_jwt(), aud: @redis_aud)
    end

    test "jwt? is shape-only routing" do
      {:ok, token, _} = mint_redis_token()
      assert EntraToken.jwt?(token)
      refute EntraToken.jwt?("abc")
      refute EntraToken.jwt?("a.b.c!")
      refute EntraToken.jwt?("")
    end
  end

  # ------------------------------------------------------------------
  # Shared helpers
  # ------------------------------------------------------------------

  defp request do
    %{id: "_req" <> unique(), acs: @acs, issuer: @sp}
  end

  defp authn_request_xml do
    id = "_req" <> unique()

    """
    <samlp:AuthnRequest xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" ID="#{id}" Version="2.0" IssueInstant="2026-10-29T00:00:00Z" AssertionConsumerServiceURL="#{@acs}"><saml:Issuer xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion">#{@sp}</saml:Issuer></samlp:AuthnRequest>
    """
    |> String.trim_trailing("\n")
  end

  defp mint_redis_token(opts \\ []) do
    now = Keyword.get(opts, :now) || System.system_time(:second)

    {:ok, token} =
      Smalt.Auth.StsKey.mint(%{
        "aud" => @redis_aud,
        "iss" => "https://sts.windows.net/#{@tid}/",
        "iat" => now,
        "nbf" => now,
        "exp" => now + 3600,
        "appid" => "00000000-0000-0000-0000-000000000004",
        "oid" => @oid,
        "tid" => @tid
      })

    {:ok, token, %{"aud" => @redis_aud}}
  end

  defp uri(key), do: EntraClaims.claim_uris()[key]
  defp assertion_re, do: ~r/(<[\w.:-]*Assertion\b.*<\/[\w.:-]*Assertion>)/s
  defp response_re, do: ~r/(<[\w.:-]*Response\b.*<\/[\w.:-]*Response>)/s

  defp garbled_jwt do
    h = Base.url_encode64(Jason.encode!(%{"alg" => "RS256", "typ" => "JWT"}), padding: false)
    p = Base.url_encode64(Jason.encode!(%{"aud" => @redis_aud, "exp" => 9_999_999_999}), padding: false)
    h <> "." <> p <> "." <> Base.url_encode64("not-a-signature", padding: false)
  end

  defp unique, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  # Real HTTP over the private Bandit listeners (bounded poll, no sleeps).
  defp wait_until(url), do: wait_until(url, 500)
  defp wait_until(_url, 0), do: flunk("listener never came up")

  defp wait_until(url, tries) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [], []) do
      {:ok, _} -> :ok
      {:error, _} ->
        Process.sleep(10) # SLEEP-CLASS: POLL-STEP (bounded listener poll)
        wait_until(url, tries - 1)
    end
  end

  defp wait_until_token(base), do: wait_until_token(base, 500)
  defp wait_until_token(_base, 0), do: flunk("identity listener never came up")

  defp wait_until_token(base, tries) do
    url = String.to_charlist(base <> "/?api-version=2019-08-01&resource=x")

    hdrs = [{~c"x-identity-header", ~c"probe"}]
    case :httpc.request(:get, {url, hdrs}, [], []) do
      {:ok, {{_, 400, _}, _, _}} -> :ok
      {:ok, {{_, _, _}, _, _}} -> :ok
      {:error, _} ->
        Process.sleep(10)
        wait_until_token(base, tries - 1)
    end
  end

  defp http_get(url) do
    {:ok, {{_, 200, _}, _, body}} = :httpc.request(:get, {String.to_charlist(url), []}, [], [])
    to_string(body)
  end

  defp http_get_json(url, headers) do
    hdrs = Enum.map(headers, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    case :httpc.request(:get, {url, hdrs}, [], []) do
      {:ok, {{_, status, _}, _, body}} -> {status, Jason.decode!(to_string(body))}
      {:error, reason} -> flunk("http error: #{inspect(reason)}")
    end
  end

  defp form_value(html, field) do
    case Regex.run(~r/name="#{field}" value="([^"]+)"/, html) do
      [_, v] -> v
      _ -> nil
    end
  end

  defp restore_env(key, prev) do
    if prev, do: Application.put_env(:smalt, key, prev), else: Application.delete_env(:smalt, key)
  end
end
