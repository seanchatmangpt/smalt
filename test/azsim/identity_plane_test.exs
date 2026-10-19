defmodule SmaltTest.Azsim.IdentityPlaneTest do
  @moduledoc """
  AZB-08 — Identity plane profile (KeyVault + Entra STS) court.

  Accept faces at Plug level (real routers, real store, real HS256 mint —
  Chicago-style real collaborators, no mocks):

    1. KD-15 mode-blind challenge shape: tokenless /keys call in BOTH auth
       modes answers 401 with a BYTE-EQUAL enriched WWW-Authenticate header
       (grammar pinned by KD-15: `Bearer authorization=...`, `resource=...`
       echoing the request origin, `error="invalid_token"`,
       `error_description="MissingBearerToken"`, no `authorization_uri`).
    2. Injected-clock TTL expiry: a token is refused TokenExpired when the
       injected verify clock (`:smalt, :sts_clock`) moves past exp — the
       clock is MOVED, never slept (zero-Process.sleep law).
    3. Key rotation: re-create issues a NEW version; the OLD version still
       decrypts; GET /keys/:name returns the LATEST version.

  Plus the profile read sites (`:keyvault api_version/challenge_mode`,
  `:sts token_ttl_seconds`) honored from the one ontology-declared config
  source (`Smalt.Config.keyvault/0` / `Smalt.Config.sts/0`, projected via
  `mix smalt.gen` — no hand-written accessor).
  """

  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2, put_req_header: 3]
  import SmaltTest.Wire, only: [save_restore: 1]

  alias Smalt.Auth.Bearer
  alias Smalt.EgressRouter

  @opts EgressRouter.init([])
  @secret "smalt-azb08-identity-test-secret-0123456789abcdef"
  @aud "https://management.azure.com"
  @iss "https://login.microsoftonline.com/00000000-0000-0000-0000-000000000000/v2.0"

  setup do
    SmaltTest.Lifecycle.ensure_store_up()

    # Profile keys pinned to the identity-profile values (the same kw
    # config/env/az_prod_identity.exs carries). One source: every read site
    # under test consumes these via Smalt.Config.keyvault()/sts().
    save_restore(
      auth_mode: :enforce,
      sts_signing_secret: @secret,
      sts: [token_ttl_seconds: 3600, pki_envelope: :pqc_hybrid],
      keyvault: [api_version: "7.4", challenge_mode: :strict_bearer]
    )

    :ok
  end

  # -- helpers -------------------------------------------------------------------

  defp call(method, path, opts \\ []) do
    method
    |> conn(path, opts[:body])
    |> put_headers(opts[:headers])
    |> EgressRouter.call(@opts)
  end

  defp put_headers(c, nil), do: c
  defp put_headers(c, hs), do: Enum.reduce(hs, c, fn {k, v}, acc -> put_req_header(acc, k, v) end)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp mint(claims_override \\ %{}) do
    now = clock()

    claims =
      Map.merge(
        %{
          "aud" => @aud,
          "iss" => @iss,
          "iat" => now,
          "nbf" => now,
          "exp" => now + 3600,
          "appid" => "00000000-0000-0000-0000-000000000000",
          "azp" => "00000000-0000-0000-0000-000000000000",
          "oid" => "00000000-0000-0000-0000-000000000001",
          "sub" => "00000000-0000-0000-0000-000000000001",
          "tid" => "00000000-0000-0000-0000-000000000000",
          "roles" => ["Contributor", "Owner"]
        },
        claims_override
      )

    {:ok, token, _} = Joken.generate_and_sign(%{}, claims, Joken.Signer.create("HS256", @secret))
    token
  end

  defp clock, do: System.system_time(:second)

  defp bearer(token), do: [{"authorization", "Bearer " <> token}]

  defp version_of(kid) when is_binary(kid) do
    kid |> String.split("/") |> List.last()
  end

  # -- 1. profile read sites -------------------------------------------------------

  describe "identity profile read sites (AZB-08)" do
    test "profile file pins the AZB-08 spec values" do
      path = Path.join([File.cwd!(), "config/env/az_prod_identity.exs"])
      [{:smalt, kw}] = Config.Reader.read!(path, env: :test)

      assert {:keyvault, [api_version: "7.4", challenge_mode: :strict_bearer]} in kw
      assert {:sts, [token_ttl_seconds: 3600, pki_envelope: :pqc_hybrid]} in kw

      # Port single-source law (AZB-04): no port key inside the profile.
      refute Keyword.has_key?(kw, :arm_port)
      refute Keyword.has_key?(kw, :egress_port)
    end

    test "accessors read the profile keys with byte-identical defaults" do
      # Profile active: the read sites report the profile values.
      assert Bearer.kv_challenge_mode() == :strict_bearer
      assert Smalt.DataPlane.KeyVaultActions.api_version() == "7.4"
      assert Smalt.DataPlane.KeyVaultActions.challenge_mode() == :strict_bearer
      assert Smalt.Config.sts()[:token_ttl_seconds] == 3600

      # Profile absent (`:all` boot): defaults keep behavior byte-identical.
      # Scanner-visible save/restore (leak-court remediation): asserts demand
      # TRUE key absence (`Smalt.Config.sts() == []`), so the keys are
      # deleted, not set to nil; restore discipline is explicit save + on_exit.
      prev_kv = Application.get_env(:smalt, :keyvault, :__unset__)
      prev_sts = Application.get_env(:smalt, :sts, :__unset__)

      on_exit(fn ->
        if prev_kv == :__unset__,
          do: Application.delete_env(:smalt, :keyvault),
          else: Application.put_env(:smalt, :keyvault, prev_kv)

        if prev_sts == :__unset__,
          do: Application.delete_env(:smalt, :sts),
          else: Application.put_env(:smalt, :sts, prev_sts)
      end)

      Application.delete_env(:smalt, :keyvault)
      Application.delete_env(:smalt, :sts)

      assert Bearer.kv_challenge_mode() == :strict_bearer
      assert Smalt.DataPlane.KeyVaultActions.api_version() == "7.4"
      assert Smalt.Config.sts() == []
    end

    test "challenge guard consults the challenge_mode profile key" do
      # strict_bearer (the profile value): tokenless /keys challenges even in
      # :anonymous mode — the KD-15 mode-blind posture, now profile-named.
      SmaltTest.Env.with([auth_mode: :anonymous], fn ->
        res =
          SmaltTest.Env.with([keyvault: [challenge_mode: :strict_bearer]], fn ->
            call(:get, "/keys", headers: [{"authorization", ""}])
          end)

        assert res.status == 401
        assert get_resp_header(res, "www-authenticate") != []
      end)

      # A non-strict challenge_mode names a DIFFERENT posture: the mode-blind
      # guard steps aside and enforce-mode Bearer refuses downstream with its
      # own envelope (MalformedBearerHeader on the empty Authorization value,
      # vs the guard's MissingBearerToken challenge).
      SmaltTest.Env.with([auth_mode: :enforce, keyvault: [challenge_mode: :relaxed]], fn ->
        res2 = call(:get, "/keys", headers: [{"authorization", ""}])

        assert res2.status == 401
        assert get_resp_header(res2, "www-authenticate") != []
        [wa] = get_resp_header(res2, "www-authenticate")
        assert wa =~ ~s(error_description="MalformedBearerHeader")
      end)
    end
  end

  # -- 2. KD-15 challenge shape, byte-equal across auth modes ------------------------

  describe "KD-15 mode-blind challenge (AZB-08 falsifier face)" do
    test "tokenless /keys challenge is byte-equal in :enforce and :anonymous" do
      wa_by_mode =
        for mode <- [:enforce, :anonymous], into: %{} do
          SmaltTest.Env.with([auth_mode: mode], fn ->
            res = call(:get, "/keys", headers: [{"authorization", ""}])

            assert res.status == 401, "mode #{mode}: expected 401, got #{res.status}"

            case get_resp_header(res, "www-authenticate") do
              [wa] ->
                {mode, wa}

              other ->
                flunk("mode #{mode}: expected exactly ONE www-authenticate, got #{inspect(other)}")
            end
          end)
        end

      assert wa_by_mode[:enforce] == wa_by_mode[:anonymous],
             "challenge header must be BYTE-EQUAL across auth modes"

      # KD-15 grammar (rewrite-drafts/auth-wire-egress.md §0.2, verbatim).
      wa = wa_by_mode[:enforce]
      assert wa =~ ~s(error="invalid_token")
      assert wa =~ ~s(error_description="MissingBearerToken")
      assert wa =~ ~r/^Bearer authorization="[^"]+"/
      assert wa =~ ~r/resource="https?:\/\/[^"]+"/
    end

    test "challenge resource echoes the request origin; no authorization_uri" do
      res =
        conn(:get, "/keys")
        |> then(fn c -> %Plug.Conn{c | host: "vault.smalt.local", port: 8443} end)
        |> EgressRouter.call(@opts)

      assert res.status == 401
      [wa] = get_resp_header(res, "www-authenticate")

      assert wa =~ ~s(resource="http://vault.smalt.local:8443")
      refute wa =~ "authorization_uri"
    end

    test "authenticated KV call passes the guard (challenge-leg non-vacuity)" do
      res = call(:get, "/keys", headers: bearer(mint()))

      assert res.status == 200, "authenticated /keys must admit, got #{res.status}"
      assert get_resp_header(res, "www-authenticate") == []
    end
  end

  # -- 3. STS mint TTL (AZB-08 profile key) ------------------------------------------

  describe "STS mint TTL (AZB-08 profile key)" do
    test "mint honors token_ttl_seconds in exp-iat and expires_in" do
      SmaltTest.Env.with([sts: [token_ttl_seconds: 1234]], fn ->
        arm_conn = mint_via_arm()

        assert arm_conn.status == 200, "STS mint failed: #{arm_conn.resp_body}"
        body = Jason.decode!(arm_conn.resp_body)
        assert body["expires_in"] == 1234
        assert body["ext_expires_in"] == 1234

        {:ok, claims} = Joken.peek_claims(body["access_token"])
        assert claims["exp"] - claims["iat"] == 1234
      end)
    end

    test "default TTL stays 3600 when the profile key is absent (pinion: exp-iat==3600)" do
      prev = Application.get_env(:smalt, :sts, :__unset__)
      Application.delete_env(:smalt, :sts) # isolation-court: exempt delete-then-restore

      on_exit(fn ->
        if prev == :__unset__,
          do: Application.delete_env(:smalt, :sts),
          else: Application.put_env(:smalt, :sts, prev)
      end)

      arm_conn = mint_via_arm()

      assert arm_conn.status == 200, "STS mint failed: #{arm_conn.resp_body}"
      body = Jason.decode!(arm_conn.resp_body)
      assert body["expires_in"] == 3600

      {:ok, claims} = Joken.peek_claims(body["access_token"])
      assert claims["exp"] - claims["iat"] == 3600
    end

    defp mint_via_arm do
      conn(
        :post,
        "/oauth2/v2.0/token",
        "grant_type=client_credentials&client_id=azb8&client_secret=dev"
      )
      |> put_req_header("content-type", "application/x-www-form-urlencoded; charset=UTF-8")
      |> then(fn c -> %Plug.Conn{c | host: "arm.smalt.local", port: 19_081} end)
      |> Smalt.ArmGateway.Router.call([])
    end
  end

  # -- 4. injected-clock TTL expiry (falsifier: expired token admitted) ----------------

  describe "injected-clock expiry" do
    test "expired token refused TokenExpired when the injected clock moves past exp" do
      now = clock()
      token = mint(%{"exp" => now + 60})

      # Clock at mint+30: token ADMITS (proves the injected clock is THE
      # verify clock — a sleep-free positive control on the same subject).
      res_admit =
        SmaltTest.Env.with([sts_clock: now + 30], fn ->
          call(:get, "/keys", headers: bearer(token))
        end)

      assert res_admit.status == 200,
             "token valid at injected now+30 must admit, got #{res_admit.status}: #{res_admit.resp_body}"

      # Clock at exp+1: refused TokenExpired.
      res_expired =
        SmaltTest.Env.with([sts_clock: now + 61], fn ->
          call(:get, "/keys", headers: bearer(token))
        end)

      assert res_expired.status == 401
      [wa] = get_resp_header(res_expired, "www-authenticate")
      assert wa =~ ~s(error_description="TokenExpired")
      assert json(res_expired)["error"]["message"] == "TokenExpired"
    end
  end

  # -- 5. rotation ----------------------------------------------------------------

  describe "key rotation" do
    test "re-create issues a new version; old version still decrypts; GET returns latest" do
      name = "azb8-rot-#{System.unique_integer([:positive])}"
      plain = Base.encode64("azb8 rotation payload")

      # v1: create + encrypt under the then-latest version.
      v1 = create_key(name)
      v1_version = version_of(v1["kid"])
      assert v1["kid"] == latest_kid(name)

      ct1 =
        crypto(:post, "/keys/#{name}/#{v1_version}/encrypt", %{
          "alg" => "RSA-OAEP-256",
          "value" => plain
        })

      assert ct1["kid"] == v1["kid"]

      # Rotate: re-create issues a NEW version; bare-name row becomes v2.
      v2 = create_key(name)
      assert v2["kid"] != v1["kid"], "rotation must issue a NEW version"
      assert latest_kid(name) == v2["kid"]

      # OLD version still decrypts (versioned route, v1 material).
      pt1 =
        crypto(:post, "/keys/#{name}/#{v1_version}/decrypt", %{
          "alg" => "RSA-OAEP-256",
          "value" => ct1["value"]
        })

      assert pt1["value"] == plain, "old version must still decrypt its own ciphertext"

      # ...and the NEW version decrypts too (latest material).
      ct2 = crypto(:post, "/keys/#{name}/encrypt", %{"alg" => "RSA-OAEP-256", "value" => plain})

      assert ct2["kid"] == v2["kid"]

      pt2 =
        crypto(:post, "/keys/#{name}/#{version_of(v2["kid"])}/decrypt", %{
          "alg" => "RSA-OAEP-256",
          "value" => ct2["value"]
        })

      assert pt2["value"] == plain
    end

    test "versions listing carries every issued version" do
      name = "azb8-rot2-#{System.unique_integer([:positive])}"
      v1 = create_key(name)
      v2 = create_key(name)

      conn = call(:get, "/keys/#{name}/versions", headers: bearer(mint()))
      assert conn.status == 200
      kids = Enum.map(json(conn)["value"], & &1["kid"])

      assert v1["kid"] in kids and v2["kid"] in kids
    end

    defp create_key(name) do
      conn = call(:post, "/keys/#{name}/create", body: %{"kty" => "RSA"}, headers: bearer(mint()))
      assert conn.status == 200, "create failed: #{conn.resp_body}"
      json(conn)
    end

    defp latest_kid(name) do
      conn = call(:get, "/keys/#{name}", headers: bearer(mint()))
      assert conn.status == 200, "GET /keys/#{name} failed: #{conn.resp_body}"
      json(conn)["kid"]
    end

    defp crypto(method, path, params) do
      conn = call(method, path, body: params, headers: bearer(mint()))
      assert conn.status == 200, "crypto #{path} failed: #{conn.resp_body}"
      json(conn)
    end
  end

  # -- 6. api_version read site ------------------------------------------------------

  describe "api_version read site" do
    test "InvalidApiVersion message names the configured api_version" do
      res =
        SmaltTest.Env.with([keyvault: [api_version: "7.5", challenge_mode: :strict_bearer]], fn ->
          call(:post, "/keys/azb8-rel/release?api-version=6.0", headers: bearer(mint()))
        end)

      assert res.status == 400
      assert json(res)["error"]["message"] =~ "api-version=7.5"
    end
  end
end
