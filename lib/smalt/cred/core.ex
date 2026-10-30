defmodule Smalt.Cred.Core do
  @moduledoc """
  Neutral credential core model (gap 09 phase 2, spec:
  `docs/jira/v26.10.31/gaps/09-credential-core-model.md`).

  This module is dialect-agnostic by construction: it names NO cloud vendor,
  NO vendor URL, NO vendor claim name. The only literals are the substrate's
  own env keys and atoms. All vendor rendering lives in a `DialectMapper`
  implementation (the dialect-1 mapper module under `lib/smalt/cred/dialect/`).

  Vocabulary (spec §1):

      CredentialRequest :: {
        principal   : PrincipalId            # opaque; dialect renders natively
        auth_factor : {:shared_secret, SecretRef}
        audience    : Scope
        tenant      : TenantKey              # opaque authority-namespace key
      }

  Field laws:

  - `principal` is opaque. Core never parses or validates its form.
  - `auth_factor` is a reference, never a value. SecretRef values resolve only
    at the wire boundary, dialect-side; `{:literal, v}` is dev/substrate mode
    only and is refused at the core boundary in enforce mode.
  - `audience` is a core `Scope`, never a URL. URL rendering is dialect-side
    (`scope_binding/1`).
  - `tenant` reads ONE canonical env key: `SMALT_TENANT_ID`. Legacy aliases are
    dialect-config concerns, never core config.
  """

  @canonical_tenant_env "SMALT_TENANT_ID"

  @typedoc "Opaque principal identity — no GUID semantics in core."
  @type principal_id :: binary

  @typedoc "Opaque authority-namespace key — no GUID semantics in core."
  @type tenant_key :: binary

  @type secret_ref :: {:env, binary} | {:file, binary} | {:literal, binary}

  @type scope :: :control_plane | {:data_plane, resource :: binary} | {:dialect, atom, binary}

  @type t :: %__MODULE__{
          principal: principal_id(),
          auth_factor: {:shared_secret, secret_ref()},
          audience: scope(),
          tenant: tenant_key()
        }

  @enforce_keys [:principal, :auth_factor, :audience, :tenant]
  defstruct [:principal, :auth_factor, :audience, :tenant]

  @doc "The ONE canonical tenant env key. Dialect aliases live dialect-side."
  @spec canonical_tenant_env() :: binary
  def canonical_tenant_env, do: @canonical_tenant_env

  @doc """
  Reads the tenant key from the canonical env. Legacy alias envs are NEVER
  read here (field law 4).
  """
  @spec tenant_from_env() :: {:ok, tenant_key()} | {:error, :tenant_env_missing}
  def tenant_from_env do
    case System.get_env(@canonical_tenant_env) do
      nil -> {:error, :tenant_env_missing}
      "" -> {:error, :tenant_env_missing}
      v -> {:ok, v}
    end
  end

  @doc """
  Validates a request against the field laws. Returns `:ok` or a typed
  refusal — the core never repairs or coerces.
  """
  @spec validate(t()) :: :ok | {:refused, term()}
  def validate(%__MODULE__{principal: p, auth_factor: af, audience: s, tenant: t} = req) do
    with :ok <- opaque(p, :principal),
         :ok <- shared_secret(af),
         :ok <- scope(s),
         :ok <- opaque(t, :tenant),
         :ok <- literal_law(af) do
      literal_enforce_law(req)
    end
  end

  defp opaque(v, _field) when is_binary(v) and v != "", do: :ok
  defp opaque(_v, field), do: {:refused, {:field_not_opaque_binary, field}}

  defp shared_secret({:shared_secret, ref}) when is_tuple(ref), do: :ok
  defp shared_secret(_), do: {:refused, :auth_factor_not_shared_secret}

  defp scope(:control_plane), do: :ok
  defp scope({:data_plane, r}) when is_binary(r) and r != "", do: :ok
  defp scope({:dialect, name, s}) when is_atom(name) and is_binary(s), do: :ok
  defp scope(_), do: {:refused, :invalid_scope}

  # {:literal, v} is legal to CARRY in dev mode, refused to RESOLVE in enforce
  # mode (resolve_secret/2). Carrying is validated here; resolving is gated
  # there.
  defp literal_law({:shared_secret, {:literal, v}}) when is_binary(v) and v != "", do: :ok
  defp literal_law({:shared_secret, {:env, n}}) when is_binary(n) and n != "", do: :ok
  defp literal_law({:shared_secret, {:file, p}}) when is_binary(p) and p != "", do: :ok
  defp literal_law({:shared_secret, _}), do: {:refused, :invalid_secret_ref}

  defp literal_enforce_law(%__MODULE__{auth_factor: {:shared_secret, {:literal, _}}}) do
    if enforce_mode?(),
      do: {:refused, :literal_secret_in_enforce_mode},
      else: :ok
  end

  defp literal_enforce_law(_), do: :ok

  @doc "Auth mode of the running substrate. `:enforce` is the default."
  @spec auth_mode() :: :enforce | :anonymous | atom()
  def auth_mode, do: Application.get_env(:smalt, :auth_mode, :enforce)

  @doc "True when the substrate runs in enforce mode (literal secrets refused)."
  @spec enforce_mode?() :: boolean()
  def enforce_mode?, do: auth_mode() == :enforce

  @doc """
  Resolves a SecretRef to bytes. Wire-boundary only: callers are dialect
  mappers at mint time. `{:literal, v}` is refused in enforce mode.
  """
  @spec resolve_secret(secret_ref(), :enforce | :dev | atom()) ::
          {:ok, binary()} | {:refused, term()}
  def resolve_secret({:env, name}, _mode) when is_binary(name) do
    case System.get_env(name) do
      nil -> {:refused, {:secret_env_missing, name}}
      "" -> {:refused, {:secret_env_missing, name}}
      v -> {:ok, v}
    end
  end

  def resolve_secret({:file, path}, _mode) when is_binary(path) do
    case File.read(path) do
      {:ok, v} -> {:ok, v}
      {:error, reason} -> {:refused, {:secret_file_unreadable, path, reason}}
    end
  end

  def resolve_secret({:literal, v}, mode) when is_binary(v) do
    if mode == :enforce,
      do: {:refused, :literal_secret_in_enforce_mode},
      else: {:ok, v}
  end

  def resolve_secret(_, _), do: {:refused, :invalid_secret_ref}

  # -- Core audience register (spec §1.1 "verify" row) -------------------------

  @doc """
  Registers a core scope in the verify-side audience register. `:control_plane`
  is always registered. Idempotent.
  """
  @spec register_audience(scope()) :: :ok
  def register_audience(scope) do
    known = Application.get_env(:smalt, :cred_audiences, [])
    Application.put_env(:smalt, :cred_audiences, Enum.uniq([scope | known]))
  end

  @doc "The verify-side audience register (core scopes, never URLs)."
  @spec known_audiences() :: [scope()]
  def known_audiences do
    Enum.uniq([:control_plane | Application.get_env(:smalt, :cred_audiences, [])])
  end

  @doc "Core scope check: is the audience in the register?"
  @spec audience_registered?(scope()) :: boolean()
  def audience_registered?(scope), do: scope in known_audiences()

  # -- Core challenge grammar (spec §1.1 "challenge" row; KD-15) ---------------

  @doc """
  Parses an enriched `WWW-Authenticate: Bearer` challenge into core fields.
  The grammar itself is vendor-neutral (see `Smalt.Auth.Bearer.challenge_value/2`):
  `authorization` names the issuer authority + tenant path, `resource` echoes
  the request origin. Both are core fields; any path-suffix or host rendering
  is dialect-side.
  """
  @spec parse_challenge(binary()) ::
          {:ok, %{authorization: binary(), resource: binary(), error: binary() | nil}}
          | {:error, :not_bearer_challenge}
  def parse_challenge("Bearer " <> rest) do
    params = parse_challenge_params(rest)

    case {params["authorization"], params["resource"]} do
      {auth, res} when is_binary(auth) and is_binary(res) ->
        {:ok, %{authorization: auth, resource: res, error: params["error"]}}

      _ ->
        {:error, :challenge_missing_core_fields}
    end
  end

  def parse_challenge(_), do: {:error, :not_bearer_challenge}

  defp parse_challenge_params(rest) do
    rest
    |> String.split(",", trim: true)
    |> Enum.reduce(%{}, fn part, acc ->
      case String.split(String.trim(part), "=", parts: 2) do
        [k, v] -> Map.put(acc, String.trim(k), String.trim(v, ~s(")))
        _ -> acc
      end
    end)
  end

  # -- DialectMapper behaviour (spec §1.1 seam contract) -----------------------

  @doc """
  The dialect seam. The core plane never sees: form field names, grant_type
  values, native scope strings, vendor URL shapes. The dialect never sees:
  SecretRef values, core scope atoms (beyond the 3 callbacks), core issuer
  config.
  """
  @callback to_wire(t(), wire_ctx :: map()) ::
              {:ok, wire_request :: map()} | {:refused, term()}

  @callback from_claim(claim :: map()) ::
              {:ok, {principal_id(), scope(), tenant_key()}} | {:error, term()}

  @callback scope_binding(scope()) ::
              {:ok, native_scope :: binary()} | {:error, term()}
end
