defmodule Smalt.ServengineSim.ProdEnvContract do
  @moduledoc """
  Validates the full `xaas` `:prod` environment and secret contract before boot.

  Models the fail-closed `:prod` runtime requirements across `xaas/config/runtime.exs`,
  `xaas/lib/xaas/vault.ex`, `xaas/lib/xaas/secrets.ex`, `xaas/lib/xaas_web/router.ex`,
  `xaas/lib/xaas/serv_engine/prod_bootstrap.ex`, and
  `xaas/lib/xaas/serv_engine/commercial/changes/payment_method_sensitive_fields.ex`:

    * `DATABASE_URL` — valid `ecto`/`postgres`/`postgresql` URI with credentials,
      explicit host, non-empty database name, no Cloud SQL `?host=/cloudsql/...`
      query parameter (`GAP-SIM-RUNTIME-DB-URL`), and valid optional `socket_dir`.
    * `SECRET_KEY_BASE` — >= 64 bytes, refusing committed dev/test/placeholder values.
    * `CLOAK_KEY` — valid base64 decoding to 32 raw bytes (AES-256-GCM), refusing
      the committed dev placeholder in `Xaas.Vault`.
    * `BLIND_INDEX_KEY` — valid base64 decoding to >= 32 raw bytes, and distinct
      in raw bytes from `CLOAK_KEY` (HMAC-SHA256 pepper separation).
    * `USER_SOCKET_SALT` — >= 16 bytes, refusing committed endpoint/config salts.
    * `TOKEN_SIGNING_SECRET` — >= 32 bytes (JWT signing floor), refusing
      committed dev/test literals.
    * `A2A_BASE_URL` — `https://` URL with non-loopback host, non-root path, no
      trailing `/`, and no query/fragment (matches `router.ex` `<> "/..."` mounts).
    * `XAAS_A2A_*_KEY` (`XAAS_A2A_OUTBOX_KEY`, `XAAS_A2A_BINDING_KEY`,
      `XAAS_A2A_CLAIM_STORE_KEY`, plus any extra `XAAS_A2A_*_KEY` present) —
      valid base64 decoding to >= 32 raw bytes, refusing committed dev literals.
    * `ADMIN_PASSWORD` — non-blank, >= 8 trimmed bytes (matching
      `Xaas.ServEngine.ProdBootstrap`), refusing placeholders and weak defaults.

  Optionally (when `include_runtime_extras: true` or when present in `env`),
  also validates `ONETIME_REVOKE_KEY`, `INTERNAL_API_TOKEN`, `XAAS_A2A_DATA_DIR`,
  and `CORS_ORIGINS`.

  Findings never echo raw secret values so reports and exceptions are safe to log.
  """

  @core_vars [
    "DATABASE_URL",
    "SECRET_KEY_BASE",
    "CLOAK_KEY",
    "BLIND_INDEX_KEY",
    "USER_SOCKET_SALT",
    "TOKEN_SIGNING_SECRET",
    "A2A_BASE_URL",
    "XAAS_A2A_OUTBOX_KEY",
    "XAAS_A2A_BINDING_KEY",
    "XAAS_A2A_CLAIM_STORE_KEY",
    "ADMIN_PASSWORD"
  ]

  @a2a_key_vars [
    "XAAS_A2A_OUTBOX_KEY",
    "XAAS_A2A_BINDING_KEY",
    "XAAS_A2A_CLAIM_STORE_KEY"
  ]

  @runtime_extra_vars [
    "ONETIME_REVOKE_KEY",
    "INTERNAL_API_TOKEN",
    "XAAS_A2A_DATA_DIR",
    "CORS_ORIGINS"
  ]

  @a2a_key_pattern ~r/^XAAS_A2A_[A-Z0-9_]+_KEY$/

  # Committed dev/test literals in xaas that must never reach :prod.
  @forbidden_dev_literals %{
    "SECRET_KEY_BASE" => [
      "1Tm0Lz/glhTKmCnt284nv+OUGMvuNHo1IRWYFXkafdDX3E6frvnas0DBytqhJkQQ",
      "R0hv8DBm2eLIGQsu63NgN+Na/ZLpvVaZ0lU3P2XHhYL7qwQf4o802taC0lfEF12L"
    ],
    "CLOAK_KEY" => [
      "4T4/f5PYK0d489Do8sNU8VNJHKD/1XVOLXyzHUlIkQY="
    ],
    "USER_SOCKET_SALT" => [
      "8PSILiaE",
      "27Dz+bCC"
    ],
    "TOKEN_SIGNING_SECRET" => [
      "xaas-dev-token-signing-secret-0123456789abcdef",
      "test-token-signing-secret-at-least-32-bytes-long-for-jwt-signing!!"
    ],
    "XAAS_A2A_OUTBOX_KEY" => [
      "xaas-dev-outbox-hmac-key-0123456789abcdef0123456789abcdef"
    ],
    "XAAS_A2A_BINDING_KEY" => [
      "xaas-dev-binding-hmac-key-0123456789abcdef0123456789abcdef"
    ],
    "XAAS_A2A_CLAIM_STORE_KEY" => [
      "xaas-dev-claimstore-hmac-key-0123456789abcdef0123456789abcdef"
    ],
    "ONETIME_REVOKE_KEY" => [
      "dev-only-onetime-revoke-key",
      "test-only-onetime-revoke-key-do-not-use-in-prod"
    ]
  }

  @cloak_placeholder_bytes Base.decode64!("4T4/f5PYK0d489Do8sNU8VNJHKD/1XVOLXyzHUlIkQY=")

  @weak_passwords MapSet.new([
                    "password",
                    "password123",
                    "admin",
                    "admin123",
                    "changeme",
                    "12345678",
                    "secret123",
                    "xaas"
                  ])

  @forbidden_hosts MapSet.new([
                     "localhost",
                     "127.0.0.1",
                     "::1",
                     "0.0.0.0",
                     "example.com"
                   ])

  @placeholder_markers ["REPLACE_ME", "CHANGEME", "CHANGE_ME", "YOUR_SECRET_HERE"]

  @type finding_kind ::
          :missing
          | :placeholder_value
          | :forbidden_dev_default
          | :weak_default
          | :too_short
          | :invalid_base64
          | :invalid_key_length
          | :key_reuse_with_cloak_key
          | :invalid_uri
          | :invalid_scheme
          | :missing_credentials
          | :missing_host
          | :forbidden_host
          | :missing_database
          | :cloudsql_query_host_unsupported
          | :invalid_socket_dir
          | :invalid_path
          | :trailing_slash
          | :unexpected_query_or_fragment
          | :relative_path
          | :ephemeral_tmp_path
          | :wildcard_cors_origin
          | :insecure_cors_origin

  @type finding :: %{
          var: String.t(),
          kind: finding_kind(),
          reason: String.t()
        }

  @type report :: %{
          status: :ok | :refused,
          checked_vars: [String.t()],
          passed_vars: [String.t()],
          failed_vars: [String.t()],
          findings: [finding()],
          counts: %{optional(finding_kind()) => non_neg_integer()}
        }

  defmodule Error do
    @moduledoc "Raised by `Smalt.ServengineSim.ProdEnvContract.validate!/2` on refusal."
    defexception [:report]

    @impl true
    def message(%__MODULE__{report: report}) do
      Smalt.ServengineSim.ProdEnvContract.format_report(report)
    end
  end

  @doc "Canonical core `:prod` env/secret variable names."
  @spec required_vars(keyword()) :: [String.t()]
  def required_vars(opts \\ []) do
    if Keyword.get(opts, :include_runtime_extras, false) do
      @core_vars ++ @runtime_extra_vars
    else
      @core_vars
    end
  end

  @doc "Canonical `XAAS_A2A_*_KEY` variable names."
  @spec a2a_key_vars() :: [String.t()]
  def a2a_key_vars, do: @a2a_key_vars

  @doc "Committed `xaas` dev/test literal values refused in `:prod`."
  @spec dev_placeholders() :: %{String.t() => [String.t()]}
  def dev_placeholders, do: @forbidden_dev_literals

  @doc """
  Validates `env` (defaults to `System.get_env/0`) against the `xaas` `:prod`
  env+secret contract.

  Options:
    * `:include_runtime_extras` - when `true`, also requires `ONETIME_REVOKE_KEY`,
      `INTERNAL_API_TOKEN`, `XAAS_A2A_DATA_DIR`, and `CORS_ORIGINS` (default `false`).
  """
  @spec validate(map(), keyword()) :: {:ok, report()} | {:refused, report()}
  def validate(env \\ System.get_env(), opts \\ []) when is_map(env) and is_list(opts) do
    include_extras? = Keyword.get(opts, :include_runtime_extras, false)
    extra_a2a_keys = discover_extra_a2a_keys(env)

    checked_vars =
      required_vars(include_runtime_extras: include_extras?)
      |> Kernel.++(extra_a2a_keys)
      |> Kernel.++(present_optional_extras(env, include_extras?))
      |> Enum.uniq()

    findings =
      []
      |> Kernel.++(check_database_url(Map.get(env, "DATABASE_URL")))
      |> Kernel.++(check_secret_key_base(Map.get(env, "SECRET_KEY_BASE")))
      |> Kernel.++(check_cloak_and_blind_index(Map.get(env, "CLOAK_KEY"), Map.get(env, "BLIND_INDEX_KEY")))
      |> Kernel.++(check_user_socket_salt(Map.get(env, "USER_SOCKET_SALT")))
      |> Kernel.++(check_token_signing_secret(Map.get(env, "TOKEN_SIGNING_SECRET")))
      |> Kernel.++(check_a2a_base_url(Map.get(env, "A2A_BASE_URL")))
      |> Kernel.++(check_a2a_keys(env, @a2a_key_vars ++ extra_a2a_keys))
      |> Kernel.++(check_admin_password(Map.get(env, "ADMIN_PASSWORD")))
      |> Kernel.++(check_runtime_extras(env, include_extras?))

    report = build_report(checked_vars, findings)

    case report.status do
      :ok -> {:ok, report}
      :refused -> {:refused, report}
    end
  end

  @doc """
  Like `validate/2`, returning the report on `:ok` or raising
  `Smalt.ServengineSim.ProdEnvContract.Error` on `:refused`.
  """
  @spec validate!(map(), keyword()) :: report()
  def validate!(env \\ System.get_env(), opts \\ []) do
    case validate(env, opts) do
      {:ok, report} -> report
      {:refused, report} -> raise Error, report: report
    end
  end

  @doc "Formats a human-readable summary of a validation report without leaking secret values."
  @spec format_report(report()) :: String.t()
  def format_report(%{status: :ok, checked_vars: vars}) do
    "PROD_ENV_CONTRACT OK: #{length(vars)} variable(s) validated, 0 findings"
  end

  def format_report(%{status: :refused, checked_vars: vars, findings: findings}) do
    lines =
      Enum.map(findings, fn %{var: var, kind: kind, reason: reason} ->
        "  - [#{kind}] #{var}: #{reason}"
      end)

    Enum.join(
      [
        "PROD_ENV_CONTRACT REFUSED: #{length(findings)} finding(s) across #{length(vars)} variable(s)"
        | lines
      ],
      "\n"
    )
  end

  # -- per-variable checks -----------------------------------------------------

  defp check_database_url(raw) do
    with {:ok, val} <- require_non_blank("DATABASE_URL", raw),
         :ok <- reject_placeholder("DATABASE_URL", val) do
      validate_database_uri(val)
    else
      {:finding, f} -> [f]
    end
  end

  defp validate_database_uri(raw) do
    uri = URI.parse(raw)
    query = if is_binary(uri.query), do: URI.decode_query(uri.query), else: %{}

    []
    |> add_if(
      uri.scheme not in ["ecto", "postgres", "postgresql"],
      finding("DATABASE_URL", :invalid_scheme, "scheme must be ecto, postgres, or postgresql")
    )
    |> add_if(
      not valid_userinfo?(uri.userinfo),
      finding("DATABASE_URL", :missing_credentials, "userinfo must supply non-empty user:password")
    )
    |> add_if(
      not non_blank?(uri.host),
      finding("DATABASE_URL", :missing_host, "URI host must be non-empty (Ecto.InvalidURLError)")
    )
    |> add_if(
      not valid_db_path?(uri.path),
      finding("DATABASE_URL", :missing_database, "URI path must include a non-empty database name")
    )
    |> add_if(
      Map.has_key?(query, "host"),
      finding(
        "DATABASE_URL",
        :cloudsql_query_host_unsupported,
        "query parameter ?host= is rejected by Ecto/Postgrex; use ?socket_dir=/cloudsql/..."
      )
    )
    |> add_if(
      Map.has_key?(query, "socket_dir") and not valid_socket_dir?(Map.get(query, "socket_dir")),
      finding(
        "DATABASE_URL",
        :invalid_socket_dir,
        "socket_dir query parameter must be an absolute path"
      )
    )
  end

  defp check_secret_key_base(raw) do
    check_min_length_secret("SECRET_KEY_BASE", raw, 64)
  end

  defp check_cloak_and_blind_index(cloak_raw, blind_raw) do
    {cloak_findings, cloak_bytes} = check_cloak_key(cloak_raw)
    {blind_findings, blind_bytes} = check_blind_index_key(blind_raw)

    separation_findings =
      if is_binary(cloak_bytes) and is_binary(blind_bytes) and
           Plug.Crypto.secure_compare(cloak_bytes, blind_bytes) do
        [
          finding(
            "BLIND_INDEX_KEY",
            :key_reuse_with_cloak_key,
            "BLIND_INDEX_KEY must be cryptographically separate from CLOAK_KEY"
          )
        ]
      else
        []
      end

    cloak_findings ++ blind_findings ++ separation_findings
  end

  defp check_cloak_key(raw) do
    with {:ok, val} <- require_non_blank("CLOAK_KEY", raw),
         :ok <- reject_placeholder("CLOAK_KEY", val),
         :ok <- reject_dev_literal("CLOAK_KEY", val),
         {:ok, bytes} <- decode_base64("CLOAK_KEY", val) do
      cond do
        Plug.Crypto.secure_compare(bytes, @cloak_placeholder_bytes) ->
          {[
             finding(
               "CLOAK_KEY",
               :forbidden_dev_default,
               "CLOAK_KEY must not match the committed Xaas.Vault dev placeholder"
             )
           ], bytes}

        byte_size(bytes) != 32 ->
          {[
             finding(
               "CLOAK_KEY",
               :invalid_key_length,
               "CLOAK_KEY must decode to exactly 32 raw bytes for AES-256-GCM"
             )
           ], bytes}

        true ->
          {[], bytes}
      end
    else
      {:finding, f} -> {[f], nil}
    end
  end

  defp check_blind_index_key(raw) do
    with {:ok, val} <- require_non_blank("BLIND_INDEX_KEY", raw),
         :ok <- reject_placeholder("BLIND_INDEX_KEY", val),
         {:ok, bytes} <- decode_base64("BLIND_INDEX_KEY", val) do
      if byte_size(bytes) < 32 do
        {[
           finding(
             "BLIND_INDEX_KEY",
             :invalid_key_length,
             "BLIND_INDEX_KEY must decode to >= 32 raw bytes for HMAC-SHA256"
           )
         ], bytes}
      else
        {[], bytes}
      end
    else
      {:finding, f} -> {[f], nil}
    end
  end

  defp check_user_socket_salt(raw) do
    check_min_length_secret("USER_SOCKET_SALT", raw, 16)
  end

  defp check_token_signing_secret(raw) do
    check_min_length_secret("TOKEN_SIGNING_SECRET", raw, 32)
  end

  defp check_a2a_base_url(raw) do
    with {:ok, val} <- require_non_blank("A2A_BASE_URL", raw),
         :ok <- reject_placeholder("A2A_BASE_URL", val) do
      validate_a2a_uri(val)
    else
      {:finding, f} -> [f]
    end
  end

  defp validate_a2a_uri(raw) do
    uri = URI.parse(raw)

    []
    |> add_if(
      uri.scheme != "https",
      finding("A2A_BASE_URL", :invalid_scheme, "A2A_BASE_URL must use https scheme in :prod")
    )
    |> add_if(
      not non_blank?(uri.host),
      finding("A2A_BASE_URL", :missing_host, "A2A_BASE_URL must include a non-empty host")
    )
    |> add_if(
      non_blank?(uri.host) and forbidden_prod_host?(uri.host),
      finding("A2A_BASE_URL", :forbidden_host, "A2A_BASE_URL must not target loopback/dev host")
    )
    |> add_if(
      not is_binary(uri.path) or not String.starts_with?(uri.path, "/") or uri.path == "/",
      finding("A2A_BASE_URL", :invalid_path, "A2A_BASE_URL must carry a non-root mount path (e.g. /a2a)")
    )
    |> add_if(
      is_binary(uri.path) and byte_size(uri.path) > 1 and String.ends_with?(uri.path, "/"),
      finding("A2A_BASE_URL", :trailing_slash, "A2A_BASE_URL must not end with '/'")
    )
    |> add_if(
      uri.query != nil or uri.fragment != nil,
      finding(
        "A2A_BASE_URL",
        :unexpected_query_or_fragment,
        "A2A_BASE_URL must not contain a query string or fragment"
      )
    )
  end

  defp check_a2a_keys(env, keys) do
    Enum.flat_map(keys, fn var ->
      raw = Map.get(env, var)

      with {:ok, val} <- require_non_blank(var, raw),
           :ok <- reject_placeholder(var, val),
           :ok <- reject_dev_literal(var, val),
           {:ok, bytes} <- decode_base64(var, val) do
        if byte_size(bytes) < 32 do
          [finding(var, :invalid_key_length, "#{var} must decode to >= 32 raw bytes")]
        else
          []
        end
      else
        {:finding, f} -> [f]
      end
    end)
  end

  defp check_admin_password(raw) do
    with {:ok, val} <- require_non_blank("ADMIN_PASSWORD", raw),
         :ok <- reject_placeholder("ADMIN_PASSWORD", val) do
      trimmed = String.trim(val)

      cond do
        byte_size(trimmed) < 8 ->
          [
            finding(
              "ADMIN_PASSWORD",
              :too_short,
              "ADMIN_PASSWORD must be at least 8 bytes (Xaas.ServEngine.ProdBootstrap)"
            )
          ]

        MapSet.member?(@weak_passwords, String.downcase(trimmed)) ->
          [
            finding(
              "ADMIN_PASSWORD",
              :weak_default,
              "ADMIN_PASSWORD must not use a trivial default password"
            )
          ]

        true ->
          []
      end
    else
      {:finding, f} -> [f]
    end
  end

  defp check_runtime_extras(env, include_extras?) do
    onetime =
      if include_extras? or Map.has_key?(env, "ONETIME_REVOKE_KEY") do
        check_min_length_secret("ONETIME_REVOKE_KEY", Map.get(env, "ONETIME_REVOKE_KEY"), 32)
      else
        []
      end

    internal_token =
      if include_extras? or Map.has_key?(env, "INTERNAL_API_TOKEN") do
        check_min_length_secret("INTERNAL_API_TOKEN", Map.get(env, "INTERNAL_API_TOKEN"), 32)
      else
        []
      end

    data_dir =
      if include_extras? or Map.has_key?(env, "XAAS_A2A_DATA_DIR") do
        check_data_dir("XAAS_A2A_DATA_DIR", Map.get(env, "XAAS_A2A_DATA_DIR"))
      else
        []
      end

    cors =
      if include_extras? or Map.has_key?(env, "CORS_ORIGINS") do
        check_cors_origins(Map.get(env, "CORS_ORIGINS"), include_extras?)
      else
        []
      end

    onetime ++ internal_token ++ data_dir ++ cors
  end

  defp check_data_dir(var, raw) do
    with {:ok, val} <- require_non_blank(var, raw),
         :ok <- reject_placeholder(var, val) do
      expanded = Path.expand(val)

      cond do
        not String.starts_with?(val, "/") ->
          [finding(var, :relative_path, "#{var} must be an absolute persistent path")]

        expanded == "/tmp" or String.starts_with?(expanded, "/tmp/") or
          expanded == "/var/tmp" or String.starts_with?(expanded, "/var/tmp/") ->
          [finding(var, :ephemeral_tmp_path, "#{var} must never point into /tmp or /var/tmp")]

        true ->
          []
      end
    else
      {:finding, f} -> [f]
    end
  end

  defp check_cors_origins(raw, required?) do
    cond do
      is_nil(raw) and required? ->
        [finding("CORS_ORIGINS", :missing, "CORS_ORIGINS must be set when runtime extras are enforced")]

      not is_binary(raw) or String.trim(raw) == "" ->
        []

      true ->
        raw
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.flat_map(&validate_cors_origin/1)
    end
  end

  defp validate_cors_origin("*"),
    do: [finding("CORS_ORIGINS", :wildcard_cors_origin, "CORS_ORIGINS must not contain '*' in :prod")]

  defp validate_cors_origin(origin) do
    uri = URI.parse(origin)

    cond do
      uri.scheme != "https" or not non_blank?(uri.host) ->
        [
          finding(
            "CORS_ORIGINS",
            :insecure_cors_origin,
            "every CORS_ORIGINS entry must be an https:// origin"
          )
        ]

      forbidden_prod_host?(uri.host) ->
        [
          finding(
            "CORS_ORIGINS",
            :forbidden_host,
            "CORS_ORIGINS must not allow loopback/dev hosts in :prod"
          )
        ]

      true ->
        []
    end
  end

  # -- shared primitive checks -------------------------------------------------

  defp check_min_length_secret(var, raw, min_bytes) do
    with {:ok, val} <- require_non_blank(var, raw),
         :ok <- reject_placeholder(var, val),
         :ok <- reject_dev_literal(var, val) do
      if byte_size(val) < min_bytes do
        [finding(var, :too_short, "#{var} must be at least #{min_bytes} bytes")]
      else
        []
      end
    else
      {:finding, f} -> [f]
    end
  end

  defp require_non_blank(var, raw) when is_binary(raw) do
    if String.trim(raw) == "" do
      {:finding, finding(var, :missing, "#{var} is required and cannot be blank")}
    else
      {:ok, raw}
    end
  end

  defp require_non_blank(var, _raw) do
    {:finding, finding(var, :missing, "#{var} is required in :prod")}
  end

  defp reject_placeholder(var, val) do
    upper = String.upcase(val)

    if Enum.any?(@placeholder_markers, &String.contains?(upper, &1)) do
      {:finding, finding(var, :placeholder_value, "#{var} contains an unreplaced template placeholder")}
    else
      :ok
    end
  end

  defp reject_dev_literal(var, val) do
    literals = Map.get(@forbidden_dev_literals, var, [])

    if Enum.any?(literals, &Plug.Crypto.secure_compare(val, &1)) do
      {:finding, finding(var, :forbidden_dev_default, "#{var} uses a committed dev/test literal")}
    else
      :ok
    end
  end

  defp decode_base64(var, val) do
    case Base.decode64(String.trim(val)) do
      {:ok, bytes} ->
        {:ok, bytes}

      :error ->
        {:finding, finding(var, :invalid_base64, "#{var} must be valid standard base64")}
    end
  end

  defp valid_userinfo?(userinfo) when is_binary(userinfo) do
    case String.split(userinfo, ":", parts: 2) do
      [user, pass] -> user != "" and pass != ""
      _ -> false
    end
  end

  defp valid_userinfo?(_), do: false

  defp valid_db_path?(path) when is_binary(path) do
    String.starts_with?(path, "/") and String.trim(String.trim_leading(path, "/")) != ""
  end

  defp valid_db_path?(_), do: false

  defp valid_socket_dir?(dir) when is_binary(dir) do
    trimmed = String.trim(dir)
    trimmed != "" and String.starts_with?(trimmed, "/")
  end

  defp valid_socket_dir?(_), do: false

  defp forbidden_prod_host?(host) when is_binary(host) do
    down = String.downcase(host)

    MapSet.member?(@forbidden_hosts, down) or
      String.ends_with?(down, ".local") or
      String.ends_with?(down, ".localhost")
  end

  defp non_blank?(val) when is_binary(val), do: String.trim(val) != ""
  defp non_blank?(_), do: false

  defp discover_extra_a2a_keys(env) do
    env
    |> Map.keys()
    |> Enum.filter(fn key ->
      is_binary(key) and Regex.match?(@a2a_key_pattern, key) and key not in @a2a_key_vars
    end)
    |> Enum.sort()
  end

  defp present_optional_extras(_env, true), do: []

  defp present_optional_extras(env, false) do
    Enum.filter(@runtime_extra_vars, &Map.has_key?(env, &1))
  end

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list

  defp finding(var, kind, reason), do: %{var: var, kind: kind, reason: reason}

  defp build_report(checked_vars, findings) do
    ordered_findings = Enum.reverse(findings)

    failed_set =
      ordered_findings
      |> Enum.map(& &1.var)
      |> MapSet.new()

    failed_vars = Enum.filter(checked_vars, &MapSet.member?(failed_set, &1))
    passed_vars = Enum.reject(checked_vars, &MapSet.member?(failed_set, &1))

    counts =
      Enum.reduce(ordered_findings, %{}, fn %{kind: kind}, acc ->
        Map.update(acc, kind, 1, &(&1 + 1))
      end)

    %{
      status: if(ordered_findings == [], do: :ok, else: :refused),
      checked_vars: checked_vars,
      passed_vars: passed_vars,
      failed_vars: failed_vars,
      findings: ordered_findings,
      counts: counts
    }
  end
end
