defmodule PopcornDemo.LiveEG do
  @moduledoc """
  Event Grid leg (lane W3-9): system topics landed in the v26.10.19 semantic
  wave. Chicago walk — the only collaborators are the REAL substrate over the
  REAL wire:

    1. bearer — STS token minted over the wire (enforce mode, 9443);
    2. topic — create-or-reuse an ARM `Microsoft.EventGrid/systemTopics`
       topic on 9443 (real PUT, api-version 2022-06-15 — the latest the
       control plane admits; 2023-06-01 400s InvalidApiVersionParameter),
       declared `inputSchema: "EventGrid"` so the 8443 ingest admits the
       native EG1 envelope;
    3. publish — real POST of one EG1 event to the topic endpoint face
       `POST /topics/<name>/events` on 8443;
    4. readback — GET the same feed, assert the published id returned;
    5. webhook face — typed probe only: a WebHook eventSubscription with a
       REMOTE endpointUrl is refused 400 `EventGridWebhookPushUnsupported`
       (KD-101). Push delivery to a loopback https endpoint is NOT wired (no
       delivery engine POSTs to `endpointUrl`; the receiver plug
       `Smalt.EventGridWebhookPlug` is mountable but not mounted on any
       port), so a `:gen_tcp` listener would receive nothing — publish-only
       with this typed detail instead of a fake webhook pass.

  Transport (second-tranche consolidation): all HTTP rides
  `PopcornDemo.Transport` (browser: `Transport.Fetch`, host:
  `Transport.Httpc`) — the former raw `:gen_tcp` HTTP/1.1 client (headers,
  chunked decoding, dechunker) is deleted. `Transport.Httpc` honors the
  caller's content-type (ERRC-E2 close), so the application/json ingest
  gate is satisfied without a private path.

  Header-parse gap note: the deleted raw client parsed response HEADERS
  (only for `transfer-encoding: chunked` dechunking — `:httpc` dechunks
  natively, and `Popcorn.Fetch` hands the assembled body). No walk step
  consumes a header-only value: topic endpoint, feed, and KD-101 refusal
  code all live in response BODIES, so nothing is lost. Transport returns
  RAW binary bodies; best-effort JSON decode stays at this module's edge
  (`decode_body/1`).

  Receipt: `eg=OK(<topic>:bearer-topic-publish-readback-kd101refusal)` |
  `eg=FAIL(<step>:<reason>)`. SKIP is reserved for the wasm environment
  fact: in the browser BEAM, transports without a JS-bridge backing answer
  `eprotonosupport`/`not available`/`popcorn_fetch_unavailable` — a loud
  `eg=SKIP(wasm-transport:<step>)`, never a FAIL (the host run is the real
  witness for this leg). Host-side transport errors (e.g. connection
  refused with the substrate down) are NOT wasm facts and stay typed FAILs.
  The Chicago test skips loudly when the substrate is down.
  """

  alias PopcornDemo.Redact

  @base_ctrl "http://127.0.0.1:9443"
  @base_data "http://127.0.0.1:8443"
  @tenant "smalt-tenant"
  @subscription "11111111-1111-1111-1111-111111111111"
  @rg "popcorn-eg"
  @api_version "2022-06-15"

  # Run-unique topic: sibling lanes share the control-plane ETS; a per-run
  # name keeps the walk hermetic (create-always, no reuse collision).
  defp topic_name, do: "pegl3" <> Integer.to_string(System.system_time(:millisecond))

  @doc """
  Runs the walk. Returns `{:ok, "eg=OK(<topic>:<stages>)"}`,
  `{:skip, "eg=SKIP(<reason>)"}` or `{:error, "eg=FAIL(<step>:<reason>)"}`.
  """
  def run do
    topic = topic_name()

    with {:ok, token} <- token(),
         :ok <- topic_put(topic, token),
         :ok <- publish(topic, token),
         :ok <- readback(topic, token),
         :ok <- kd101_refusal(topic, token) do
      {:ok, "eg=OK(#{topic}:bearer-topic-publish-readback-kd101refusal)"}
    else
      # Browser reality: transports without a JS-bridge backing do not exist
      # in the wasm BEAM (eprotonosupport / transport-unavailable) — an
      # environment fact, loud SKIP, never a FAIL (the host run is the real
      # witness for this leg). Host transport failures are NOT environment
      # facts and surface as typed FAILs.
      {:error, {step, reason}} when is_binary(step) ->
        text = to_text(reason)

        if text =~ "eprotonosupport" or text =~ "not available" or
             text =~ "popcorn_fetch_unavailable" or text =~ "Failed to fetch" or
             text =~ "blocked" do
          {:skip, "eg=SKIP(wasm-transport:#{step})"}
        else
          {:error, "eg=FAIL(#{step}:#{text})"}
        end
    end
  end

  # -- transport -------------------------------------------------------------

  defp browser? do
    Code.ensure_loaded?(Popcorn.JS) and function_exported?(Popcorn.JS, :available?, 0) and
      Popcorn.JS.available?()
  end

  defp req(request) do
    if browser?() do
      request |> PopcornDemo.Transport.Fetch.request() |> decode_body()
    else
      request |> PopcornDemo.Transport.Httpc.request() |> decode_body()
    end
  end

  defp decode_body({:ok, %{body: body} = resp}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, %{resp | body: decoded}}
      _ -> {:ok, resp}
    end
  end

  defp decode_body(other), do: other

  defp to_text(r) when is_binary(r), do: Redact.fragment(r)
  defp to_text(r), do: Redact.fragment(inspect(r))

  # -- walk steps ------------------------------------------------------------

  defp token do
    req(%{
      method: "POST",
      url: @base_ctrl <> "/#{@tenant}/oauth2/v2.0/token",
      headers: [{"content-type", "application/x-www-form-urlencoded"}],
      body: "grant_type=client_credentials&client_id=popcorn-eg&client_secret=not-checked"
    })
    |> case do
      {:ok, %{status: 200, body: %{"access_token" => tok}}} when is_binary(tok) ->
        {:ok, tok}

      {:ok, %{status: st, body: body}} ->
        {:error, {"token", "http-#{st}:#{Redact.fragment(str(body))}"}}

      {:error, reason} ->
        {:error, {"token", to_text(reason)}}
    end
  end

  defp topic_put(topic, token) do
    req(%{
      method: "PUT",
      url:
        @base_ctrl <>
          "/subscriptions/#{@subscription}/resourceGroups/#{@rg}/providers/" <>
          "Microsoft.EventGrid/systemTopics/#{topic}?api-version=#{@api_version}",
      headers: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "location" => "westus2",
          "properties" => %{
            "inputSchema" => "EventGrid",
            "topicType" => "Microsoft.EventGrid.CustomTopics"
          }
        })
    })
    |> case do
      {:ok, %{status: st, body: %{"properties" => %{"endpoint" => ep, "inputSchema" => "EventGrid"}}}}
      when st in [200, 201] and is_binary(ep) ->
        :ok

      {:ok, %{status: st, body: body}} when st in [200, 201] ->
        {:error, {"topic", "put-body-missing-endpoint-or-schema:#{Redact.fragment(str(body))}"}}

      {:ok, %{status: st, body: body}} ->
        {:error, {"topic", "http-#{st}:#{Redact.fragment(str(body))}"}}

      {:error, reason} ->
        {:error, {"topic", to_text(reason)}}
    end
  end

  defp publish(topic, token) do
    req(%{
      method: "POST",
      url: @base_data <> "/topics/#{topic}/events",
      headers: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "id" => "w39-" <> topic,
          "subject" => "smalt/w39",
          "eventType" => "popcorn.eg.probe",
          "eventTime" => "2026-10-20T00:00:00Z",
          "data" => %{"lane" => "W3-9", "topic" => topic}
        })
    })
    |> case do
      # The ingest answers 200 with an EMPTY body (witnessed over the wire,
      # 2026-10-20); the id-witness is the readback step, not this body.
      {:ok, %{status: 200}} ->
        :ok

      {:ok, %{status: st, body: body}} ->
        {:error, {"publish", "http-#{st}:#{Redact.fragment(str(body))}"}}

      {:error, reason} ->
        {:error, {"publish", to_text(reason)}}
    end
  end

  defp readback(topic, token) do
    req(%{
      method: "GET",
      url: @base_data <> "/topics/#{topic}/events",
      headers: [{"authorization", "Bearer " <> token}]
    })
    |> case do
      {:ok, %{status: 200, body: evs}} when is_list(evs) ->
        assert_published(evs, topic)

      {:ok, %{status: 200, body: body}} ->
        {:error, {"readback", "non-list-feed:#{Redact.fragment(str(body))}"}}

      {:ok, %{status: st, body: body}} ->
        {:error, {"readback", "http-#{st}:#{Redact.fragment(str(body))}"}}

      {:error, reason} ->
        {:error, {"readback", to_text(reason)}}
    end
  end

  defp assert_published(evs, topic) do
    if Enum.any?(evs, &(&1["id"] == "w39-" <> topic)),
      do: :ok,
      else: {:error, {"readback", "published-id-absent-in-feed"}}
  end

  # KD-101 typed face: a remote WebHook destination is refused BEFORE the
  # subscription record exists. The typed code is the assertion.
  defp kd101_refusal(topic, token) do
    req(%{
      method: "PUT",
      url:
        @base_ctrl <>
          "/subscriptions/#{@subscription}/resourceGroups/#{@rg}/providers/" <>
          "Microsoft.EventGrid/systemTopics/#{topic}/eventSubscriptions/es-w39?api-version=#{@api_version}",
      headers: [{"authorization", "Bearer " <> token}, {"content-type", "application/json"}],
      body:
        Jason.encode!(%{
          "properties" => %{
            "destination" => %{
              "endpointType" => "WebHook",
              "properties" => %{"endpointUrl" => "https://example.com/hook"}
            }
          }
        })
    })
    |> case do
      {:ok, %{status: 400, body: %{"error" => %{"code" => "EventGridWebhookPushUnsupported"}}}} ->
        :ok

      {:ok, %{status: 400, body: body}} ->
        {:error, {"kd101", "refusal-not-typed:#{Redact.fragment(str(body))}"}}

      {:ok, %{status: st, body: body}} ->
        {:error, {"kd101", "http-#{st}:#{Redact.fragment(str(body))}"}}

      {:error, reason} ->
        {:error, {"kd101", to_text(reason)}}
    end
  end

  defp str(b) when is_binary(b), do: b
  defp str(b), do: Jason.encode!(b)
end
