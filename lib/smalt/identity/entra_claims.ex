defmodule Smalt.Identity.EntraClaims do
  @moduledoc """
  Entra claim-shaping for the consumer contract (lane S3, r16; census row R7).

  The consumer `courtroom-platform-az` reads EXACTLY the attribute URIs in
  `apps/api/src/claims.ts` (`CLAIMS` map). This module mints those claim
  shapes so the consumer's `mapProfile/authorizationDenial` sees the real
  Entra attribute surface: groups with GUID casing (the consumer lowercases
  for its policy compare), the app-role `role` claim, objectidentifier and
  tenantid (the tid claim scopes the consumer's tenant-fence law:
  `tenant_mismatch` when the minted tenantid differs from the configured
  `ENTRA_TENANT_ID`), `authnmethodsreferences`, and the `groups.link`
  overage signal.

  ## Delegation contract (R7 integration point)

  `SamlIdp.assertion_xml/3` (L16-owned file, read-only for this lane) still
  mints its single `Name="groups"` basic attribute. This module is the
  Entra-shaped shaping the mint path can delegate to; the one-line swap in
  `SamlIdp` is:

      attributes = Smalt.Identity.EntraClaims.attribute_statement_xml(%{})

  `Smalt.Identity.EntraSaml` already mints through this module.

  Config `config :smalt, :entra_identity, ...`:

    * `:tenant_id`  - tenant GUID minted into tenantid (default
      `"11111111-1111-4111-8111-111111111111"`). The consumer lowercases
      and fences on it.
    * `:object_id`  - the user's Entra objectId GUID.
    * `:upn` / `:display_name` / `:email` / `:given_name` / `:surname`
    * `:groups`     - group GUID list (GUID casing preserved; the consumer
      lowercases for its policy compare).
    * `:roles`      - app-role values for the role claim (case preserved;
      the consumer compares `AUTH_ALLOWED_ROLES` verbatim).
    * `:auth_methods` - authnmethodsreferences values (Entra emits
      `http://schemas.microsoft.com/claims/pwd` for password sign-in).
    * `:groups_overage` - when true, mint `groups.link` (the consumer's
      groupsOverage signal; its denial law requires the assertion to carry
      `groups.link` with NO `groups`).
  """

  @displayname_uri "http://schemas.microsoft.com/identity/claims/displayname"
  @name_uri "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/name"
  @email_uri "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"
  @givenname_uri "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname"
  @surname_uri "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname"
  @objectidentifier_uri "http://schemas.microsoft.com/identity/claims/objectidentifier"
  @tenantid_uri "http://schemas.microsoft.com/identity/claims/tenantid"
  @amr_uri "http://schemas.microsoft.com/claims/authnmethodsreferences"
  @groups_uri "http://schemas.microsoft.com/ws/2008/06/identity/claims/groups"
  @groups_link_uri "http://schemas.microsoft.com/claims/groups.link"
  @role_uri "http://schemas.microsoft.com/ws/2008/06/identity/claims/role"

  @tenant_default "11111111-1111-4111-8111-111111111111"
  @object_default "22222222-2222-4222-8222-222222222222"
  @upn_default "smalt.user@tenanta.example"
  @display_default "Smalt User"
  @email_default "smalt.user@tenanta.example"
  @given_default "Smalt"
  @surname_default "User"
  @groups_default [
    "33333333-3333-4333-8333-333333333331",
    "33333333-3333-4333-8333-333333333332"
  ]
  @roles_default ["Admin"]
  @auth_methods_default ["http://schemas.microsoft.com/claims/pwd"]

  @spec claim_uris() :: %{optional(atom()) => String.t()}
  @doc "The exact claim URIs the consumer reads - mirror of claims.ts CLAIMS."
  def claim_uris do
    %{
      displayname: @displayname_uri,
      name: @name_uri,
      email: @email_uri,
      givenname: @givenname_uri,
      surname: @surname_uri,
      objectidentifier: @objectidentifier_uri,
      tenantid: @tenantid_uri,
      authnmethodsreferences: @amr_uri,
      groups: @groups_uri,
      groups_link: @groups_link_uri,
      role: @role_uri
    }
  end

  @doc """
  Resolves the effective Entra user shape: `opts` overrides over
  `config :smalt, :entra_identity` over defaults. Returns the normalized
  claim-set map used by the SAML attribute mint (`attribute_statement_xml/1`)
  and by the MSI/ACA token face (`Smalt.Identity.AcaIdentity`).
  """
  @spec resolve(keyword()) :: map()
  def resolve(opts \\ []) when is_list(opts) do
    cfg = Application.get_env(:smalt, :entra_identity, [])

    %{
      tenant_id: Keyword.get(cfg, :tenant_id, @tenant_default),
      object_id: Keyword.get(cfg, :object_id, @object_default),
      upn: Keyword.get(cfg, :upn, shape_upn()),
      display_name: Keyword.get(cfg, :display_name, @display_default),
      email: Keyword.get(cfg, :email, @email_default),
      given_name: Keyword.get(cfg, :given_name, @given_default),
      surname: Keyword.get(cfg, :surname, @surname_default),
      groups: Keyword.get(cfg, :groups, @groups_default),
      roles: Keyword.get(cfg, :roles, @roles_default),
      auth_methods: Keyword.get(cfg, :auth_methods, @auth_methods_default),
      groups_overage: Keyword.get(cfg, :groups_overage, false)
    }
    |> merge_overrides(opts)
  end

  defp shape_upn, do: @upn_default

  defp merge_overrides(claims, opts) do
    Enum.reduce(opts, claims, fn
      {k, v}, acc
      when k in [:tenant_id, :object_id, :upn, :display_name, :email, :given_name, :surname] and is_binary(v) ->
        Map.put(acc, k, v)

      {k, v}, acc when k in [:groups, :roles, :auth_methods] and is_list(v) ->
        Map.put(acc, k, v)

      {:groups_overage, v}, acc when is_boolean(v) ->
        Map.put(acc, :groups_overage, v)

      _other, acc ->
        acc
    end)
  end

  @doc """
  The full Entra-shaped `<saml:AttributeStatement>` for the claim set.
  Multi-valued claims (groups, role, authnmethodsreferences) emit ONE
  `<saml:Attribute>` with multiple `<saml:AttributeValue>` children - the
  Entra wire shape node-saml maps to profile arrays.
  """
  @spec attribute_statement_xml(keyword() | map()) :: String.t()
  def attribute_statement_xml(opts \\ [])

  def attribute_statement_xml(opts) when is_list(opts) do
    opts |> resolve() |> attribute_xml()
  end

  def attribute_statement_xml(%{} = claims) do
    attribute_xml(claims)
  end

  defp attribute_xml(claims) do
    inner =
      claims
      |> attribute_list()
      |> Enum.map(&attribute_element/1)
      |> Enum.join()

    "<saml:AttributeStatement>" <> inner <> "</saml:AttributeStatement>"
  end

  @doc """
  The resolved claims as `%{name => values}` bundles (multi-valued claims
  keep all values, order preserved). Empty-valued claims are dropped.
  """
  @spec attribute_list(keyword() | map()) :: [%{name: String.t(), values: [String.t()]}]
  def attribute_list(opts \\ [])

  def attribute_list(opts) when is_list(opts), do: opts |> resolve() |> attribute_list()

  def attribute_list(%{} = claims) do
    Enum.reject(
      [
        %{name: @displayname_uri, values: [claims.display_name]},
        %{name: @name_uri, values: [claims.upn]},
        %{name: @email_uri, values: [claims.email]},
        %{name: @givenname_uri, values: [claims.given_name]},
        %{name: @surname_uri, values: [claims.surname]},
        %{name: @objectidentifier_uri, values: [claims.object_id]},
        %{name: @tenantid_uri, values: [claims.tenant_id]},
        %{name: @amr_uri, values: claims.auth_methods},
        %{name: @groups_uri, values: claims.groups},
        %{name: @groups_link_uri, values: overage_values(claims)},
        %{name: @role_uri, values: claims.roles}
      ],
      fn %{values: values} -> values in [[], nil] end
    )
  end

  defp overage_values(%{groups_overage: true}), do: ["1"]
  defp overage_values(_), do: []

  defp attribute_element(%{name: name, values: values}) do
    children =
      values
      |> Enum.map(&~s(<saml:AttributeValue>#{xml_escape(&1)}</saml:AttributeValue>))
      |> Enum.join()

    ~s(<saml:Attribute Name="#{xml_escape(name)}" NameFormat="urn:oasis:names:tc:SAML:2.0:attrname-format:basic">#{children}</saml:Attribute>)
  end

  defp xml_escape(v) when is_binary(v) do
    v
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
