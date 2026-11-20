defmodule Smalt.ServengineSim.SpaFallbackTrap do
  @moduledoc """
  Simulates Phoenix's `/*path` SPA fallback trap vs. API `Accept: application/json`
  content negotiation, and provides wire-level detectors for both failure modes.

  ## The two halves of the SPA fallback trap

  In Phoenix routers that combine JSON API endpoints with a catch-all SPA shell
  (`get "/*path", PageController, :index` piped through `:browser` with
  `plug :accepts, ["html"]`), any API route that is missing, mis-scoped, or
  shadowed by `/*path` falls into the `:browser` pipeline:

  1. **`406 Not Acceptable` trap** (exemplar: `/entity/validate-sub-domain`):
     When the caller sends strict `Accept: application/json`, `:browser`'s
     `accepts(["html"])` rejects the request with HTTP `406 Not Acceptable`
     because neither `text/html` nor `*/*` is present in `Accept`.

  2. **`200` HTML leak** (exemplars: `/s3` and `/device-tokens`):
     When the caller sends `Accept: */*`, `Accept: application/json, text/plain, */*`
     (Axios default), `Accept: text/html`, or omits `Accept`, `:browser`'s
     `accepts(["html"])` accepts the request and `/*path` returns HTTP `200 OK`
     with `content-type: text/html` and the SPA shell instead of API JSON.

  ## Usage

  As a `Plug` simulator (`:mode` is `:trap`, `:shadowed`, or `:fixed`):

      conn =
        Plug.Test.conn(:get, "/entity/validate-sub-domain")
        |> Plug.Conn.put_req_header("accept", "application/json")
        |> Smalt.ServengineSim.SpaFallbackTrap.call(mode: :trap)

      {:detected, finding} = Smalt.ServengineSim.SpaFallbackTrap.detect_406(conn)

  As an active prober / audit against any `Plug`:

      report = Smalt.ServengineSim.SpaFallbackTrap.audit({Smalt.ServengineSim.SpaFallbackTrap, [mode: :trap]})
      :trapped = report.verdict
  """

  @behaviour Plug
  import Plug.Conn

  @default_api_paths ["/entity/validate-sub-domain", "/s3", "/device-tokens"]
  @default_api_prefixes ["/api"]
  @default_fallback_methods ["GET", "HEAD"]
  @default_spa_html "<!doctype html><html><head><meta charset=\"utf-8\"><title>ServEngine</title></head><body><div id=\"root\"></div></body></html>"

  @type mode :: :trap | :shadowed | :fixed
  @type trap_kind :: :spa_406_not_acceptable | :spa_200_html_leak

  @type finding :: %{
          trap: trap_kind(),
          status: pos_integer(),
          path: String.t(),
          method: String.t(),
          accept: String.t() | nil,
          content_type: String.t() | nil,
          reason: atom()
        }

  @doc "Default API paths guarded by the simulator and audit."
  @spec default_api_paths() :: [String.t()]
  def default_api_paths, do: @default_api_paths

  @doc "Default API prefixes guarded from falling through to the SPA fallback."
  @spec default_api_prefixes() :: [String.t()]
  def default_api_prefixes, do: @default_api_prefixes

  @doc "Default SPA `index.html` shell body returned by the `/*path` fallback."
  @spec spa_html() :: String.t()
  def spa_html, do: @default_spa_html

  @impl true
  @spec init(keyword()) :: map()
  def init(opts \\ []) do
    %{
      mode: Keyword.get(opts, :mode, :trap),
      fallback_methods: Keyword.get(opts, :fallback_methods, @default_fallback_methods),
      api_paths: Keyword.get(opts, :api_paths, @default_api_paths),
      api_prefixes: Keyword.get(opts, :api_prefixes, @default_api_prefixes),
      spa_html: Keyword.get(opts, :spa_html, @default_spa_html),
      api_routes: Keyword.get(opts, :api_routes, nil)
    }
  end

  @impl true
  @spec call(Plug.Conn.t(), keyword() | map()) :: Plug.Conn.t()
  def call(conn, opts) when is_list(opts), do: call(conn, init(opts))

  def call(%Plug.Conn{} = conn, %{} = cfg) do
    case cfg.mode do
      :shadowed ->
        # `/*path` was mounted above the API scope, shadowing every matching HTTP method.
        dispatch_spa_then_api(conn, cfg)

      :trap ->
        # Only non-trapped baseline API routes (e.g. `/health`) are mounted;
        # `/entity/validate-sub-domain`, `/s3`, and `/device-tokens` fall through to `/*path`.
        dispatch_api_then_spa(conn, cfg, trapped_routes())

      :fixed ->
        # All API routes mount above `/*path`, and API paths/prefixes have a JSON 404 fence.
        dispatch_api_then_spa(conn, cfg, fixed_routes(cfg))
    end
  end

  # --- Content negotiation (Phoenix.Controller.accepts/2 semantics) ---

  @doc """
  Parses an HTTP `Accept` header string into a list of media ranges with quality factors.
  """
  @spec parse_accept(String.t() | nil) :: [%{type: String.t(), subtype: String.t(), q: float()}]
  def parse_accept(nil), do: []
  def parse_accept(""), do: []

  def parse_accept(header) when is_binary(header) do
    header
    |> String.split(",", trim: true)
    |> Enum.flat_map(&parse_media_range/1)
  end

  defp parse_media_range(raw) do
    [media | params] = raw |> String.trim() |> String.split(";", trim: true)

    case String.split(String.trim(media), "/", parts: 2) do
      [type, subtype] when type != "" and subtype != "" ->
        q = parse_quality(params)

        [
          %{
            type: String.downcase(String.trim(type)),
            subtype: String.downcase(String.trim(subtype)),
            q: q
          }
        ]

      _ ->
        []
    end
  end

  defp parse_quality(params) do
    params
    |> Enum.find_value(1.0, fn param ->
      case String.split(String.trim(param), "=", parts: 2) do
        [k, v] ->
          if String.downcase(String.trim(k)) == "q" do
            parse_q_float(String.trim(v))
          else
            nil
          end

        _ ->
          nil
      end
    end)
  end

  defp parse_q_float(v) do
    case Float.parse(v) do
      {q, ""} when q >= 0.0 and q <= 1.0 -> q
      {q, ""} when q > 1.0 -> 1.0
      _ -> 0.0
    end
  end

  @doc """
  Returns `true` when the `Plug.Conn` or `Accept` header string negotiates the
  requested Phoenix format (`"html"` / `:html` or `"json"` / `:json`).

  Missing or empty `Accept` headers pass negotiation (matching `Phoenix.Controller.accepts/2`).
  """
  @spec accepts_format?(Plug.Conn.t() | String.t() | nil, String.t() | atom()) :: boolean()
  def accepts_format?(%Plug.Conn{} = conn, format) do
    conn |> accept_header() |> accepts_format?(format)
  end

  def accepts_format?(nil, _format), do: true
  def accepts_format?("", _format), do: true

  def accepts_format?(header, format) when is_atom(format) do
    accepts_format?(header, Atom.to_string(format))
  end

  def accepts_format?(header, format) when is_binary(header) and format in ["html", "json"] do
    ranges = parse_accept(header)

    if ranges == [] do
      false
    else
      target_candidates(format)
      |> Enum.any?(fn {type, subtype, suffix} ->
        negotiate_media_type(ranges, type, subtype, suffix)
      end)
    end
  end

  defp target_candidates("html"), do: [{"text", "html", nil}]
  defp target_candidates("json"), do: [{"application", "json", "+json"}]

  defp negotiate_media_type(ranges, type, subtype, suffix) do
    exact = Enum.filter(ranges, &(&1.type == type and &1.subtype == subtype))

    structured =
      if suffix do
        Enum.filter(ranges, &(&1.type == type and String.ends_with?(&1.subtype, suffix)))
      else
        []
      end

    type_wild = Enum.filter(ranges, &(&1.type == type and &1.subtype == "*"))
    any_wild = Enum.filter(ranges, &(&1.type == "*" and &1.subtype == "*"))

    # RFC 9110 §12.5.1: most specific matching media range governs `q`.
    cond do
      exact != [] -> max_q(exact) > 0.0
      structured != [] -> max_q(structured) > 0.0
      type_wild != [] -> max_q(type_wild) > 0.0
      any_wild != [] -> max_q(any_wild) > 0.0
      true -> false
    end
  end

  defp max_q(ranges), do: ranges |> Enum.map(& &1.q) |> Enum.max()

  # --- Detectors ---

  @doc """
  Detects the `406 Not Acceptable` SPA fallback trap on an executed `Plug.Conn`.

  By default, restricts detection to API paths (`:api_paths` and `:api_prefixes`)
  so genuine browser SPA pages returning `406` to `Accept: application/json` do not
  trigger false positives. Pass `api_only: false` to evaluate any path.
  """
  @spec detect_406(Plug.Conn.t(), keyword()) :: {:detected, finding()} | :ok
  def detect_406(%Plug.Conn{} = conn, opts \\ []) do
    api_only? = Keyword.get(opts, :api_only, true)
    path = conn.request_path
    accept = accept_header(conn)

    if conn.status == 406 and (not api_only? or api_path?(path, opts)) and
         json_requested?(accept, opts) do
      {:detected,
       %{
         trap: :spa_406_not_acceptable,
         status: 406,
         path: path,
         method: conn.method,
         accept: accept,
         content_type: resp_content_type(conn),
         reason: :browser_fallback_rejected_json_accept
       }}
    else
      :ok
    end
  end

  @doc """
  Detects a `200 OK` HTML leak on an API path in an executed `Plug.Conn`.

  Flags responses with HTTP `200` whose `content-type` or body is HTML when the
  request targets an API path (`:api_paths` / `:api_prefixes`, defaulting to
  `/entity/validate-sub-domain`, `/s3`, `/device-tokens`, and `/api/*`).
  Non-API SPA routes (e.g. `/`, `/dashboard`) returning `200 text/html` return `:ok`.
  """
  @spec detect_html_leak(Plug.Conn.t(), keyword()) :: {:detected, finding()} | :ok
  def detect_html_leak(%Plug.Conn{} = conn, opts \\ []) do
    api_only? = Keyword.get(opts, :api_only, true)
    path = conn.request_path

    if conn.status == 200 and (not api_only? or api_path?(path, opts)) and html_response?(conn) do
      {:detected,
       %{
         trap: :spa_200_html_leak,
         status: 200,
         path: path,
         method: conn.method,
         accept: accept_header(conn),
         content_type: resp_content_type(conn),
         reason: :api_route_served_spa_html
       }}
    else
      :ok
    end
  end

  @doc """
  Runs both the `406` detector and the `200` HTML leak detector against `conn`.
  """
  @spec inspect_conn(Plug.Conn.t(), keyword()) :: {:detected, finding()} | :ok
  def inspect_conn(%Plug.Conn{} = conn, opts \\ []) do
    case detect_406(conn, opts) do
      {:detected, _} = hit -> hit
      :ok -> detect_html_leak(conn, opts)
    end
  end

  # --- Active Probers & Audit ---

  @doc """
  Actively probes `plug` at `path` (default `"/entity/validate-sub-domain"`) with
  `Accept: application/json` and runs `detect_406/2`.
  """
  @spec probe_406(
          module() | {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()),
          String.t(),
          keyword()
        ) ::
          {:detected, finding()} | :ok
  def probe_406(plug, path \\ "/entity/validate-sub-domain", opts \\ []) do
    method = Keyword.get(opts, :method, :get)
    accept = Keyword.get(opts, :accept, "application/json")
    conn = dispatch(plug, method, path, accept)
    detect_406(conn, Keyword.put_new(opts, :api_only, false))
  end

  @doc """
  Actively probes `plug` at `path` (e.g. `"/s3"` or `"/device-tokens"`) with a
  wildcard/browser `Accept` header (default `"*/*"`) and runs `detect_html_leak/2`.
  """
  @spec probe_html_leak(
          module() | {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()),
          String.t(),
          keyword()
        ) :: {:detected, finding()} | :ok
  def probe_html_leak(plug, path, opts \\ []) do
    method = Keyword.get(opts, :method, :get)
    accept = Keyword.get(opts, :accept, "*/*")
    conn = dispatch(plug, method, path, accept)
    detect_html_leak(conn, Keyword.put_new(opts, :api_only, false))
  end

  @doc """
  Dispatches a simulated `Plug.Test.conn` request with the given `Accept` header
  (or `nil` to omit `Accept`) through `plug`.
  """
  @spec dispatch(
          module() | {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()),
          atom() | String.t(),
          String.t(),
          String.t() | nil
        ) :: Plug.Conn.t()
  def dispatch(plug, method, path, accept) do
    conn = Plug.Test.conn(method, path)

    conn =
      if is_binary(accept) do
        put_req_header(conn, "accept", accept)
      else
        conn
      end

    invoke_plug(plug, conn)
  end

  @doc """
  Runs the full ServEngine SPA fallback audit matrix against `plug`:

  - `406` trap probe on `/entity/validate-sub-domain` (`Accept: application/json`)
  - `200` HTML leak probes on `/s3` and `/device-tokens` (`Accept: */*` and
    `Accept: application/json, text/plain, */*`)
  - Anti-false-positive SPA check on `/` (`Accept: text/html`)

  Returns a deterministic report map with `:verdict` (`:trapped | :clean`),
  `:findings`, `:checked`, and `:by_trap`.
  """
  @spec audit(module() | {module(), term()} | (Plug.Conn.t() -> Plug.Conn.t()), keyword()) ::
          map()
  def audit(plug, opts \\ []) do
    validate_path = Keyword.get(opts, :validate_path, "/entity/validate-sub-domain")
    leak_paths = Keyword.get(opts, :leak_paths, ["/s3", "/device-tokens"])
    spa_routes = Keyword.get(opts, :spa_routes, ["/"])

    validate_findings =
      case probe_406(plug, validate_path, opts) do
        {:detected, f} -> [f]
        :ok -> []
      end

    leak_accepts = Keyword.get(opts, :leak_accepts, ["*/*", "application/json, text/plain, */*"])

    leak_findings =
      for path <- leak_paths, accept <- leak_accepts do
        probe_html_leak(plug, path, Keyword.put(opts, :accept, accept))
      end
      |> Enum.flat_map(fn
        {:detected, f} -> [f]
        :ok -> []
      end)

    spa_false_positives =
      for path <- spa_routes do
        conn = dispatch(plug, :get, path, "text/html")
        inspect_conn(conn, opts)
      end
      |> Enum.flat_map(fn
        {:detected, f} -> [f]
        :ok -> []
      end)

    findings = validate_findings ++ leak_findings ++ spa_false_positives
    checked = 1 + length(leak_paths) * length(leak_accepts) + length(spa_routes)

    by_trap = %{
      spa_406_not_acceptable: Enum.count(findings, &(&1.trap == :spa_406_not_acceptable)),
      spa_200_html_leak: Enum.count(findings, &(&1.trap == :spa_200_html_leak))
    }

    %{
      verdict: if(findings == [], do: :clean, else: :trapped),
      findings: findings,
      checked: checked,
      by_trap: by_trap
    }
  end

  @doc """
  Returns `true` if `path` matches one of the configured `:api_paths` or `:api_prefixes`
  on a segment boundary.
  """
  @spec api_path?(String.t(), keyword()) :: boolean()
  def api_path?(path, opts \\ []) when is_binary(path) do
    api_paths = Keyword.get(opts, :api_paths, @default_api_paths)
    api_prefixes = Keyword.get(opts, :api_prefixes, @default_api_prefixes)

    Enum.any?(api_paths ++ api_prefixes, &segment_match?(path, &1))
  end

  # --- Internal router simulation ---

  defp dispatch_spa_then_api(conn, cfg) do
    if fallback_method?(conn.method, cfg.fallback_methods) do
      serve_spa_fallback(conn, cfg)
    else
      case match_api(conn, fixed_routes(cfg)) do
        {:ok, conn} ->
          conn

        :nomatch ->
          send_json(conn, 404, %{"error" => "route_not_found", "path" => conn.request_path})
      end
    end
  end

  defp dispatch_api_then_spa(conn, cfg, routes) do
    case match_api(conn, routes) do
      {:ok, conn} ->
        conn

      :nomatch ->
        cond do
          cfg.mode == :fixed and
              api_path?(conn.request_path,
                api_paths: cfg.api_paths,
                api_prefixes: cfg.api_prefixes
              ) ->
            send_json(conn, 404, %{"error" => "not_found", "path" => conn.request_path})

          fallback_method?(conn.method, cfg.fallback_methods) ->
            serve_spa_fallback(conn, cfg)

          true ->
            send_json(conn, 404, %{"error" => "route_not_found", "path" => conn.request_path})
        end
    end
  end

  defp trapped_routes do
    %{
      "/health" => fn conn -> %{"ok" => true, "path" => conn.request_path} end
    }
  end

  defp fixed_routes(%{api_routes: custom}) when is_map(custom),
    do: Map.merge(default_fixed_routes(), custom)

  defp fixed_routes(_cfg), do: default_fixed_routes()

  defp default_fixed_routes do
    %{
      "/health" => fn conn -> %{"ok" => true, "path" => conn.request_path} end,
      "/entity/validate-sub-domain" => fn conn ->
        conn = fetch_query_params(conn)
        %{"valid" => true, "sub_domain" => conn.query_params["sub_domain"] || "default"}
      end,
      "/s3" => fn conn ->
        %{"service" => "s3", "presigned" => true, "path" => conn.request_path}
      end,
      "/device-tokens" => fn conn ->
        %{"tokens" => [], "path" => conn.request_path}
      end
    }
  end

  defp match_api(conn, routes) do
    case Enum.find(routes, fn {prefix, _handler} -> segment_match?(conn.request_path, prefix) end) do
      nil ->
        :nomatch

      {_prefix, handler} ->
        if accepts_format?(conn, "json") do
          {:ok, send_json(conn, 200, handler.(conn))}
        else
          {:ok,
           send_json(conn, 406, %{
             "error" => "not_acceptable",
             "expected" => ["json"],
             "accept" => accept_header(conn),
             "path" => conn.request_path
           })}
        end
    end
  end

  defp serve_spa_fallback(conn, cfg) do
    if accepts_format?(conn, "html") do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(200, cfg.spa_html)
      |> halt()
    else
      send_json(conn, 406, %{
        "error" => "not_acceptable",
        "expected" => ["html"],
        "accept" => accept_header(conn),
        "path" => conn.request_path
      })
    end
  end

  defp send_json(conn, status, payload) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(payload))
    |> halt()
  end

  defp fallback_method?(_method, :all), do: true
  defp fallback_method?(method, methods) when is_list(methods), do: method in methods

  defp segment_match?(path, prefix) do
    norm_path = normalize_path(path)
    norm_prefix = normalize_path(prefix)

    norm_path == norm_prefix or String.starts_with?(norm_path, norm_prefix <> "/")
  end

  defp normalize_path("/"), do: "/"
  defp normalize_path(path), do: String.trim_trailing(path, "/")

  defp accept_header(conn) do
    case get_req_header(conn, "accept") do
      [val | _] -> val
      [] -> nil
    end
  end

  defp resp_content_type(conn) do
    case get_resp_header(conn, "content-type") do
      [val | _] -> val
      [] -> nil
    end
  end

  defp json_requested?(nil, opts), do: not Keyword.get(opts, :require_json_accept, false)

  defp json_requested?(accept, opts) do
    if Keyword.get(opts, :require_json_accept, true) do
      accepts_format?(accept, "json")
    else
      true
    end
  end

  defp html_response?(conn) do
    ct = resp_content_type(conn) || ""
    ct_lower = String.downcase(ct)

    html_ct? =
      String.starts_with?(ct_lower, "text/html") or
        String.starts_with?(ct_lower, "application/xhtml+xml")

    body = conn.resp_body |> IO.iodata_to_binary() |> String.trim_leading() |> String.downcase()

    html_body? =
      String.starts_with?(body, "<!doctype html") or
        String.starts_with?(body, "<html") or
        String.contains?(body, "<div id=\"root\"")

    html_ct? or html_body?
  end

  defp invoke_plug(fun, conn) when is_function(fun, 1), do: fun.(conn)
  defp invoke_plug({mod, opts}, conn) when is_atom(mod), do: mod.call(conn, mod.init(opts))
  defp invoke_plug(mod, conn) when is_atom(mod), do: mod.call(conn, mod.init([]))
end
