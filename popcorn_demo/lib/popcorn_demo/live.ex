defmodule PopcornDemo.Live do
  @moduledoc """
  Live loopback leg: the in-browser slice talks to the real smalt substrate.

  Uses `Popcorn.Fetch` (browser `fetch()`) against the ARM control plane on
  `127.0.0.1:<control_plane_port>` — plain HTTP, CORS `*`, preflight OPTIONS
  auth-exempt. Walks the lawful auth path: exempt metadata/tenants probes,
  exempt STS token mint, then a Bearer-authed `/subscriptions` round-trip.

  HTTP hops route through the `PopcornDemo.Transport` behaviour: in browser
  (`Popcorn.JS.available?()`) the real `Popcorn.Fetch`; on host (`mix test`,
  `mix run`) the real loopback-only `PopcornDemo.Transport.Httpc` — a real
  degraded collaborator, not a mock.

  Host-side with no substrate the Httpc transport errors and `run/0` returns
  `{:skip, {:substrate_down, reason}}` — the formatted skip carries a
  redacted, 120-char-capped slice of the real reason instead of masking it.

  Receipt hygiene: every `format/1` clause routes through
  `PopcornDemo.Redact.fragment/1` — any JWT-shaped substring (`eyJ…`) is
  collapsed to `eyJ<redacted>` and the final fragment is capped at 120
  chars, so bearer tokens never reach receipts/logs even when a FAIL path
  embeds a response body.
  """

  require Logger

  alias PopcornDemo.Redact

  @client_id "popcorn-demo"
  @client_secret "popcorn-demo"
  @subscriptions_api_version "2022-12-01"

  def run do
    bridge? = Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()

    transport = if bridge?, do: PopcornDemo.Transport.Fetch, else: PopcornDemo.Transport.Httpc

    result = walk(transport)
    Logger.info("popcorn_demo live leg: #{format(result)}")
    result
  end

  @doc "Receipt fragment for the combined smoke line. Redacted + capped."
  def format({:ok, detail}), do: Redact.fragment("live=OK(" <> detail <> ")")

  def format({:skip, {:substrate_down, reason}}) do
    # Keep the "live=SKIP" prefix: the smoke gate exits 3 on any live=SKIP.
    # Connection-refused shapes mean the substrate is simply not listening;
    # anything else is a transport-level fault and is labeled as such. In the
    # browser there is no econnrefused: a refused/blocked loopback hop surfaces
    # as the fetch "TypeError: Failed to fetch" family (witnessed on the
    # substrate-down negative, 2026-10-22) — same skip class, still loud.
    tag =
      if reason =~ ~r/econnrefused|failed to fetch/i, do: "substrate-down", else: "transport"
    Redact.fragment("live=SKIP(" <> tag <> ":" <> reason <> ")")
  end

  def format({:skip, :substrate_down}), do: "live=SKIP(substrate-down)"
  def format({:skip, :no_bridge}), do: "live=SKIP(no-bridge)"

  def format({:fail, detail}), do: Redact.fragment("live=FAIL(" <> detail <> ")")

  defp walk(transport) do
    base = "http://127.0.0.1:#{Smalt.Registry.control_plane_port()}"

    with {:ok, _} <- probe_endpoints(transport, base),
         {:ok, tid} <- fetch_tenant(transport, base),
         {:ok, token} <- mint_token(transport, base, tid),
         {:ok, subs} <- list_subscriptions(transport, base, token) do
      {:ok, "endpoints,tenants,sts,subscriptions=" <> Integer.to_string(subs)}
    else
      {:skip, {:substrate_down, reason}} -> {:skip, {:substrate_down, reason}}
      {:fail, step, reason} -> {:fail, step <> ":" <> reason}
    end
  end

  defp probe_endpoints(transport, base) do
    case get(transport, base <> "/metadata/endpoints") do
      {:ok, 200, _body} -> {:ok, :endpoints}
      {:ok, status, _} -> {:fail, :endpoints, "status=" <> Integer.to_string(status)}
      skip_or_fail -> skip_or_fail
    end
  end

  defp fetch_tenant(transport, base) do
    case get(transport, base <> "/tenants") do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"value" => [%{"tenantId" => tid} | _]}} when is_binary(tid) -> {:ok, tid}
          other -> {:fail, :tenants, "shape=" <> inspect(other)}
        end

      {:ok, status, _} ->
        {:fail, :tenants, "status=" <> Integer.to_string(status)}

      skip_or_fail ->
        skip_or_fail
    end
  end

  defp mint_token(transport, base, tid) do
    form =
      URI.encode_query(%{
        "grant_type" => "client_credentials",
        "client_id" => @client_id,
        "client_secret" => @client_secret
      })

    case request(transport, %{
           method: "POST",
           url: base <> "/" <> tid <> "/oauth2/v2.0/token",
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body: form
         }) do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"access_token" => token}} when is_binary(token) -> {:ok, token}
          other -> {:fail, :sts, "shape=" <> inspect(other)}
        end

      {:ok, status, body} ->
        {:fail, :sts, "status=" <> Integer.to_string(status) <> " body=" <> binary_slice(body)}

      skip_or_fail ->
        skip_or_fail
    end
  end

  defp list_subscriptions(transport, base, token) do
    url = base <> "/subscriptions?api-version=" <> @subscriptions_api_version

    case request(transport, %{
           method: "GET",
           url: url,
           headers: [{"authorization", "Bearer " <> token}]
         }) do
      {:ok, 200, body} ->
        case Jason.decode(body) do
          {:ok, %{"value" => subs}} when is_list(subs) -> {:ok, length(subs)}
          other -> {:fail, :subscriptions, "shape=" <> inspect(other)}
        end

      {:ok, status, body} ->
        {:fail, :subscriptions,
         "status=" <> Integer.to_string(status) <> " body=" <> binary_slice(body)}

      skip_or_fail ->
        skip_or_fail
    end
  end

  defp get(transport, url), do: request(transport, %{method: "GET", url: url})

  defp request(transport, req) do
    case transport.request(req) do
      {:ok, %{status: status, body: body}} -> {:ok, status, body}
      {:error, {:fetch, msg}} -> {:skip, {:substrate_down, inspect(msg)}}
      {:error, {:httpc, reason}} -> {:skip, {:substrate_down, inspect(reason)}}
      {:error, other} -> {:fail, :fetch, inspect(other)}
    end
  end

  defp binary_slice(body) when is_binary(body), do: body |> String.slice(0, 120)
  defp binary_slice(other), do: inspect(String.slice(inspect(other), 0, 120))
end
