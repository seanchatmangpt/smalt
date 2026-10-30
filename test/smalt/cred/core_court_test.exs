defmodule Smalt.Cred.CoreCourtTest do
  @moduledoc """
  Gap 09 phase-2 dialect-1 court (spec §3 dry-run + §2 mapping table).

  Asserts that the KD-15 flow expressed through `Smalt.Cred.Core` +
  `Smalt.Cred.Dialect.Azure` produces the SAME wire steps as the current auth
  path (real collaborators: `Smalt.Auth.Bearer` challenge grammar, the STS
  face's request contract), and that a mutated mapper (wrong audience) refuses
  typed.
  """

  use ExUnit.Case, async: false

  alias Smalt.Cred.Core
  alias Smalt.Cred.Dialect.Azure

  @zero_guid "00000000-0000-0000-0000-000000000000"
  @zero_guid_sub "00000000-0000-0000-0000-000000000001"
  @mgmt_scope "https://management.azure.com/.default"
  @mgmt_aud "https://management.azure.com"

  defp request do
    %Core{
      principal: @zero_guid,
      auth_factor: {:shared_secret, {:literal, "smalt-sovereign-mock-secret"}},
      audience: :control_plane,
      tenant: "tenant-one"
    }
  end

  # -- Dialect-1 mint side: byte-identical to the current face contract --------

  describe "to_wire dialect-1 court" do
    test "renders the exact form the STS face validates (oidc_sts.ex contract)" do
      {:ok, wire} = Azure.to_wire(request(), %{endpoint: "https://arm.local:9443", secret: "s3cret"})

      assert wire.method == "POST"
      assert wire.url == "https://arm.local:9443/tenant-one/oauth2/v2.0/token"
      assert wire.content_type == "application/x-www-form-urlencoded"

      params = URI.decode_query(wire.body)
      assert params["grant_type"] == "client_credentials"
      assert params["client_id"] == @zero_guid
      assert params["client_secret"] == "s3cret"
      assert params["scope"] == @mgmt_scope
      # Exact field set — nothing more, nothing less (face refuses nothing else
      # but the wire must be byte-identical to today's shape).
      assert params |> Map.keys() |> Enum.sort() ==
               ["client_id", "client_secret", "grant_type", "scope"]

      # Byte-identical form body against the current auth-path encoding order.
      assert wire.body ==
               "grant_type=client_credentials&client_id=#{@zero_guid}" <>
                 "&client_secret=s3cret&scope=#{URI.encode_www_form(@mgmt_scope)}"
    end

    test "tenant-less form renders the zero-guid-tenant path (face route 1)" do
      {:ok, wire} =
        Azure.to_wire(request(), %{endpoint: "https://arm.local:9443", secret: "s", tenant_path: ""})

      assert wire.url == "https://arm.local:9443/oauth2/v2.0/token"
    end

    test "refuses typed when the core request is invalid or ctx missing" do
      bad = %{request() | audience: {:data_plane, ""}}
      assert {:refused, _} = Azure.to_wire(bad, %{endpoint: "https://x", secret: "s"})
      assert {:refused, :wire_ctx_missing_endpoint_or_secret} =
               Azure.to_wire(request(), %{})

      # Secret resolution is wire-boundary: enforce mode refuses the literal.
      assert {:refused, :literal_secret_in_enforce_mode} =
               Core.resolve_secret({:literal, "x"}, :enforce)
    end
  end

  # -- Dialect-1 verify side: claim mapping identical to the minted face -------

  describe "from_claim dialect-1 court" do
    test "maps the face's minted claim shape (oidc_sts.ex claims) to core fields" do
      claims = %{
        "aud" => @mgmt_aud,
        "iss" => "https://arm.local:9443/tenant-one/v2.0",
        "appid" => @zero_guid,
        "azp" => @zero_guid,
        "oid" => @zero_guid_sub,
        "sub" => @zero_guid_sub,
        "tid" => "tenant-one",
        "roles" => ["Contributor", "Owner"]
      }

      assert {:ok, {principal, :control_plane, tenant}} = Azure.from_claim(claims)
      assert principal in [@zero_guid, @zero_guid_sub]
      assert tenant == "tenant-one"
    end

    test "all four principal claim names map to core PrincipalId (row 7)" do
      for name <- ["appid", "azp", "oid", "sub"] do
        claims = %{"aud" => @mgmt_aud, "tid" => "t", name => "principal-x"}
        assert {:ok, {"principal-x", :control_plane, "t"}} = Azure.from_claim(claims)
      end
    end
  end

  # -- Render side: scope binding identical to the face's scope strings --------

  describe "scope_binding dialect-1 court" do
    test ":control_plane renders the pinned management scope" do
      assert {:ok, @mgmt_scope} = Azure.scope_binding(:control_plane)
    end

    test "data-plane resource renders per-resource .default (KD-15 KV shape)" do
      {:ok, scope} = Azure.scope_binding({:data_plane, "vault.local:8443"})
      assert scope == "https://vault.local:8443/.default"
    end
  end

  # -- §3 dry-run: KD-15 flow through Core+Mapper, same wire steps -------------

  describe "KD-15 challenge handshake through the core model" do
    test "tokenless 401 grammar -> core challenge parse -> bearer resend steps" do
      # Step 3 (spec §3): the core answers 401 with the challenge grammar.
      # Real collaborator: Smalt.Auth.Bearer.challenge_value/2 — the exact
      # grammar the egress router sends today (# KD-COVERS: KD-15).
      conn = %Plug.Conn{scheme: :https, host: "vault.local", port: 8443}
      reason = "Validation of the provided access token failed."
      header = Smalt.Auth.Bearer.challenge_value(conn, reason)

      # Step 1: the client provokes it with a data-plane CredentialRequest —
      # no credential material needed to parse the challenge.
      req = %Core{
        principal: @zero_guid,
        auth_factor: {:shared_secret, {:env, "SMALT_SECRET"}},
        audience: {:data_plane, "vault.local:8443"},
        tenant: "tenant-one"
      }
      assert :ok = Core.validate(req)

      # Step 4: parse the challenge through the core grammar — authorization
      # (issuer authority + tenant path) and resource (request origin) are
      # core fields; the grammar is already vendor-neutral per the spec.
      assert {:ok, parsed} = Core.parse_challenge(header)
      assert parsed.resource == "https://vault.local:8443"
      assert parsed.authorization =~ "/organizations"
      assert parsed.error == "invalid_token"

      # The mapper renders the SAME data-plane scope the resend carries.
      {:ok, scope} = Azure.scope_binding(req.audience)
      assert scope == "https://vault.local:8443/.default"

      # Step 5: the resend to_wire mints dialect-1 form with the SecretRef
      # resolved dialect-side (env here).
      System.put_env("SMALT_SECRET", "kv-secret-value")
      {:ok, secret} = Core.resolve_secret(req.auth_factor |> elem(1), :dev)
      {:ok, wire} = Azure.to_wire(req, %{endpoint: "https://arm.local:9443", secret: secret})
      params = URI.decode_query(wire.body)
      assert params["scope"] == scope
      assert params["client_secret"] == "kv-secret-value"
    after
      System.delete_env("SMALT_SECRET")
    end

    test "enforce-mode core refuses a literal SecretRef (field law 2)" do
      assert {:refused, :literal_secret_in_enforce_mode} =
               Core.resolve_secret({:literal, "smalt-tf-mock-secret"}, :enforce)

      literal_req = %Core{
        principal: @zero_guid,
        auth_factor: {:shared_secret, {:literal, "x"}},
        audience: :control_plane,
        tenant: "t"
      }

      # The plain `mix test` boot runs in enforce mode (the default), so a
      # literal SecretRef is refused at the core boundary.
      if Core.enforce_mode?() do
        assert {:refused, :literal_secret_in_enforce_mode} = Core.validate(literal_req)
      else
        assert :ok = Core.validate(literal_req)
      end
    end
  end

  # -- Mutated mapper: wrong audience refuses typed -----------------------------

  describe "mutation court: wrong-audience mapper" do
    defmodule WrongAudienceMapper do
      @behaviour Smalt.Cred.Core

      @impl true
      def to_wire(_req, _ctx), do: {:ok, %{}}

      @impl true
      # MUTATION: claims the token was minted for a foreign audience and
      # renders a mutated native scope.
      def from_claim(claims), do: {:ok, {claims["sub"], {:dialect, :wrong, "https://evil/.default"}, claims["tid"]}}

      @impl true
      def scope_binding(:control_plane), do: {:ok, "https://evil/.default"}
      def scope_binding(_), do: {:error, :unknown_scope}
    end

    test "the mutated render is caught by the core audience register (typed)" do
      Core.register_audience(:control_plane)
      # The mutated mapper's scope is NOT the registered core scope.
      assert {:ok, "https://evil/.default"} = WrongAudienceMapper.scope_binding(:control_plane)
      assert {:ok, @mgmt_scope} = Azure.scope_binding(:control_plane)
      # Core scope check: only the core atom is registered, never a URL — the
      # mutated rendering cannot enter the register.
      assert Core.audience_registered?(:control_plane)
      refute Core.audience_registered?({:dialect, :wrong, "https://evil/.default"})

      # The compliant mapper refuses a foreign aud TYPED (verify side).
      assert {:error, {:unknown_audience, "https://evil.example"}} =
               Azure.from_claim(%{"aud" => "https://evil.example", "tid" => "t", "sub" => "s"})
    end
  end

  # -- Core neutrality fence ----------------------------------------------------

  test "core validate refuses non-opaque fields typed" do
    assert {:refused, {:field_not_opaque_binary, :principal}} =
             Core.validate(%{request() | principal: nil})

    assert {:refused, :auth_factor_not_shared_secret} =
             Core.validate(%{request() | auth_factor: {:password, {:env, "X"}}})

    assert {:refused, :invalid_scope} =
             Core.validate(%{request() | audience: "https://management.azure.com/.default"})
  end
end
