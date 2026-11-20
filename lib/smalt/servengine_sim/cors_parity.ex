defmodule Smalt.ServengineSim.CorsParity do
  @moduledoc """
  Simulates `CORS_ORIGINS` preflight handling and verifies CORS parity for all
  `servengine-frontend` request headers.

  Models the browser preflight (`OPTIONS`) and actual-request CORS contract
  across the ALB/backend boundary:

    * `CORS_ORIGINS` (comma-separated env var, explicit `:cors_origins`/`:origins`
      opt, or default `servengine` origins `https://servengine.fnox.io`,
      `https://servegine.fnox.io`, `https://xaas.fnox.io`) controls which
      `Origin` values receive `access-control-allow-origin`.
    * Empty `CORS_ORIGINS=""` fails closed (`[]`, no origins admitted).
    * Disallowed or absent `Origin` headers receive zero `access-control-allow-*`
      headers (and optionally `403` when `halt_on_disallowed: true` or routed
      through `Smalt.ServengineSim.CorsParity.Endpoint`).
    * Allowed `OPTIONS` preflights answer `204 No Content`, halt the `Plug.Conn`,
      and emit `access-control-allow-origin`, `access-control-allow-methods`,
      `access-control-allow-headers`, and `access-control-max-age`.
    * All six `servengine-frontend` headers (`X-Location`, `x-avion-action`,
      `acting-entity-id`, `X-Tenant-Id`, `Authorization`,
      `impersonation-session-id`) are included in the default header allowlist
      and verified case-insensitively by `verify_preflight/2` and
      `verify_matrix/2`.
  """

  @behaviour Plug

  import Plug.Conn

  @servengine_frontend_headers [
    "X-Location",
    "x-avion-action",
    "acting-entity-id",
    "X-Tenant-Id",
    "Authorization",
    "impersonation-session-id"
  ]

  @standard_headers [
    "content-type",
    "accept",
    "x-requested-with"
  ]

  @default_allowed_origins [
    "https://servengine.fnox.io",
    "https://servegine.fnox.io",
    "https://xaas.fnox.io"
  ]

  @default_allowed_methods [
    "GET",
    "POST",
    "PUT",
    "PATCH",
    "DELETE",
    "OPTIONS"
  ]

  @default_max_age 86_400

  @type preflight_report :: %{
          status: :ok | :refused,
          http_status: integer() | nil,
          halted: boolean(),
          origin: String.t(),
          path: String.t(),
          request_method: String.t(),
          requested_headers: [String.t()],
          allow_origin: String.t() | nil,
          allow_methods: [String.t()],
          allow_headers: [String.t()],
          allow_credentials: String.t() | nil,
          missing_headers: [String.t()],
          reasons: [atom() | {atom(), term()}],
          conn: Plug.Conn.t()
        }

  @type matrix_report :: %{
          status: :ok | :refused,
          origins_tested: [String.t()],
          untrusted_origin: String.t(),
          untrusted_rejected?: boolean(),
          results: [preflight_report()],
          failures: [preflight_report()]
        }

  @doc "Canonical list of custom and auth headers sent by `servengine-frontend`."
  @spec servengine_frontend_headers() :: [String.t()]
  def servengine_frontend_headers, do: @servengine_frontend_headers

  @doc "Default `Access-Control-Allow-Headers` list (standard + all `servengine-frontend` headers)."
  @spec default_allowed_headers() :: [String.t()]
  def default_allowed_headers, do: @standard_headers ++ @servengine_frontend_headers

  @doc "Default allowed origins when `CORS_ORIGINS` is unset."
  @spec default_allowed_origins() :: [String.t()]
  def default_allowed_origins, do: @default_allowed_origins

  @doc "Default `Access-Control-Allow-Methods` list."
  @spec default_allowed_methods() :: [String.t()]
  def default_allowed_methods, do: @default_allowed_methods

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts \\ []), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(%Plug.Conn{} = conn, opts) when is_list(opts) do
    case first_req_header(conn, "origin") do
      nil ->
        conn

      origin ->
        origins = allowed_origins(opts)
        allow_credentials? = Keyword.get(opts, :allow_credentials, false)

        case match_origin(origins, origin, allow_credentials?) do
          nil ->
            maybe_halt_disallowed(conn, opts)

          allow_origin ->
            conn
            |> put_cors_base_headers(allow_origin, allow_credentials?, opts)
            |> maybe_handle_preflight(opts)
        end
    end
  end

  @doc """
  Parses a `CORS_ORIGINS` value (comma-separated string or list of origin strings)
  into normalized origin patterns. Returns `nil` when given `nil`.
  """
  @spec parse_cors_origins(nil | String.t() | [String.t()]) :: [String.t()] | nil
  def parse_cors_origins(nil), do: nil

  def parse_cors_origins(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> normalize_origin_list()
  end

  def parse_cors_origins(list) when is_list(list) do
    normalize_origin_list(list)
  end

  @doc """
  Resolves the effective allowed origins from `:cors_origins`/`:origins` option,
  `CORS_ORIGINS` environment variable, or `default_allowed_origins/0`.

  An explicit empty `CORS_ORIGINS=""` resolves to `[]` (fail-closed).
  """
  @spec allowed_origins(keyword()) :: [String.t()]
  def allowed_origins(opts \\ []) do
    opt_origins =
      cond do
        Keyword.has_key?(opts, :cors_origins) -> Keyword.get(opts, :cors_origins)
        Keyword.has_key?(opts, :origins) -> Keyword.get(opts, :origins)
        true -> nil
      end

    case opt_origins do
      nil ->
        case System.get_env("CORS_ORIGINS") do
          nil -> @default_allowed_origins
          env_val -> parse_cors_origins(env_val)
        end

      explicit ->
        parse_cors_origins(explicit) || @default_allowed_origins
    end
  end

  @doc """
  Returns `true` if `origin` is admitted by `origins_or_opts` (a keyword list of
  plug opts or an explicit list of origin strings).
  """
  @spec origin_allowed?(String.t(), keyword() | [String.t()]) :: boolean()
  def origin_allowed?(origin, origins_or_opts \\ [])

  def origin_allowed?(origin, opts) when is_binary(origin) and is_list(opts) do
    origins =
      if Keyword.keyword?(opts) do
        allowed_origins(opts)
      else
        normalize_origin_list(opts)
      end

    match_origin(origins, origin, false) != nil
  end

  @doc """
  Simulates a browser CORS `OPTIONS` preflight request against `target` (a Plug
  module, `{module, opts}`, or `fun/1`) with `Access-Control-Request-Method` and
  `Access-Control-Request-Headers`.
  """
  @spec simulate_preflight(
          module() | {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()),
          keyword()
        ) ::
          Plug.Conn.t()
  def simulate_preflight(target \\ __MODULE__.Endpoint, opts \\ []) do
    path = Keyword.get(opts, :path, "/api/rpc")
    origin = Keyword.get(opts, :origin, hd(@default_allowed_origins))
    method = opts |> Keyword.get(:request_method, "POST") |> to_string() |> String.upcase()
    req_headers_list = Keyword.get(opts, :request_headers, @servengine_frontend_headers)

    base_headers =
      []
      |> maybe_put_header("origin", origin)
      |> maybe_put_header("access-control-request-method", method)
      |> maybe_put_req_headers(req_headers_list)

    extra_headers = Keyword.get(opts, :extra_headers, [])

    conn =
      Plug.Test.conn(:options, path)
      |> Map.put(:req_headers, base_headers ++ extra_headers)

    invoke_target(target, conn)
  end

  @doc """
  Runs a simulated `OPTIONS` preflight against `target` and verifies:

    * preflight response status (`200` or `204`) and halted pipeline (configurable)
    * `access-control-allow-origin` admits `origin` (and does not pair `"*"`
      with `access-control-allow-credentials: "true"`)
    * `access-control-allow-methods` admits `request_method`
    * `access-control-allow-headers` admits every header in `:expected_headers`
      (defaults to `servengine_frontend_headers/0`)

  Returns `{:ok, report}` or `{:refused, report}`.
  """
  @spec verify_preflight(
          module() | {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()),
          keyword()
        ) ::
          {:ok, preflight_report()} | {:refused, preflight_report()}
  def verify_preflight(target \\ __MODULE__.Endpoint, opts \\ []) do
    expected_headers = Keyword.get(opts, :expected_headers, @servengine_frontend_headers)
    opts_with_req = Keyword.put_new(opts, :request_headers, expected_headers)

    origin = Keyword.get(opts_with_req, :origin, hd(@default_allowed_origins))
    path = Keyword.get(opts_with_req, :path, "/api/rpc")

    method =
      opts_with_req |> Keyword.get(:request_method, "POST") |> to_string() |> String.upcase()

    require_halted? = Keyword.get(opts_with_req, :require_halted, true)
    require_allow_methods? = Keyword.get(opts_with_req, :require_allow_methods, true)

    conn = simulate_preflight(target, opts_with_req)

    allow_origin = first_resp_header(conn, "access-control-allow-origin")
    allow_credentials = first_resp_header(conn, "access-control-allow-credentials")

    allow_methods =
      split_resp_header_tokens(conn, "access-control-allow-methods", &String.upcase/1)

    allow_headers =
      split_resp_header_tokens(conn, "access-control-allow-headers", &String.downcase/1)

    missing_headers =
      compute_missing_headers(expected_headers, allow_headers, allow_credentials)

    reasons =
      []
      |> add_if(conn.status not in [200, 204], {:bad_status, conn.status})
      |> add_if(require_halted? and not conn.halted, :not_halted)
      |> add_origin_reasons(origin, allow_origin, allow_credentials)
      |> add_method_reasons(method, allow_methods, require_allow_methods?)
      |> add_if(missing_headers != [], {:missing_headers, missing_headers})
      |> Enum.reverse()

    report = %{
      status: if(reasons == [], do: :ok, else: :refused),
      http_status: conn.status,
      halted: conn.halted,
      origin: origin,
      path: path,
      request_method: method,
      requested_headers: expected_headers,
      allow_origin: allow_origin,
      allow_methods: allow_methods,
      allow_headers: allow_headers,
      allow_credentials: allow_credentials,
      missing_headers: missing_headers,
      reasons: reasons,
      conn: conn
    }

    if reasons == [] do
      {:ok, report}
    else
      {:refused, report}
    end
  end

  @doc """
  Verifies CORS preflight parity across every admitted origin (combined and
  per-header checks for all six `servengine-frontend` headers) and performs an
  anti-vacuity check confirming an untrusted origin receives no allow headers.
  """
  @spec verify_matrix(module() | {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()), keyword()) ::
          {:ok, matrix_report()} | {:refused, matrix_report()}
  def verify_matrix(target \\ __MODULE__.Endpoint, opts \\ []) do
    origins = resolve_matrix_origins(opts)
    untrusted_origin = Keyword.get(opts, :untrusted_origin, "https://evil.example")
    expected_headers = Keyword.get(opts, :expected_headers, @servengine_frontend_headers)

    results =
      for origin <- origins,
          header_group <- [expected_headers | Enum.map(expected_headers, &[&1])] do
        {_status, report} =
          verify_preflight(
            target,
            opts
            |> Keyword.put(:origin, origin)
            |> Keyword.put(:request_headers, header_group)
            |> Keyword.put(:expected_headers, header_group)
          )

        report
      end

    untrusted_conn =
      simulate_preflight(
        target,
        opts
        |> Keyword.put(:origin, untrusted_origin)
        |> Keyword.put(:request_headers, expected_headers)
      )

    untrusted_rejected? =
      is_nil(first_resp_header(untrusted_conn, "access-control-allow-origin")) and
        is_nil(first_resp_header(untrusted_conn, "access-control-allow-headers"))

    failures = Enum.filter(results, &(&1.status == :refused))
    ok? = origins != [] and failures == [] and untrusted_rejected?

    summary = %{
      status: if(ok?, do: :ok, else: :refused),
      origins_tested: origins,
      untrusted_origin: untrusted_origin,
      untrusted_rejected?: untrusted_rejected?,
      results: results,
      failures: failures
    }

    if ok?, do: {:ok, summary}, else: {:refused, summary}
  end

  # -- Private helpers ---------------------------------------------------------

  defp resolve_matrix_origins(opts) do
    case Keyword.get(opts, :origins) do
      nil ->
        case allowed_origins(opts) do
          ["*"] -> @default_allowed_origins
          other -> expand_probe_origins(other)
        end

      explicit ->
        parse_cors_origins(explicit) || []
    end
  end

  defp expand_probe_origins(origins) do
    Enum.map(origins, fn
      "*" -> hd(@default_allowed_origins)
      origin -> String.replace(origin, "*.", "app.")
    end)
  end

  defp invoke_target({mod, plug_opts}, conn), do: mod.call(conn, mod.init(plug_opts))
  defp invoke_target(fun, conn) when is_function(fun, 1), do: fun.(conn)
  defp invoke_target(mod, conn) when is_atom(mod), do: mod.call(conn, mod.init([]))

  defp maybe_halt_disallowed(conn, opts) do
    if Keyword.get(opts, :halt_on_disallowed, false) do
      conn
      |> send_resp(:forbidden, "")
      |> halt()
    else
      conn
    end
  end

  defp put_cors_base_headers(conn, allow_origin, allow_credentials?, opts) do
    expose = Keyword.get(opts, :expose_headers, [])

    conn
    |> put_resp_header("access-control-allow-origin", allow_origin)
    |> maybe_put_vary(allow_origin)
    |> maybe_put_credentials(allow_credentials?)
    |> maybe_put_expose_headers(expose)
  end

  defp maybe_put_vary(conn, "*"), do: conn

  defp maybe_put_vary(conn, _origin) do
    existing = get_resp_header(conn, "vary")

    if Enum.any?(existing, &String.contains?(String.downcase(&1), "origin")) do
      conn
    else
      put_resp_header(conn, "vary", "origin")
    end
  end

  defp maybe_put_credentials(conn, true),
    do: put_resp_header(conn, "access-control-allow-credentials", "true")

  defp maybe_put_credentials(conn, _), do: conn

  defp maybe_put_expose_headers(conn, []), do: conn

  defp maybe_put_expose_headers(conn, headers) when is_list(headers) do
    put_resp_header(conn, "access-control-expose-headers", Enum.join(headers, ","))
  end

  defp maybe_handle_preflight(%Plug.Conn{method: "OPTIONS"} = conn, opts) do
    methods = Keyword.get(opts, :methods, @default_allowed_methods)
    headers = Keyword.get(opts, :headers, default_allowed_headers())
    max_age = Keyword.get(opts, :max_age, @default_max_age)

    conn
    |> put_resp_header("access-control-allow-methods", Enum.join(methods, ","))
    |> put_allow_headers(headers)
    |> put_max_age(max_age)
    |> send_resp(:no_content, "")
    |> halt()
  end

  defp maybe_handle_preflight(conn, _opts), do: conn

  defp put_allow_headers(conn, ["*"]) do
    case first_req_header(conn, "access-control-request-headers") do
      nil -> put_resp_header(conn, "access-control-allow-headers", "*")
      echo -> put_resp_header(conn, "access-control-allow-headers", echo)
    end
  end

  defp put_allow_headers(conn, headers) when is_list(headers) do
    put_resp_header(conn, "access-control-allow-headers", Enum.join(headers, ","))
  end

  defp put_allow_headers(conn, _other), do: conn

  defp put_max_age(conn, nil), do: conn

  defp put_max_age(conn, max_age) when is_integer(max_age) and max_age >= 0 do
    put_resp_header(conn, "access-control-max-age", Integer.to_string(max_age))
  end

  defp put_max_age(conn, max_age) when is_binary(max_age) do
    put_resp_header(conn, "access-control-max-age", max_age)
  end

  defp normalize_origin_list(list) do
    list
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&normalize_origin_pattern/1)
    |> Enum.uniq()
  end

  defp normalize_origin_pattern("*"), do: "*"

  defp normalize_origin_pattern(origin) do
    trimmed = String.trim_trailing(origin, "/")

    case URI.parse(trimmed) do
      %URI{scheme: scheme, host: host, port: port}
      when is_binary(scheme) and is_binary(host) and host != "" ->
        norm_scheme = String.downcase(scheme)
        norm_host = String.downcase(host)
        format_origin(norm_scheme, norm_host, port)

      _ ->
        trimmed
    end
  end

  defp format_origin(scheme, host, nil), do: "#{scheme}://#{host}"
  defp format_origin("https", host, 443), do: "https://#{host}"
  defp format_origin("http", host, 80), do: "http://#{host}"
  defp format_origin(scheme, host, port), do: "#{scheme}://#{host}:#{port}"

  defp match_origin(origins, origin, allow_credentials?) do
    with {:ok, req_parts} <- parse_request_origin(origin) do
      Enum.find_value(origins, fn allowed ->
        match_single_origin(allowed, origin, req_parts, allow_credentials?)
      end)
    else
      :error -> nil
    end
  end

  defp parse_request_origin(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        {:ok, {String.downcase(scheme), String.downcase(host), effective_port(scheme, port)}}

      _ ->
        :error
    end
  end

  defp effective_port(scheme, nil), do: default_port(String.downcase(scheme))
  defp effective_port(_scheme, port), do: port

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_), do: nil

  defp match_single_origin("*", origin, _req_parts, true), do: origin
  defp match_single_origin("*", _origin, _req_parts, false), do: "*"

  defp match_single_origin(allowed, origin, {req_scheme, req_host, req_port}, _creds?) do
    case URI.parse(allowed) do
      %URI{scheme: a_scheme, host: a_host, port: a_port}
      when is_binary(a_scheme) and is_binary(a_host) and a_host != "" ->
        norm_scheme = String.downcase(a_scheme)
        norm_host = String.downcase(a_host)
        eff_port = effective_port(norm_scheme, a_port)

        if norm_scheme == req_scheme and eff_port == req_port and host_match?(req_host, norm_host) do
          origin
        end

      _ ->
        nil
    end
  end

  defp host_match?(req_host, "*." <> domain) do
    req_host != domain and String.ends_with?(req_host, "." <> domain)
  end

  defp host_match?(req_host, exact), do: req_host == exact

  defp compute_missing_headers(expected_headers, allow_headers, allow_credentials) do
    wildcard_headers? = "*" in allow_headers
    creds_on? = allow_credentials == "true"

    Enum.reject(expected_headers, fn header ->
      down = String.downcase(header)

      down in allow_headers or
        (wildcard_headers? and not (creds_on? and down == "authorization"))
    end)
  end

  defp add_origin_reasons(reasons, _origin, nil, _creds),
    do: [:missing_allow_origin | reasons]

  defp add_origin_reasons(reasons, _origin, "*", "true"),
    do: [:wildcard_origin_with_credentials | reasons]

  defp add_origin_reasons(reasons, _origin, "*", _creds),
    do: reasons

  defp add_origin_reasons(reasons, origin, allow_origin, _creds) do
    if String.downcase(allow_origin) == String.downcase(origin) do
      reasons
    else
      [{:origin_mismatch, {origin, allow_origin}} | reasons]
    end
  end

  defp add_method_reasons(reasons, _method, [], true),
    do: [:missing_allow_methods | reasons]

  defp add_method_reasons(reasons, _method, [], false),
    do: reasons

  defp add_method_reasons(reasons, method, allow_methods, _req?) do
    if "*" in allow_methods or method in allow_methods do
      reasons
    else
      [{:method_not_allowed, method} | reasons]
    end
  end

  defp add_if(list, true, item), do: [item | list]
  defp add_if(list, false, _item), do: list

  defp maybe_put_header(headers, _k, nil), do: headers
  defp maybe_put_header(headers, k, v), do: headers ++ [{k, v}]

  defp maybe_put_req_headers(headers, nil), do: headers
  defp maybe_put_req_headers(headers, []), do: headers

  defp maybe_put_req_headers(headers, list) when is_list(list) do
    headers ++ [{"access-control-request-headers", Enum.join(list, ",")}]
  end

  defp maybe_put_req_headers(headers, val) when is_binary(val) do
    headers ++ [{"access-control-request-headers", val}]
  end

  defp first_req_header(conn, name) do
    conn |> get_req_header(name) |> List.first()
  end

  defp first_resp_header(conn, name) do
    conn |> get_resp_header(name) |> List.first()
  end

  defp split_resp_header_tokens(conn, name, normalize_fn) do
    conn
    |> get_resp_header(name)
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&(&1 |> String.trim() |> normalize_fn.()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end
end

defmodule Smalt.ServengineSim.CorsParity.Endpoint do
  @moduledoc """
  Simulated servengine API Plug.Router behind an AWS ALB, mounting
  `Smalt.ServengineSim.CorsParity` before `:match`/`:dispatch` so browser
  `OPTIONS` preflights succeed for `CORS_ORIGINS` and all `servengine-frontend`
  headers.
  """

  use Plug.Router, init_mode: :runtime

  plug(Smalt.ServengineSim.CorsParity)
  plug(:match)
  plug(:dispatch)

  get "/healthz" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  post "/api/rpc" do
    echo_frontend_headers(conn, "/api/rpc")
  end

  get "/api/session" do
    echo_frontend_headers(conn, "/api/session")
  end

  options _ do
    send_json(conn, 403, %{"error" => "cors_origin_denied"})
  end

  match _ do
    send_json(conn, 404, %{"error" => "not_found"})
  end

  defp echo_frontend_headers(conn, path) do
    headers =
      Map.new(Smalt.ServengineSim.CorsParity.servengine_frontend_headers(), fn name ->
        val = conn |> get_req_header(String.downcase(name)) |> List.first()
        {name, val}
      end)

    send_json(conn, 200, %{"status" => "ok", "path" => path, "headers" => headers})
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
