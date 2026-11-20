defmodule Smalt.ServengineSim.EdgeHeadersSim do
  @moduledoc """
  GCP External Application Load Balancer (ALB) edge response header and
  HTTP-to-HTTPS redirect simulator for DuckDB-Wasm + AoQ.

  Enforces the edge policy required to boot `SharedArrayBuffer`-backed
  DuckDB-Wasm alongside Popcorn BEAM (cross-origin isolation) and advertise
  HTTP/3 / QUIC for AoQ over the same origin:

    * Plaintext HTTP requests (`scheme == :http` or `x-forwarded-proto: http`)
      receive a `301 Moved Permanently` redirect to `https://...` (preserving
      host, path, and query string) and halt the Plug pipeline.
    * HTTPS (or `x-forwarded-proto: https`, or `redirect_http?: false`)
      responses carry:
        * `cross-origin-opener-policy: same-origin`
        * `cross-origin-embedder-policy: credentialless`
        * `alt-svc: h3=":443"`

  Can be mounted directly in a `Plug.Builder` / `Plug.Router` chain (`plug
  Smalt.ServengineSim.EdgeHeadersSim`), invoked standalone in unit tests, or
  configured with `plug: DownstreamPlug` to wrap a router under Bandit.
  """

  @behaviour Plug

  import Plug.Conn

  @default_coop "same-origin"
  @default_coep "credentialless"
  @default_h3_port 443
  @default_https_port 443

  @impl true
  def init(opts) when is_list(opts) do
    opts
  end

  @impl true
  def call(%Plug.Conn{halted: true} = conn, _opts), do: conn

  def call(%Plug.Conn{} = conn, opts) do
    opts = if is_list(opts), do: opts, else: []

    if Keyword.get(opts, :redirect_http?, true) and effective_scheme(conn) == :http do
      conn
      |> put_resp_header("location", redirect_url(conn, opts))
      |> send_resp(301, "")
      |> halt()
    else
      conn =
        Enum.reduce(edge_headers(opts), conn, fn {name, value}, acc ->
          put_resp_header(acc, name, value)
        end)

      dispatch_downstream(conn, Keyword.get(opts, :plug))
    end
  end

  @doc """
  Returns the canonical list of GCP ALB edge response headers for `opts`.

  Defaults:
    * `cross-origin-opener-policy`: `"same-origin"`
    * `cross-origin-embedder-policy`: `"credentialless"`
    * `alt-svc`: `"h3=\\":443\\""`
  """
  @spec edge_headers(keyword()) :: [{String.t(), String.t()}]
  def edge_headers(opts \\ []) do
    coop = Keyword.get(opts, :coop, @default_coop)
    coep = Keyword.get(opts, :coep, @default_coep)
    alt_svc = Keyword.get(opts, :alt_svc) || format_alt_svc(opts)

    [
      {"cross-origin-opener-policy", coop},
      {"cross-origin-embedder-policy", coep},
      {"alt-svc", alt_svc}
    ]
  end

  @doc """
  Resolves the effective request scheme (`:http` or `:https`), honoring the
  `x-forwarded-proto` header when present before falling back to `conn.scheme`.
  """
  @spec effective_scheme(Plug.Conn.t()) :: :http | :https
  def effective_scheme(%Plug.Conn{} = conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [raw | _] ->
        case raw |> String.split(",") |> hd() |> String.trim() |> String.downcase() do
          "https" -> :https
          "http" -> :http
          _ -> normalize_scheme(conn.scheme)
        end

      [] ->
        normalize_scheme(conn.scheme)
    end
  end

  @doc """
  Builds the `https://` target URL for an HTTP-to-HTTPS 301 redirect.
  """
  @spec redirect_url(Plug.Conn.t(), keyword()) :: String.t()
  def redirect_url(%Plug.Conn{} = conn, opts \\ []) do
    https_port = Keyword.get(opts, :https_port, @default_https_port)
    host = conn |> extract_host() |> strip_port()

    port_suffix =
      if https_port == 443 do
        ""
      else
        ":#{https_port}"
      end

    path =
      case conn.request_path do
        p when is_binary(p) and p != "" -> p
        _ -> "/"
      end

    query =
      case conn.query_string do
        q when is_binary(q) and q != "" -> "?" <> q
        _ -> ""
      end

    "https://#{host}#{port_suffix}#{path}#{query}"
  end

  @doc """
  Verifies that a `Plug.Conn` or header enumerable carries all required GCP ALB
  edge headers (`COOP`, `COEP`, `alt-svc`) with their expected values.
  """
  @spec verify_edge_headers(Plug.Conn.t() | Enumerable.t(), keyword()) ::
          :ok | {:error, [{String.t(), term()}]}
  def verify_edge_headers(conn_or_headers, opts \\ [])

  def verify_edge_headers(%Plug.Conn{resp_headers: headers}, opts) do
    verify_edge_headers(headers, opts)
  end

  def verify_edge_headers(headers, opts) do
    normalized =
      Enum.reduce(headers, %{}, fn {k, v}, acc ->
        Map.put_new(acc, k |> to_string() |> String.downcase(), to_string(v))
      end)

    failures =
      Enum.flat_map(edge_headers(opts), fn {name, expected} ->
        case Map.fetch(normalized, name) do
          :error -> [{name, {:missing, expected}}]
          {:ok, ^expected} -> []
          {:ok, actual} -> [{name, {:mismatch, expected, actual}}]
        end
      end)

    case failures do
      [] -> :ok
      list -> {:error, list}
    end
  end

  defp format_alt_svc(opts) do
    h3_port = Keyword.get(opts, :h3_port, @default_h3_port)
    base = ~s(h3=":#{h3_port}")

    case Keyword.get(opts, :alt_svc_max_age) do
      ma when is_integer(ma) and ma >= 0 -> "#{base}; ma=#{ma}"
      _ -> base
    end
  end

  defp normalize_scheme(:https), do: :https
  defp normalize_scheme(_), do: :http

  defp extract_host(conn) do
    with nil <- first_header_host(conn, "x-forwarded-host"),
         nil <- first_header_host(conn, "host") do
      case conn.host do
        h when is_binary(h) and h != "" -> h
        _ -> "localhost"
      end
    end
  end

  defp first_header_host(conn, header) do
    case get_req_header(conn, header) do
      [raw | _] ->
        case raw |> String.split(",") |> hd() |> String.trim() do
          "" -> nil
          val -> val
        end

      [] ->
        nil
    end
  end

  defp strip_port("[" <> _ = ipv6_host) do
    case String.split(ipv6_host, "]", parts: 2) do
      [addr, _rest] -> addr <> "]"
      _ -> ipv6_host
    end
  end

  defp strip_port(host) do
    case String.split(host, ":") do
      # Bare IPv6 address from Plug.Conn.host (e.g. "::1") has >= 2 colons
      [_, _, _ | _] -> "[#{host}]"
      [hostname | _] -> hostname
    end
  end

  defp dispatch_downstream(conn, nil), do: conn
  defp dispatch_downstream(conn, fun) when is_function(fun, 1), do: fun.(conn)
  defp dispatch_downstream(conn, mod) when is_atom(mod), do: mod.call(conn, mod.init([]))
  defp dispatch_downstream(conn, {mod, plug_opts}), do: mod.call(conn, mod.init(plug_opts))
end
