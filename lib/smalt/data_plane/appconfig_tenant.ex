defmodule Smalt.DataPlane.AppConfigTenant do
  @moduledoc """
  Per-tenant App Configuration technique (lane S4, v26.10.29, census rows
  R11+R14): the consumer's tenant-config zod contract
  (courtroom-platform-az packages/tenant-config/src/schema.ts — slug,
  displayName, hostnames {canonical, redirects}, loginMethods ["entra-saml"],
  access `assigned-users|allowed-groups`) projected onto the smalt App
  Configuration plane as per-tenant key-values + feature flags.

  Projection (label = tenant slug):

    tenant/displayName          text/plain
    tenant/hostnames/canonical  text/plain
    tenant/hostnames/redirects  application/json
    tenant/loginMethods         application/json
    tenant/access               text/plain
    tenant/SAML_IDP_CERT        keyvaultref+json (only when cert-uri supplied)

  Feature flags (label = slug, Microsoft.FeatureManagement semantics — the
  "checkmark" is the flag's enabled bit; filters AND-compose):

    loginMethods.entra-saml     enabled <=> entra-saml in loginMethods
    access.allowed-groups       enabled <=> access == allowed-groups

  Resolution law (flag-first, typed fallback):

    login_methods/1: flag enabled -> on; disabled -> off; :undefined (no
    flag row) -> kv row; absent -> default. access_mode/1: flag
    access.allowed-groups enabled -> allowed-groups; disabled ->
    assigned-users; :undefined -> kv row; absent -> default (the consumer
    zod default: an unknown tenant is assigned-users).

  All writes ride the lawful kv write path (AppConfigRevisions.write —
  Store.put + revision record) so tenant rows surface in the revisions
  history; flags ride AppConfigFeatures.put_flag (also revision-recorded).
  No router edit: the /kv, /snapshots and /secrets wire faces are existing
  capital (r7 + r9c), exercised live by the real @azure clients (receipt
  r17 courts).
  """

  alias Smalt.AppConfigRevisions
  alias Smalt.DataPlane.AppConfigFeatures
  alias Smalt.DataPlane.AppConfigKvRefs
  alias Smalt.Store

  @login_methods ["entra-saml"]
  @access_modes ["assigned-users", "allowed-groups"]
  @flag_login "loginMethods.entra-saml"
  @flag_access "access.allowed-groups"
  @cert_key "tenant/SAML_IDP_CERT"
  @kv_ref_ct AppConfigKvRefs.kv_ref_content_type()

  @doc """
  Provision (or re-provision) a tenant onto the appconfig plane. `tenant` is
  the consumer zod shape: %{"slug" => _, "displayName" => _, "hostnames" =>
  %{"canonical" => _, "redirects" => [_]}, "loginMethods" => [_],
  "access" => _, "saml_idp_cert_uri" => _ (optional)}.

  Returns {:ok, summary} with the written rows/flags or
  {:error, {code, message}} (typed 400 face).
  """
  @spec put_config(map()) :: {:ok, map()} | {:error, {String.t(), String.t()}}
  def put_config(tenant) when is_map(tenant) do
    with {:ok, slug} <- slug_of(tenant),
         {:ok, f} <- fields_of(tenant) do
      tags = %{"tenant" => slug}
      label = slug

      kv_rows =
        [
          {"tenant/displayName", f.display, "text/plain", tags},
          {"tenant/hostnames/canonical", f.canonical, "text/plain", tags},
          {"tenant/hostnames/redirects", Jason.encode!(f.redirects), "application/json", tags},
          {"tenant/loginMethods", Jason.encode!(f.methods), "application/json", tags},
          {"tenant/access", f.access, "text/plain", tags}
        ] ++
          case f.cert_uri do
            nil -> []
            uri -> [{@cert_key, Jason.encode!(%{"uri" => uri}), @kv_ref_ct, tags}]
          end

      flag_login = %{
        "enabled" => f.methods != [],
        "conditions" => %{"client_filters" => []}
      }

      flag_access = %{
        "enabled" => f.access == "allowed-groups",
        "conditions" => %{"client_filters" => []}
      }

      with :ok <- write_all(kv_rows, label),
           :ok <- put_flag(@flag_login, flag_login, label, tags),
           :ok <- put_flag(@flag_access, flag_access, label, tags) do
        {:ok, %{slug: slug, kv_rows: length(kv_rows), flags: 2}}
      end
    end
  end

  defp write_all(rows, label) do
    Enum.reduce_while(rows, :ok, fn {key, value, ct, row_tags}, :ok ->
      record = %{
        "key" => key,
        "label" => label,
        "value" => value,
        "contentType" => ct,
        "tags" => row_tags,
        "etag" => content_etag(key, label, value, ct),
        "new_etag" => true,
        "locked" => false,
        "last_modified" => System.system_time(:second)
      }

      existing = Store.get(:smalt_appconfig, {key, label})

      case AppConfigRevisions.write(key, label, existing, record) do
        {:ok, _} -> {:cont, :ok}
        _ -> {:halt, {:error, {"AppConfigWriteFailed", "write failed for " <> key}}}
      end
    end)
  end

  defp put_flag(name, flag, label, tags) do
    case AppConfigFeatures.put_flag(name, flag, label, tags) do
      {:ok, _} -> :ok
      {:error, _} = err -> err
    end
  end

  @doc """
  Read the tenant projection back: folds the tenant rows (label = slug) into
  the consumer zod shape. Unknown slug -> {:error, :not_found}.
  """
  @spec get_config(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_config(slug) when is_binary(slug) do
    with {:ok, display} <- read_row("tenant/displayName", slug),
         {:ok, canonical} <- read_row("tenant/hostnames/canonical", slug),
         {:ok, redirects} <- read_json_row("tenant/hostnames/redirects", slug),
         {:ok, methods} <- read_json_row("tenant/loginMethods", slug),
         {:ok, access} <- read_row("tenant/access", slug) do
      {:ok,
       %{
         "slug" => slug,
         "displayName" => display,
         "hostnames" => %{"canonical" => canonical, "redirects" => redirects},
         "loginMethods" => methods,
         "access" => access,
         "saml_idp_cert_uri" => cert_uri(slug)
       }}
    end
  end

  @doc """
  Effective login methods for a tenant (flag-first law). Defaults to
  ["entra-saml"] when nothing is provisioned (consumer zod: LOGIN_METHODS).
  """
  @spec login_methods(String.t()) :: [String.t()]
  def login_methods(slug) do
    case flag_on?(@flag_login, slug) do
      true ->
        @login_methods

      false ->
        []

      :undefined ->
        case read_json_row("tenant/loginMethods", slug) do
          {:ok, methods} when is_list(methods) ->
            Enum.filter(methods, &(&1 in @login_methods))

          _ ->
            @login_methods
        end
    end
  end

  @doc """
  Effective access mode for a tenant (flag-first law). Defaults to
  "assigned-users" (consumer zod default: unknown tenant is assigned-users).
  """
  @spec access_mode(String.t()) :: String.t()
  def access_mode(slug) do
    case flag_on?(@flag_access, slug) do
      true -> "allowed-groups"
      false -> "assigned-users"
      :undefined ->
        case read_row("tenant/access", slug) do
          {:ok, access} when access in @access_modes -> access
          _ -> "assigned-users"
        end
    end
  end

  # --- internals -----------------------------------------------------------

  defp slug_of(%{"slug" => slug}) when is_binary(slug) and byte_size(slug) > 0, do: {:ok, slug}
  defp slug_of(_), do: {:error, {"InvalidTenant", "tenant requires a non-empty string slug"}}

  defp fields_of(%{"slug" => slug} = tenant) do
    display = tenant["displayName"] || slug
    hostnames = tenant["hostnames"] || %{}
    canonical = hostnames["canonical"] || (slug <> ".example.test")
    redirects = hostnames["redirects"] || []
    methods = tenant["loginMethods"] || @login_methods
    access = tenant["access"] || "assigned-users"
    cert_uri = tenant["saml_idp_cert_uri"]

    with :ok <- check_methods(methods),
         :ok <- check_access(access),
         :ok <- check_redirects(canonical, redirects) do
      {:ok,
       %{
         display: display,
         canonical: canonical,
         redirects: redirects,
         methods: methods,
         access: access,
         cert_uri: cert_uri
       }}
    end
  end

  defp fields_of(_), do: {:error, {"InvalidTenant", "tenant requires a slug"}}

  defp check_methods(methods) when is_list(methods) do
    if methods != [] and Enum.all?(methods, &(&1 in @login_methods)) do
      :ok
    else
      {:error,
       {"InvalidTenant", "loginMethods must be a non-empty subset of " <> Enum.join(@login_methods, ", ")}}
    end
  end

  defp check_methods(_),
    do: {:error, {"InvalidTenant", "loginMethods must be a list"}}

  defp check_access(access) when access in @access_modes, do: :ok

  defp check_access(_),
    do: {:error, {"InvalidTenant", "access must be assigned-users or allowed-groups"}}

  defp check_redirects(canonical, redirects) when is_list(redirects) do
    if canonical in redirects do
      {:error,
       {"InvalidTenant", "canonical hostname must not also be listed as a redirect"}}
    else
      :ok
    end
  end

  defp check_redirects(_, _),
    do: {:error, {"InvalidTenant", "redirects must be a list"}}

  defp read_row(key, slug) do
    case Store.get(:smalt_appconfig, {key, slug}) do
      {:ok, rec} -> {:ok, rec["value"]}
      :error -> {:error, :not_found}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp read_json_row(key, slug) do
    case read_row(key, slug) do
      {:ok, value} ->
        case Jason.decode(value) do
          {:ok, decoded} -> {:ok, decoded}
          _ -> {:error, :not_found}
        end

      err ->
        err
    end
  end

  defp cert_uri(slug) do
    case read_row(@cert_key, slug) do
      {:ok, value} ->
        case Jason.decode(value) do
          {:ok, %{"uri" => uri}} -> uri
          _ -> nil
        end

      :error ->
        nil

      {:error, :not_found} ->
        nil
    end
  end

  defp flag_on?(name, slug) do
    case AppConfigFeatures.get_flag(name, slug) do
      {:ok, %{"enabled" => enabled}} -> enabled == true
      _ -> :undefined
    end
  end

  defp content_etag(key, label, value, ct) do
    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary({key, label, value, ct}))
      |> Base.encode16()

    "\"" <> hash <> "\""
  end
end
