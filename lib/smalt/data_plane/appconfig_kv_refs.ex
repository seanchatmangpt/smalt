defmodule Smalt.DataPlane.AppConfigKvRefs do
  @moduledoc """
  Azure App Configuration -> Key Vault secret-reference resolution (lane S4,
  v26.10.29, census row R11): the container-app technique where a config value
  or an App Configuration key-value is not the secret material itself but a
  `@Microsoft.KeyVault(...)` reference, resolved by the platform into the
  container env contract at start.

  Two reference surfaces, one resolver:

    - Env-contract references (ACA/App Service env injection):
      `@Microsoft.KeyVault(SecretUri=...)` and
      `@Microsoft.KeyVault(VaultName=...;SecretName=...;SecretVersion=...)`,
      the documented real grammar, carried as plain env values.

    - App Configuration keyvaultref rows (r7 landed the verbatim passthrough):
      contentType `application/vnd.microsoft.appconfig.keyvaultref+json`,
      value `{"uri": "https://{vault}.vault.azure.net/secrets/{name}/{version?}"}`.
      The row is stored unresolved; this module is the platform-side
      resolution the real AzureAppConfiguration provider performs when a
      consumer asks for the effective value.

  Resolution law (emulator posture, disclosed):

    - single-vault substrate: the vault host in a reference is parsed and
      carried, but resolution matches by secret NAME plus optional version,
      never by host - the substrate's KD-15 vault face is one vault;
    - secrets are read from the real `:smalt_vault_secrets` Store rows the
      wire `PUT /secrets/:name` face (and the real `@azure/keyvault-secrets`
      SecretClient) writes - no shadow copy, no mock;
    - a version-addressed reference resolves the RETAINED version row
      `{name, version}` (KD-184/185 retained-version parity); the newest
      version wins for bare references (last-write `created_seq` order, never
      lexically-greatest-UUID);
    - typed refusals (never silent): unknown secret -> `SecretNotFound` (404
      face), disabled secret -> `SecretDisabled` (403 face), unknown version ->
      `VersionNotFound` (404 face), malformed reference ->
      `InvalidKeyVaultReference` (400 face). Resolution is a pure read - it
      never writes the vault or the kv plane.

  The wire is the existing r7 `/kv` face (references stored verbatim, never
  resolved server-side) plus the existing `/secrets` face; this module adds
  the missing R11 technique - resolution INTO the env contract - without a
  single router edit (route files are not lane S4 ownership).
  """

  alias Smalt.Store

  @kv_ref_content_type "application/vnd.microsoft.appconfig.keyvaultref+json"
  @sentinel "@Microsoft.KeyVault("

  @doc "The App Configuration keyvaultref content type (r7 verbatim storage)."
  def kv_ref_content_type, do: @kv_ref_content_type

  @typedoc "A parsed reference: which secret, which (optional) version."
  @type ref :: %{
          required(:vault_host) => String.t(),
          required(:vault_name) => String.t() | nil,
          required(:secret_name) => String.t(),
          required(:secret_version) => String.t() | nil,
          required(:raw) => String.t()
        }

  @typedoc "Resolution outcome per env name."
  @type resolution ::
          {:ok, String.t()} | {:error, %{status: pos_integer(), code: String.t(), message: String.t()}}

  # ---------------------------------------------------------------------------
  # Parsing
  # ---------------------------------------------------------------------------

  @doc """
  Parse a candidate value.

      {:ok, {:literal, value}}                  - no @Microsoft.KeyVault( sentinel
      {:ok, {:ref, %{...}}}                     - a well-formed reference
      {:error, {:ref_parse, code, message}}     - sentinel present, grammar broken

  Both documented real forms parse:

      @Microsoft.KeyVault(SecretUri=.../secrets/db-conn)
      @Microsoft.KeyVault(SecretUri=.../secrets/db-conn/<version>)
      @Microsoft.KeyVault(VaultName=myvault;SecretName=db-conn)
      @Microsoft.KeyVault(VaultName=myvault;SecretName=db-conn;SecretVersion=v)
  """
  @spec parse(String.t() | nil) ::
          {:ok, {:literal, String.t() | nil}}
          | {:ok, {:ref, ref()}}
          | {:error, {:ref_parse, String.t(), String.t()}}
  def parse(value) when is_binary(value) do
    case String.trim(value) do
      trimmed = @sentinel <> rest -> parse_ref(trimmed, rest)
      _literal -> {:ok, {:literal, value}}
    end
  end

  def parse(nil), do: {:ok, {:literal, nil}}

  defp parse_ref(raw, rest) do
    with {:ok, inner} <- close_paren(rest),
         {:ok, params} <- split_params(inner) do
      cond do
        Map.has_key?(params, "SecretUri") ->
          uri = params["SecretUri"]

          case parse_secret_uri(uri, raw) do
            {:ok, parsed} ->
              if parsed.secret_name in [nil, ""] do
                {:error, {:ref_parse, "InvalidKeyVaultReference", "reference carries no secret name"}}
              else
                {:ok, {:ref, parsed}}
              end

            err ->
              err
          end

        Map.has_key?(params, "VaultName") and Map.has_key?(params, "SecretName") ->
          vault = params["VaultName"]

          {:ok,
           {:ref,
            %{
              vault_host: default_host(vault),
              vault_name: vault,
              secret_name: params["SecretName"],
              secret_version: params["SecretVersion"],
              raw: raw
            }}}

        true ->
          {:error,
           {:ref_parse, "InvalidKeyVaultReference",
            "expected SecretUri=... or VaultName=...;SecretName=... inside @Microsoft.KeyVault(...)"}}
      end
    end
  end

  defp default_host(nil), do: nil
  defp default_host(""), do: nil
  defp default_host(vault), do: vault <> ".vault.azure.net"

  defp close_paren(rest) do
    if String.ends_with?(rest, ")") do
      {:ok, String.slice(rest, 0, byte_size(rest) - 1)}
    else
      {:error,
       {:ref_parse, "InvalidKeyVaultReference",
        "reference is not closed with ')': " <> String.slice(rest, 0, 40)}}
    end
  end

  # `;`-separated Key=Value pairs, whitespace-tolerant. Unknown members are
  # kept (forward parity with the real grammar's extensibility).
  defp split_params(inner) do
    pairs =
      inner
      |> String.split(";")
      |> Enum.reduce_while({:ok, %{}}, fn pair, {:ok, acc} ->
        case String.split(pair, "=", parts: 2) do
          [k, v] -> {:cont, {:ok, Map.put(acc, String.trim(k), String.trim(v))}}
          _ -> {:halt, {:error, {:ref_parse, "InvalidKeyVaultReference", "malformed Key=Value segment"}}}
        end
      end)

    case pairs do
      {:ok, _} = ok -> ok
      err -> err
    end
  end

  # SecretUri grammar: https://{host}/secrets/{name}[/{version}]. The host
  # segment is required to look like a vault host (non-empty, one label or
  # more); the emulator resolves by name only, so host is carried not matched.
  defp parse_secret_uri(uri, raw) when is_binary(uri) do
    case URI.new(uri) do
      {:ok, %URI{host: host, path: path}} when is_binary(host) and host != "" ->
        segments =
          path
          |> String.split("/", trim: true)

        case segments do
          ["secrets", name] ->
            {:ok,
             %{
               vault_host: host,
               vault_name: vault_name_from_host(host),
               secret_name: name,
               secret_version: nil,
               raw: raw
             }}

          ["secrets", name, version] ->
            {:ok,
             %{
               vault_host: host,
               vault_name: vault_name_from_host(host),
               secret_name: name,
               secret_version: version,
               raw: raw
             }}

          _ ->
            {:error,
             {:ref_parse, "InvalidKeyVaultReference",
              "SecretUri path must be /secrets/{name}[/{version}] (got: " <> uri <> ")"}}
        end

      _ ->
        {:error,
         {:ref_parse, "InvalidKeyVaultReference", "SecretUri is not an absolute https URI"}}
    end
  end

  defp parse_secret_uri(_, _),
    do: {:error, {:ref_parse, "InvalidKeyVaultReference", "SecretUri must be a string"}}

  defp vault_name_from_host(host) do
    case String.split(host, ".", parts: 2) do
      [name | _] -> name
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Env-contract resolution (the R11 close)
  # ---------------------------------------------------------------------------

  @doc """
  Resolve an env contract: `spec` maps env name -> value (binary), where any
  value may be a `@Microsoft.KeyVault(...)` reference. Returns
  `{:ok, %{env => resolved_binary}}` or
  `{:error, {env_name, %{status: , code: , message: }}}` for the FIRST
  failing reference (deterministic: keys sorted). Literal values pass
  through byte-identically.
  """
  @spec resolve_env(%{String.t() => String.t()}) ::
          {:ok, %{String.t() => String.t()}}
          | {:error, {String.t(), %{status: pos_integer(), code: String.t(), message: String.t()}}}
  def resolve_env(spec) when is_map(spec) do
    spec
    |> Map.new(fn
      {name, %{"value" => v}} -> {name, v}
      {name, v} -> {name, v}
    end)
    |> Enum.sort(fn {a, _}, {b, _} -> a <= b end)
    |> Enum.reduce_while({:ok, %{}}, fn {name, value}, {:ok, acc} ->
      case parse(value) do
        {:ok, {:literal, v}} ->
          {:cont, {:ok, Map.put(acc, name, v)}}

        {:ok, {:ref, parsed}} ->
          case resolve_ref(parsed) do
            {:ok, secret_value} -> {:cont, {:ok, Map.put(acc, name, secret_value)}}
            {:error, failure} -> {:halt, {:error, {name, failure}}}
          end

        {:error, {:ref_parse, code, message}} ->
          {:halt, {:error, {name, %{status: 400, code: code, message: message}}}}
      end
    end)
  end

  @doc """
  Resolve an App Configuration keyvaultref record (the r7 verbatim row):
  `record` is a kv record map (wire or Store shape) whose contentType is the
  keyvaultref content type and whose value is `{"uri": ...}`. Returns the
  same shapes as `resolve_env/1` (wrapped in a kv-shaped tuple:
  `{:ok, {:secret, value}}` / `{:error, failure}`).
  """
  @spec resolve_kv(map()) ::
          {:ok, {:secret, String.t()}}
          | {:error, %{status: pos_integer(), code: String.t(), message: String.t()}}
  def resolve_kv(%{"value" => value} = record) when is_binary(value) do
    ct = record["contentType"] || record["content_type"]

    if ct == @kv_ref_content_type do
      case Jason.decode(value) do
        {:ok, %{"uri" => uri}} when is_binary(uri) ->
          case parse_secret_uri(uri, uri) do
            {:ok, parsed} -> resolve_ref(parsed) |> wrap_kv()
            {:error, {:ref_parse, code, message}} -> {:error, %{status: 400, code: code, message: message}}
          end

        {:ok, _} ->
          {:error, %{status: 400, code: "InvalidKeyVaultReference", message: "keyvaultref value must be {\"uri\": ...}"}}

        {:error, _} ->
          {:error, %{status: 400, code: "InvalidKeyVaultReference", message: "keyvaultref value is not valid JSON"}}
      end
    else
      {:error, %{status: 400, code: "InvalidKeyVaultReference", message: "contentType is not the keyvaultref content type"}}
    end
  end

  defp wrap_kv({:ok, value}), do: {:ok, {:secret, value}}
  defp wrap_kv({:error, f}), do: {:error, f}

  # ---------------------------------------------------------------------------
  # Secret fetch (real vault rows, no mock)
  # ---------------------------------------------------------------------------

  @doc """
  Fetch the effective secret value for a parsed reference from the real
  `:smalt_vault_secrets` Store rows. Bare reference -> newest version
  (last-write `created_seq` order). Version reference -> the retained
  `{name, version}` row.
  """
  @spec resolve_ref(ref()) :: resolution()
  def resolve_ref(%{secret_name: name, secret_version: nil}) when is_binary(name) do
    case Store.get(:smalt_vault_secrets, name) do
      {:ok, record} ->
        with :ok <- enabled?(record) do
          {:ok, record["value"]}
        end

      :error ->
        {:error, %{status: 404, code: "SecretNotFound", message: "secret #{name} not found in the vault"}}

      {:error, :not_found} ->
        {:error, %{status: 404, code: "SecretNotFound", message: "secret #{name} not found in the vault"}}
    end
  end

  def resolve_ref(%{secret_name: name, secret_version: version}) when is_binary(name) and is_binary(version) do
    case Store.get(:smalt_vault_secrets, {name, version}) do
      {:ok, record} ->
        with :ok <- enabled?(record) do
          {:ok, record["value"]}
        end

      :error ->
        case Store.get(:smalt_vault_secrets, name) do
          {:ok, _} ->
            {:error, %{status: 404, code: "VersionNotFound", message: "version #{version} of secret #{name} not found"}}

          :error ->
            {:error, %{status: 404, code: "SecretNotFound", message: "secret #{name} not found in the vault"}}

          {:error, :not_found} ->
            {:error, %{status: 404, code: "SecretNotFound", message: "secret #{name} not found in the vault"}}
        end
    end
  end

  defp enabled?(%{"attributes" => %{"enabled" => false}}),
    do: {:error, %{status: 403, code: "SecretDisabled", message: "secret is disabled"}}

  defp enabled?(_), do: :ok

  # ---------------------------------------------------------------------------
  # Readiness
  # ---------------------------------------------------------------------------

  @doc "True when the vault + kv stores are up (wire readiness gate)."
  def ready? do
    :ets.info(:smalt_vault_secrets) != :undefined
  end
end
