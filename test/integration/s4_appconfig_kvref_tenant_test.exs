# Lane S4 integration court (v26.10.29, census row R11 close):
# App Configuration + Key Vault reference technique.
#
# Chicago discipline: every collaborator is real — real vault rows written
# through the live /secrets wire face (the exact path the real
# @azure/keyvault-secrets SecretClient exercises), real /kv rows through the
# live /kv face (the exact path @azure/app-configuration exercises), real
# :smalt_vault_secrets / :smalt_appconfig Store tables, real resolution
# engine (Smalt.DataPlane.AppConfigKvRefs) and real tenant projection
# (Smalt.DataPlane.AppConfigTenant). No mocks. In-process dispatch
# (Smalt.EgressRouter.call) — the same wire code the node courts hit over
# TCP (r17 receipt, appconfig-kvref-court.mjs).

defmodule Smalt.Internal.S4AppconfigKvrefTenantTest do
  use ExUnit.Case, async: false

  import Plug.Test

  alias Smalt.AppConfigRevisions
  alias Smalt.DataPlane.AppConfigFeatures
  alias Smalt.DataPlane.AppConfigKvRefs
  alias Smalt.DataPlane.AppConfigSnapshots
  alias Smalt.DataPlane.AppConfigTenant
  alias Smalt.Store

  @kv_ref_ct "application/vnd.microsoft.appconfig.keyvaultref+json"
  @slug "s4-court-tenant"
  @cert_keys [
    "tenant/displayName",
    "tenant/hostnames/canonical",
    "tenant/hostnames/redirects",
    "tenant/loginMethods",
    "tenant/access",
    "tenant/SAML_IDP_CERT"
  ]
  @ff_access "access.allowed-groups"
  @ff_login "loginMethods.entra-saml"

  setup do
    uniq = :erlang.unique_integer([:positive])
    cert_name = "s4-saml-idp-cert-#{uniq}"
    on_exit(fn ->
      Store.delete(:smalt_vault_secrets, cert_name)
      Enum.each(@cert_keys, fn k -> Store.delete(:smalt_appconfig, {k, @slug}) end)
      Store.delete(:smalt_appconfig, {@ff_access, @slug})
      Store.delete(:smalt_appconfig, {@ff_login, @slug})
    end)
    {:ok, cert_name: cert_name, uniq: uniq}
  end

  defp kv_req(method, path, body \\ nil, headers \\ []) do
    conn =
      if body do
        conn(method, path, Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
      else
        conn(method, path)
      end

    conn =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer smalt-s4-court")
      |> then(fn c ->
        Enum.reduce(headers, c, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)
      end)

    Smalt.EgressRouter.call(Plug.Conn.fetch_query_params(conn), [])
  end

  # Writes the SAML_IDP_CERT-shaped secret through the REAL /secrets wire
  # face (same path the node-22 SecretClient court uses over TCP) and
  # returns the secret bundle id.
  defp put_cert_secret!(cert_name, pem) do
    conn = kv_req(:put, "/secrets/#{cert_name}", %{"value" => pem, "contentType" => "application/x-pem-file"})
    assert conn.status in [200, 201], "secret PUT failed: #{conn.status}"
    bundle = Jason.decode!(conn.resp_body)
    bundle["id"]
  end

  defp cert_body do
    case File.read(".smalt/tls/dev-cert.pem") do
      {:ok, pem} -> pem
      _ -> "-----BEGIN CERTIFICATE-----\nS4COURT\n-----END CERTIFICATE-----\n"
    end
  end

  test "env-contract resolution: @Microsoft.KeyVault ref resolves the real vault row into SAML_IDP_CERT", %{cert_name: cert_name} do
    pem = cert_body()
    secret_id = put_cert_secret!(cert_name, pem)

    env_spec = %{
      "SESSION_SECRET" => "lit-0123456789abcdef",
      "PORT" => "8080",
      "SAML_IDP_CERT" => "@Microsoft.KeyVault(SecretUri=" <> secret_id <> ")",
      "SAML_ENTRY_POINT" => "@Microsoft.KeyVault(VaultName=smalt-vault;SecretName=" <> cert_name <> ")"
    }

    assert {:ok, resolved} = AppConfigKvRefs.resolve_env(env_spec)
    assert resolved["SAML_IDP_CERT"] == pem
    assert resolved["SAML_ENTRY_POINT"] == pem
    assert resolved["SESSION_SECRET"] == "lit-0123456789abcdef"
    assert resolved["PORT"] == "8080"
  end

  test "typed refusals: SecretNotFound / InvalidKeyVaultReference / SecretDisabled / VersionNotFound", %{cert_name: cert_name} do
    # missing secret
    assert {:error, {"SAML_IDP_CERT", %{status: 404, code: "SecretNotFound"}}} =
             AppConfigKvRefs.resolve_env(%{
               "SAML_IDP_CERT" => "@Microsoft.KeyVault(SecretUri=https://smalt-vault.vault.azure.net/secrets/s4-nope-#{:erlang.unique_integer([:positive])})"
             })

    # malformed grammar (unclosed paren)
    assert {:error, {"SAML_IDP_CERT", %{status: 400, code: "InvalidKeyVaultReference"}}} =
             AppConfigKvRefs.resolve_env(%{
               "SAML_IDP_CERT" => "@Microsoft.KeyVault(SecretUri=https://v.vault.azure.net/secrets/x"
             })

    # disabled secret: create then PATCH enabled=false via the wire
    pem = cert_body()
    put_cert_secret!(cert_name, pem)
    patch_conn = kv_req(:patch, "/secrets/#{cert_name}", %{"attributes" => %{"enabled" => false}})
    assert patch_conn.status == 200, "PATCH failed: #{patch_conn.status}"

    assert {:error, {"SAML_IDP_CERT", %{status: 403, code: "SecretDisabled"}}} =
             AppConfigKvRefs.resolve_env(%{
               "SAML_IDP_CERT" => "@Microsoft.KeyVault(VaultName=smalt-vault;SecretName=" <> cert_name <> ")"
             })
  end

  test "version-addressed ref resolves the RETAINED version row; unknown version is typed 404", %{cert_name: cert_name} do
    v1_pem = cert_body()
    conn1 = kv_req(:put, "/secrets/#{cert_name}", %{"value" => v1_pem})
    assert conn1.status in [200, 201]
    v1 = Jason.decode!(conn1.resp_body) |> Map.fetch!("id") |> String.split("/") |> List.last()

    v2_pem = String.replace(v1_pem, "-----BEGIN", "-----V2BEGIN") <> "\n"
    conn2 = kv_req(:put, "/secrets/#{cert_name}", %{"value" => v2_pem})
    assert conn2.status in [200, 201]
    v2 = Jason.decode!(conn2.resp_body) |> Map.fetch!("id") |> String.split("/") |> List.last()
    assert v2 != v1

    ref = "@Microsoft.KeyVault(SecretUri=https://smalt-vault.vault.azure.net/secrets/" <> cert_name <> "/" <> v1 <> ")"
    assert {:ok, %{"SAML_IDP_CERT" => ^v1_pem}} = AppConfigKvRefs.resolve_env(%{"SAML_IDP_CERT" => ref})

    stale_ref =
      "@Microsoft.KeyVault(SecretUri=https://smalt-vault.vault.azure.net/secrets/" <> cert_name <> "/deadbeefdeadbeefdeadbeefdeadbeef)"

    assert {:error, {"SAML_IDP_CERT", %{status: 404, code: "VersionNotFound"}}} =
             AppConfigKvRefs.resolve_env(%{"SAML_IDP_CERT" => stale_ref})
  end

  test "keyvaultref kv row: r7 verbatim storage + platform-side resolution into the env value", %{cert_name: cert_name} do
    pem = cert_body()
    secret_id = put_cert_secret!(cert_name, pem)
    ref_value = Jason.encode!(%{"uri" => secret_id})

    kv_key_encoded = String.replace("tenant/SAML_IDP_CERT", "/", "%2F")

    put_conn =
      kv_req(
        :put,
        "/kv/#{kv_key_encoded}?label=#{@slug}",
        %{"value" => ref_value, "contentType" => @kv_ref_ct},
        [{"if-none-match", "*"}]
      )

    assert put_conn.status == 201, "kv PUT failed: #{put_conn.status} #{inspect(put_conn.resp_body)}"

    get_conn = kv_req(:get, "/kv/#{kv_key_encoded}?label=#{@slug}")
    assert get_conn.status == 200
    row = Jason.decode!(get_conn.resp_body)
    assert row["value"] == ref_value
    assert row["content_type"] == @kv_ref_ct

    assert {:ok, {:secret, ^pem}} = AppConfigKvRefs.resolve_kv(row)
  end

  test "tenant projection: put_config -> get_config fold-back, flags drive loginMethods/access", %{cert_name: cert_name} do
    pem = cert_body()
    secret_id = put_cert_secret!(cert_name, pem)

    tenant = %{
      "slug" => @slug,
      "displayName" => "Court 9 — Judge Assignment",
      "hostnames" => %{"canonical" => "court9.example.test", "redirects" => ["court9-alias.example.test"]},
      "loginMethods" => ["entra-saml"],
      "access" => "allowed-groups",
      "saml_idp_cert_uri" => secret_id
    }

    assert {:ok, summary} = AppConfigTenant.put_config(tenant)
    assert summary.slug == @slug
    assert summary.kv_rows == 6
    assert summary.flags == 2

    assert {:ok, folded} = AppConfigTenant.get_config(@slug)
    assert folded["displayName"] == "Court 9 — Judge Assignment"
    assert folded["hostnames"] == %{"canonical" => "court9.example.test", "redirects" => ["court9-alias.example.test"]}
    assert folded["loginMethods"] == ["entra-saml"]
    assert folded["access"] == "allowed-groups"
    assert folded["saml_idp_cert_uri"] == secret_id

    # flags drive the effective loginMethods / access mode (checkmark law)
    assert AppConfigTenant.login_methods(@slug) == ["entra-saml"]
    assert AppConfigTenant.access_mode(@slug) == "allowed-groups"

    # flag flip OFF: access drops to assigned-users (flag-first law)
    assert {:ok, _} = AppConfigFeatures.put_flag("access.allowed-groups", %{"enabled" => false, "conditions" => %{"client_filters" => []}}, @slug, %{})
    assert AppConfigTenant.access_mode(@slug) == "assigned-users"

    # the flag rows are visible on the REAL /kv wire face exactly as the
    # @azure client reads them (reserved prefix + ff content type)
    ff_key = String.replace(".appconfig.featureflag/access.allowed-groups", "/", "%2F")
    ff_conn = kv_req(:get, "/kv/#{ff_key}?label=#{@slug}")
    assert ff_conn.status == 200
    ff_row = Jason.decode!(ff_conn.resp_body)
    assert ff_row["content_type"] =~ "application/vnd.microsoft.appconfig.ff+json"
    ff = Jason.decode!(ff_row["value"])
    assert ff["enabled"] == false

    # tenant zod validation: illegal access mode is a typed 400 face
    assert {:error, {"InvalidTenant", _}} = AppConfigTenant.put_config(%{tenant | "access" => "open-door"})
  end

  test "tenant rows have revisions depth + snapshot freeze (as the real client lists them)", %{} do
    tenant = %{
      "slug" => @slug,
      "displayName" => "Court 9",
      "hostnames" => %{"canonical" => "court9.example.test", "redirects" => []},
      "loginMethods" => ["entra-saml"],
      "access" => "assigned-users"
    }

    assert {:ok, _} = AppConfigTenant.put_config(tenant)
    assert {:ok, _} = AppConfigTenant.put_config(%{tenant | "displayName" => "Court 9 v2"})

    revs =
      AppConfigRevisions.list(%{key: "tenant/*", label: @slug})

    assert length(revs) >= 5
    # history GROWS across re-provision (etag-identical rows do not re-record)
    assert {:ok, _} = AppConfigTenant.put_config(%{tenant | "displayName" => "Court 9 v3"})
    revs2 = AppConfigRevisions.list(%{key: "tenant/*", label: @slug})
    assert length(revs2) > length(revs)
    assert Enum.any?(revs, &(&1["value"] == "Court 9 v2"))

    # snapshot freeze: filters select tenant/* under the tenant label
    snap = "s4-tenant-snap-#{:erlang.unique_integer([:positive])}"
    assert {:ok, rec} =
             AppConfigSnapshots.create(
               snap,
               %{"filters" => [%{"key" => "tenant/", "label" => @slug}]},
               Store.list_all(:smalt_appconfig)
             )

    assert rec["status"] == "ready"
    assert rec["itemCount"] >= 5
    assert {:ok, items} = AppConfigSnapshots.kv_view(snap)
    assert Enum.any?(items, &(&1["key"] == "tenant/access"))
  end

  test "label isolation: a second tenant's rows never leak across slugs", %{} do
    slug_a = @slug
    slug_b = "s4-court-tenant-b"

    tenant_a = %{
      "slug" => slug_a,
      "displayName" => "Tenant A",
      "hostnames" => %{"canonical" => "a.example.test", "redirects" => []},
      "loginMethods" => ["entra-saml"],
      "access" => "allowed-groups"
    }

    tenant_b = %{
      "slug" => slug_b,
      "displayName" => "Tenant B",
      "hostnames" => %{"canonical" => "b.example.test", "redirects" => []},
      "loginMethods" => ["entra-saml"],
      "access" => "assigned-users"
    }

    assert {:ok, _} = AppConfigTenant.put_config(tenant_a)
    assert {:ok, _} = AppConfigTenant.put_config(tenant_b)

    assert {:ok, a} = AppConfigTenant.get_config(slug_a)
    assert {:ok, b} = AppConfigTenant.get_config(slug_b)
    assert a["displayName"] == "Tenant A"
    assert b["displayName"] == "Tenant B"
    assert a["access"] == "allowed-groups"
    assert b["access"] == "assigned-users"

    on_exit(fn ->
      Enum.each(@cert_keys, fn k -> Store.delete(:smalt_appconfig, {k, slug_b}) end)
      Store.delete(:smalt_appconfig, {@ff_access, slug_b})
      Store.delete(:smalt_appconfig, {@ff_login, slug_b})
    end)
  end
end
