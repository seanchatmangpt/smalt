defmodule Smalt.ServengineSim.WsOriginGuard do
  @moduledoc """
  Simulates Phoenix `/live` and `/socket` `check_origin` enforcement when
  `PHX_HOST=xaas.fnox.io` runs behind an AWS ALB serving `servengine.fnox.io`
  and `servegine.fnox.io`.

  Models `Phoenix.Socket.Transport.check_origin/5` semantics:

    * Only transport paths (`/live`, `/live/*`, `/socket`, `/socket/*`) are
      origin-checked; regular HTTP routes (e.g. `/healthz`) pass untouched.
    * Requests without an `origin` header pass through unless
      `require_origin: true` is configured.
    * Malformed or hostless origins (e.g. `"null"`, `""`) are rejected `403`.
    * `check_origin: :allowlist` (default) admits `https://<PHX_HOST>` plus the
      configured ALB virtual hosts (`https://servengine.fnox.io`,
      `https://servegine.fnox.io`), rejecting untrusted origins such as
      `https://evil.example` with HTTP `403` and halting the `Plug.Conn`.
    * `check_origin: true` simulates Phoenix's single-host default (`PHX_HOST`
      only), demonstrating why `servengine.fnox.io` / `servegine.fnox.io` fail
      `403` behind an ALB unless explicitly admitted.
    * `check_origin: :conn` simulates `:conn` matching against ALB-forwarded
      headers when `rewrite_on_alb: true` is enabled vs raw HTTP backend
      connection fields when TLS is terminated at the ALB.
    * Explicit list (`["https://...", "//...", "https://*.domain"]`), MFA
      `{mod, fun, args}`, and `false` modes match Phoenix's `:check_origin`
      contract.
  """

  @behaviour Plug

  import Plug.Conn

  @default_phx_host "xaas.fnox.io"
  @default_alb_hosts ["servengine.fnox.io", "servegine.fnox.io"]
  @default_socket_prefixes ["/live", "/socket"]
  @default_schemes ["https"]

  @type check_origin_opt ::
          :allowlist
          | :conn
          | boolean()
          | [String.t()]
          | {module(), atom(), list()}

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts \\ []), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(%Plug.Conn{} = conn, opts) do
    prefixes = Keyword.get(opts, :socket_paths, @default_socket_prefixes)

    if guarded_path?(conn.request_path, prefixes) do
      check_origin(conn, opts)
    else
      conn
    end
  end

  @doc """
  Enforces Phoenix `check_origin` on `conn` regardless of request path.
  Returns `conn` unchanged when allowed, or sends `403` and halts when rejected.
  """
  @spec check_origin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def check_origin(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def check_origin(%Plug.Conn{} = conn, opts) do
    mode = Keyword.get(opts, :check_origin, :allowlist)
    require_origin? = Keyword.get(opts, :require_origin, false)
    origin = conn |> get_req_header("origin") |> List.first()

    cond do
      mode == false ->
        conn

      is_nil(origin) and not require_origin? ->
        conn

      is_nil(origin) ->
        forbid(conn)

      origin_allowed?(origin, conn, opts) ->
        conn

      true ->
        forbid(conn)
    end
  end

  @doc """
  Returns the effective list of allowed origin strings for `:allowlist` mode.
  """
  @spec allowed_origins(keyword()) :: [String.t()]
  def allowed_origins(opts \\ []) do
    case Keyword.get(opts, :check_origin, :allowlist) do
      origins when is_list(origins) ->
        origins

      :allowlist ->
        hosts = [phx_host(opts) | Keyword.get(opts, :alb_hosts, @default_alb_hosts)]
        schemes = Keyword.get(opts, :schemes, @default_schemes)

        for scheme <- schemes,
            host <- Enum.uniq(hosts),
            is_binary(host) and host != "" do
          "#{scheme}://#{host}"
        end

      true ->
        schemes = Keyword.get(opts, :schemes, @default_schemes)
        host = phx_host(opts)
        Enum.map(schemes, &"#{&1}://#{host}")

      _other ->
        []
    end
  end

  @doc """
  Returns `true` if `origin` is admitted under `opts` (and `conn` for `:conn` mode).
  """
  @spec origin_allowed?(String.t(), Plug.Conn.t(), keyword()) :: boolean()
  def origin_allowed?(origin, %Plug.Conn{} = conn, opts \\ []) when is_binary(origin) do
    uri = URI.parse(origin)
    mode = Keyword.get(opts, :check_origin, :allowlist)

    if empty_host?(uri.host) do
      false
    else
      do_origin_allowed?(mode, uri, conn, opts)
    end
  end

  @doc """
  Returns `true` if `path` targets a Phoenix socket or LiveView mount prefix.
  Matches exact prefix (`/live`, `/socket`) or subpath (`/live/...`, `/socket/...`),
  excluding lookalike paths such as `/livez`.
  """
  @spec guarded_path?(String.t(), [String.t()]) :: boolean()
  def guarded_path?(path, prefixes \\ @default_socket_prefixes) when is_binary(path) do
    Enum.any?(prefixes, fn prefix ->
      path == prefix or String.starts_with?(path, prefix <> "/")
    end)
  end

  @doc """
  Resolves the effective `PHX_HOST` from `:phx_host` option, `PHX_HOST` env var,
  or the default `"#{@default_phx_host}"`.
  """
  @spec phx_host(keyword()) :: String.t()
  def phx_host(opts \\ []) do
    case Keyword.get(opts, :phx_host) || System.get_env("PHX_HOST") do
      host when is_binary(host) and host != "" -> host
      _ -> @default_phx_host
    end
  end

  # -- Private helpers ---------------------------------------------------------

  defp do_origin_allowed?(false, _uri, _conn, _opts), do: true

  defp do_origin_allowed?({mod, fun, args}, uri, _conn, _opts) do
    apply(mod, fun, [uri | args])
  end

  defp do_origin_allowed?(true, uri, _conn, opts) do
    # Phoenix `check_origin: true` compares only against endpoint url[:host] (PHX_HOST).
    compare_host?(normalize_host(uri.host), normalize_host(phx_host(opts)))
  end

  defp do_origin_allowed?(:conn, uri, conn, opts) do
    {conn_scheme, conn_host, conn_port} = effective_conn_origin(conn, opts)

    normalize_host(uri.host) == normalize_host(conn_host) and
      uri.scheme == conn_scheme and
      uri.port == conn_port
  end

  defp do_origin_allowed?(:allowlist, uri, _conn, opts) do
    parsed = Enum.map(allowed_origins(opts), &parse_origin!/1)
    match_allowed_origins?(uri, parsed)
  end

  defp do_origin_allowed?(origins, uri, _conn, _opts) when is_list(origins) do
    parsed = Enum.map(origins, &parse_origin!/1)
    match_allowed_origins?(uri, parsed)
  end

  defp do_origin_allowed?(invalid, _uri, _conn, _opts) do
    raise ArgumentError,
          ":check_origin expects :allowlist, :conn, boolean, list of origins, or MFA tuple, got: #{inspect(invalid)}"
  end

  defp effective_conn_origin(conn, opts) do
    if Keyword.get(opts, :rewrite_on_alb, false) do
      scheme = header_first(conn, "x-forwarded-proto") || Atom.to_string(conn.scheme)
      host = header_first(conn, "x-forwarded-host") || conn.host
      port = parse_forwarded_port(conn, scheme)
      {scheme, host, port}
    else
      {Atom.to_string(conn.scheme), conn.host, conn.port}
    end
  end

  defp parse_forwarded_port(conn, scheme) do
    case header_first(conn, "x-forwarded-port") do
      nil ->
        default_port_for_scheme(scheme) || conn.port

      port_str ->
        case Integer.parse(port_str) do
          {port, ""} -> port
          _ -> conn.port
        end
    end
  end

  defp default_port_for_scheme("https"), do: 443
  defp default_port_for_scheme("http"), do: 80
  defp default_port_for_scheme(_), do: nil

  defp header_first(conn, name) do
    conn |> get_req_header(name) |> List.first()
  end

  defp parse_origin!(origin) when is_binary(origin) do
    case URI.parse(origin) do
      %{host: host} when host in [nil, ""] ->
        raise ArgumentError,
              "invalid :check_origin entry: #{inspect(origin)} (expected parsable host)"

      %{scheme: scheme, host: host, port: port} ->
        {scheme, normalize_host(host), port}
    end
  end

  defp match_allowed_origins?(uri, allowed_origins) do
    origin_scheme = uri.scheme
    origin_host = normalize_host(uri.host)
    origin_port = uri.port

    Enum.any?(allowed_origins, fn {allowed_scheme, allowed_host, allowed_port} ->
      compare_nullable?(origin_scheme, allowed_scheme) and
        compare_nullable?(origin_port, allowed_port) and
        compare_host?(origin_host, allowed_host)
    end)
  end

  defp compare_nullable?(_request_val, nil), do: true
  defp compare_nullable?(request_val, allowed_val), do: request_val == allowed_val

  defp compare_host?(_request_host, nil), do: true

  defp compare_host?(request_host, "*." <> allowed_host) do
    request_host == allowed_host or String.ends_with?(request_host, "." <> allowed_host)
  end

  defp compare_host?(request_host, allowed_host), do: request_host == allowed_host

  defp empty_host?(host), do: is_nil(host) or host == ""

  defp normalize_host(nil), do: nil
  defp normalize_host(host), do: String.downcase(host)

  defp forbid(conn) do
    conn
    |> send_resp(:forbidden, "")
    |> halt()
  end
end

defmodule Smalt.ServengineSim.WsOriginGuard.Endpoint do
  @moduledoc """
  Simulated Phoenix Endpoint router behind an AWS ALB exposing `/live`
  (LiveView transport) and `/socket` (Channel socket transport) protected by
  `Smalt.ServengineSim.WsOriginGuard`.
  """

  use Plug.Router

  plug(:match)
  plug(Smalt.ServengineSim.WsOriginGuard)
  plug(:dispatch)

  get "/live" do
    transport_ok(conn, :live, "/live")
  end

  match "/live/*subpath" do
    transport_ok(conn, :live, "/live/" <> Enum.join(subpath, "/"))
  end

  get "/socket" do
    transport_ok(conn, :socket, "/socket")
  end

  match "/socket/*subpath" do
    transport_ok(conn, :socket, "/socket/" <> Enum.join(subpath, "/"))
  end

  get "/healthz" do
    send_json(conn, 200, %{"status" => "ok"})
  end

  match _ do
    send_json(conn, 404, %{"error" => "not_found"})
  end

  defp transport_ok(conn, transport, path) do
    origin = conn |> get_req_header("origin") |> List.first()
    xfp = conn |> get_req_header("x-forwarded-proto") |> List.first()
    xfh = conn |> get_req_header("x-forwarded-host") |> List.first()

    send_json(conn, 200, %{
      "status" => "admitted",
      "transport" => Atom.to_string(transport),
      "path" => path,
      "phx_host" => Smalt.ServengineSim.WsOriginGuard.phx_host(),
      "host" => conn.host,
      "origin" => origin,
      "x_forwarded_proto" => xfp,
      "x_forwarded_host" => xfh
    })
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
  end
end
