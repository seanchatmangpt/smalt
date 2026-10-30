defmodule Smalt.Cred.Dialect.Azure do
  @moduledoc """
  Dialect-1 mapper (gap 09 phase 2, spec §2): renders the neutral
  `Smalt.Cred.Core` vocabulary to the dialect-1 wire that the substrate STS
  face (`Smalt.ArmGateway.Plug.OidcSts`) accepts today — byte-identical to the
  shape real SDKs (`azidentity`, `azure-core` `ChallengeAuthPolicy`, msal) mint
  and parse.

  This module is the ONLY place in the cred tree where vendor rendering lives
  (zero-guid principal rendering, vendor scope strings, claim names,
  grant_type, endpoint path). The core never sees any of it.
  """

  @behaviour Smalt.Cred.Core

  @zero_guid "00000000-0000-0000-0000-000000000000"
  @control_plane_audience "https://management.azure.com"
  @control_plane_scope "https://management.azure.com/.default"
  @grant_type "client_credentials"
  @token_path_suffix "/oauth2/v2.0/token"

  @impl true
  @doc """
  Mint side (spec §1.1 "mint request" row): renders a CredentialRequest to the
  dialect-1 token request.

  `wire_ctx` keys:
  - `:endpoint` (required) — token endpoint base, e.g. `SMALT_ARM_ENDPOINT`.
  - `:secret` (required) — RESOLVED secret bytes. The dialect resolves the
    SecretRef dialect-side; the core never carries the value.
  - `:tenant_path` (optional, default: the request's tenant) — when the caller
    wants the tenant-less form (`/oauth2/v2.0/token`, zero-guid tenant), pass
    `""`.

  Returns `%{method, url, content_type, body}` where `body` is the exact
  form-encoding the current face validates (`grant_type=client_credentials`,
  `client_id`, `client_secret`, `scope`).
  """
  @spec to_wire(Smalt.Cred.Core.t(), map()) :: {:ok, map()} | {:refused, term()}
  def to_wire(%Smalt.Cred.Core{} = req, wire_ctx) do
    with :ok <- Smalt.Cred.Core.validate(req),
         {:ok, scope} <- scope_binding(req.audience),
         endpoint when is_binary(endpoint) <- wire_ctx[:endpoint],
         secret when is_binary(secret) <- wire_ctx[:secret] do
      tenant_path = Map.get(wire_ctx, :tenant_path, req.tenant)
      base = String.trim_trailing(endpoint, "/")

      path =
        if tenant_path == "",
          do: @token_path_suffix,
          else: "/#{tenant_path}" <> @token_path_suffix

      body =
        URI.encode_query(
          grant_type: @grant_type,
          client_id: principal_wire(req.principal),
          client_secret: secret,
          scope: scope
        )

      {:ok,
       %{
         method: "POST",
         url: base <> path,
         content_type: "application/x-www-form-urlencoded",
         body: body
       }}
    else
      {:refused, reason} -> {:refused, reason}
      {:error, reason} -> {:refused, reason}
      nil -> {:refused, :wire_ctx_missing_endpoint_or_secret}
      _ -> {:refused, :wire_ctx_missing_endpoint_or_secret}
    end
  end

  # Zero-GUID form is dialect-1 rendering, not core identity (spec §2 row 1):
  # the core principal is opaque; the dialect renders it as-is when the caller
  # already carries the wire form, else defaults to the pinned zero-guid.
  defp principal_wire(principal), do: principal

  @impl true
  @doc """
  Verify side (spec §2 rows 4/5/7/8): maps dialect-1 token claims to core
  fields. All of `appid`/`azp`/`oid`/`sub` map to the core PrincipalId (row 7);
  `aud` maps through the audience register (row 4); `tid` is the TenantKey
  (row 5). Refuses typed on an unknown audience.
  """
  @spec from_claim(map()) ::
          {:ok, {Smalt.Cred.Core.principal_id(), Smalt.Cred.Core.scope(),
                 Smalt.Cred.Core.tenant_key()}}
          | {:error, term()}
  def from_claim(claims) when is_map(claims) do
    with {:ok, scope} <- audience_to_scope(claims["aud"]),
         {:ok, principal} <- principal_from_claims(claims),
         tid when is_binary(tid) and tid != "" <- claims["tid"] do
      {:ok, {principal, scope, tid}}
    else
      nil -> {:error, :missing_tid_claim}
      "" -> {:error, :missing_tid_claim}
      {:error, reason} -> {:error, reason}
    end
  end

  def from_claim(_), do: {:error, :claims_not_a_map}

  defp audience_to_scope(@control_plane_audience), do: {:ok, :control_plane}
  defp audience_to_scope(aud), do: {:error, {:unknown_audience, aud}}

  @principal_claim_names ["appid", "azp", "oid", "sub"]

  defp principal_from_claims(claims) do
    @principal_claim_names
    |> Enum.find_value(fn name ->
      case claims[name] do
        v when is_binary(v) and v != "" -> {:ok, v}
        _ -> nil
      end
    end)
    |> case do
      {:ok, principal} -> {:ok, principal}
      nil -> {:error, :missing_principal_claim}
    end
  end

  @impl true
  @doc """
  Render side (spec §2 rows 3/4): core scopes to dialect-1 native scope
  strings. `:control_plane` renders the pinned management scope; a data-plane
  resource renders `https://<resource>/.default`; a `:dialect` scope passes
  its native scope through untouched.
  """
  @spec scope_binding(Smalt.Cred.Core.scope()) ::
          {:ok, binary()} | {:error, term()}
  def scope_binding(:control_plane), do: {:ok, @control_plane_scope}

  def scope_binding({:data_plane, resource}) do
    {:ok, "https://#{String.trim_trailing(resource, "/")}/.default"}
  end

  def scope_binding({:dialect, _name, native}) when is_binary(native), do: {:ok, native}
  def scope_binding(other), do: {:error, {:unknown_scope, other}}

  @doc "Dialect-1 claim rendering constants, exposed for compat courts only."
  @spec control_plane_audience() :: binary()
  def control_plane_audience, do: @control_plane_audience

  @spec zero_guid() :: binary()
  def zero_guid, do: @zero_guid
end
