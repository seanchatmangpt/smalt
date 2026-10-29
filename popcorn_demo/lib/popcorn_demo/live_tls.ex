defmodule PopcornDemo.LiveTls do
  @moduledoc """
  Host-side TLS leg: the same lawful auth walk as `PopcornDemo.Live`, but
  over the ARM TLS twin (`https://…:<arm_tls_port>`, default 9444) with a
  REAL `:ssl` peer-verified handshake against the substrate CA — never
  `verify_none`.

  Walk (mirrors `PopcornDemo.Live.walk/1`): exempt `/metadata/endpoints`
  probe, exempt `/tenants`, exempt STS mint, then a Bearer-authed
  `/subscriptions` round-trip — all through one real `:httpc` + `:ssl`
  transport with:

    - `verify: :verify_peer`
    - `cacertfile` = the substrate CA (`SMALT_TLS_CA` or `SSL_CERT_FILE`
      env override, else the repo-root `.smalt/tls/ca-cert.pem` that
      `scripts/substrate.sh` installs)
    - `customize_hostname_check` https match against the served cert
      (SAN `DNS:localhost, IP:127.0.0.1, …`)

  Receipt contract: `{:ok, detail}` | `{:skip, {:substrate_down | :ca_missing
  | :no_ssl, reason}}` | `{:fail, detail}`; `format/1` renders
  `tls=OK(...) | tls=SKIP(<loud reason>) | tls=FAIL(...)`.
  """

  require Logger

  @client_id "popcorn-demo"
  @client_secret "popcorn-demo"
  @subscriptions_api_version "2022-12-01"

  def run do
    result = walk()
    Logger.info("popcorn_demo TLS leg: #{format(result)} via ca=#{ca_used(result)}")
    result
  end

  @doc "Receipt fragment for the combined smoke line."
  def format({:ok, detail}), do: "tls=OK(" <> detail <> ")"

  def format({:skip, {:substrate_down, reason}}) do
    slice = String.slice(reason, 0, 120)

    if reason =~ ~r/econnrefused|nxdomain|timeout|closed/i do
      "tls=SKIP(substrate-down:" <> slice <> ")"
    else
      "tls=SKIP(transport:" <> slice <> ")"
    end
  end

  def format({:skip, {:ca_missing, path}}), do: "tls=SKIP(ca-missing:" <> path <> ")"
  def format({:skip, {:no_ssl, reason}}), do: "tls=SKIP(no-ssl:" <> reason <> ")"
  def format({:fail, detail}), do: "tls=FAIL(" <> detail <> ")"

  # -- Walk -------------------------------------------------------------------

  defp walk do
    with {:ok, ca} <- ca_cert_path(),
         :ok <- ensure_ssl_started() do
      base = "https://localhost:" <> Integer.to_string(Application.get_env(:smalt, :arm_tls_port, 9444))
      opts = ssl_opts(ca)

      with {:ok, _} <- probe_endpoints(base, opts),
           {:ok, tid} <- fetch_tenant(base, opts),
           {:ok, token} <- mint_token(base, opts, tid),
           {:ok, subs} <- list_subscriptions(base, opts, token) do
        {:ok, "https-twin,endpoints,tenants,sts,subscriptions=" <> Integer.to_string(subs)}
      end
    end
  end

  # CA resolution: env override first (substrate.sh exports SSL_CERT_FILE),
  # then the repo-root path derived from this source file so the walk works
  # from any cwd.
  defp ca_cert_path do
    default = Path.expand("../../../.smalt/tls/ca-cert.pem", __DIR__)

    candidates =
      [System.get_env("SMALT_TLS_CA"), System.get_env("SSL_CERT_FILE"), default]
      |> Enum.reject(&(&1 in [nil, ""]))

    case Enum.find(candidates, &File.regular?/1) do
      path when is_binary(path) -> {:ok, path}
      nil -> {:skip, {:ca_missing, default}}
    end
  end

  defp ensure_ssl_started do
    with {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl) do
      # Mix only puts the dep-closure ebins on the code path; :ssl/:public_key
      # depend on :asn1, whose ebin is not in popcorn_demo's dep tree. Add the
      # OTP lib ebins explicitly or the handshake dies with
      # {:undef, [{:asn1rt_nif, :decode_ber_tlv, ...}]} mid-certify.
      Enum.each([:asn1, :public_key, :ssl, :inets], fn app ->
        pattern = :filename.join([:code.lib_dir(), Atom.to_charlist(app) ++ ~c"-*", ~c"ebin"])

        case :filelib.wildcard(pattern) do
          [ebin | _] ->
            unless Enum.member?(:code.get_path(), ebin), do: :code.add_pathz(ebin)

          [] ->
            :ok
        end
      end)

      :ok
    else
      {:error, reason} -> {:skip, {:no_ssl, inspect(reason)}}
    end
  end

  defp ssl_opts(ca) do
    [
      verify: :verify_peer,
      cacertfile: String.to_charlist(ca),
      depth: 3,
      # Session resumption would skip chain validation on a resumed handshake
      # (the ssl app caches sessions per host:port across connections), which
      # turns a wrong-CA walk into a silent pass. Every leg must verify its
      # own chain: no reuse, no tickets (reuse_sessions covers TLS 1.2 — the
      # twin negotiates 1.2; session_tickets covers 1.3).
      session_tickets: :disabled,
      reuse_sessions: false,
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp request(_opts, method, url, extra_headers \\ [], body \\ nil)

  defp request(opts, method, url, extra_headers, body) do
    headers =
      case body do
        nil -> extra_headers
        _ -> [{"content-type", "application/x-www-form-urlencoded"} | extra_headers]
      end
      |> Enum.map(fn {k, v} ->
        {String.to_charlist(String.downcase(k)), String.to_charlist(v)}
      end)

    request_spec =
      if body in [nil, ""] do
        {String.to_charlist(url), headers}
      else
        {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body}
      end

    case :httpc.request(method, request_spec, [ssl: opts, timeout: 10_000],
           [body_format: :binary], profile()
         ) do
      {:ok, {{_version, status, _reason}, _resp_headers, resp_body}} ->
        {:ok, status, resp_body}

      {:error, reason} ->
        text = inspect(reason)

        # A TLS alert (unknown CA, hostname mismatch, expired cert) is a real
        # verification FAIL against the served chain, not a down substrate.
        if text =~ ~r/tls_alert|certifi|hostname/i do
          {:fail, "tls:" <> text}
        else
          {:skip, {:substrate_down, text}}
        end
    end
  end

  defp probe_endpoints(base, opts) do
    case request(opts, :get, base <> "/metadata/endpoints") do
      {:ok, 200, _body} -> {:ok, :endpoints}
      {:ok, status, _} -> {:fail, "endpoints:status=" <> Integer.to_string(status)}
      skip -> skip
    end
  end

  defp fetch_tenant(base, opts) do
    case request(opts, :get, base <> "/tenants") do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"value" => [%{"tenantId" => tid} | _]}} when is_binary(tid) ->
            {:ok, tid}

          other ->
            {:fail, "tenants:shape=" <> inspect(other)}
        end

      {:ok, status, _} ->
        {:fail, "tenants:status=" <> Integer.to_string(status)}

      skip ->
        skip
    end
  end

  defp mint_token(base, opts, tid) do
    form =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => @client_id,
        "client_secret" => @client_secret
      })

    case request(opts, :post, base <> "/" <> tid <> "/oauth2/v2.0/token", [], form) do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => token}} when is_binary(token) -> {:ok, token}
          other -> {:fail, "sts:shape=" <> inspect(other)}
        end

      {:ok, status, body} ->
        {:fail, "sts:status=" <> Integer.to_string(status) <> " body=" <> body_slice(body)}

      skip ->
        skip
    end
  end

  defp list_subscriptions(base, opts, token) do
    url = base <> "/subscriptions?api-version=" <> @subscriptions_api_version

    case request(opts, :get, url, [{"authorization", "Bearer " <> token}]) do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"value" => subs}} when is_list(subs) -> {:ok, length(subs)}
          other -> {:fail, "subscriptions:shape=" <> inspect(other)}
        end

      {:ok, status, body} ->
        {:fail,
         "subscriptions:status=" <> Integer.to_string(status) <> " body=" <> body_slice(body)}

      skip ->
        skip
    end
  end

  defp ca_used({:ok, _}), do: "OK"
  defp ca_used(_), do: "not-ok"

  # A fresh :httpc profile per run: the default profile caches TLS sessions
  # per host:port, so a second call with DIFFERENT ssl options (the wrong-CA
  # negative) would silently reuse the previously verified session and never
  # see its own cacertfile — a vacuous verification. One profile per walk
  # makes every handshake real.
  defp profile do
    name = String.to_atom("popcorn_tls_" <> Integer.to_string(:erlang.unique_integer([:positive])))

    case :inets.start(:httpc, profile: name) do
      {:ok, _pid} -> name
      {:error, {:already_started, _pid}} -> name
      {:error, _} -> :default
    end
  end

  defp body_slice(body) when is_binary(body), do: String.slice(body, 0, 120)
  defp body_slice(other), do: String.slice(inspect(other), 0, 120)
end
