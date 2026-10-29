defmodule PopcornDemo.LiveEgd do
  @moduledoc """
  Event Grid DELIVERY leg (X4): the publish leg exists (`LiveEG`); this leg
  closes the LOCAL delivery half in-memory. KD-101 pins push-to-REMOTE as
  air-gapped (typed 400 `EventGridWebhookPushUnsupported`); it does NOT pin
  the local face — the receiver `Smalt.EventGridWebhookPlug` is a mountable
  plug, so this leg MOUNTS it on a real Bandit listener on an ephemeral
  loopback port and walks the full delivery contract over the real wire:

    1. mount — `Smalt.EventGridWebhookPlug` on Bandit, 127.0.0.1, port 0
       (ephemeral; the real port is discovered via :inet.port/1);
    2. handshake 1 — POST with `WebHook-Request-Origin` → 200 with
       `webhook-allowed-origin` / `webhook-allowed-rate` response headers;
    3. handshake 2 — POST a batch carrying
       `Microsoft.EventGrid.SubscriptionValidationEvent` →
       200 `{"validationResponse": "<code>"}` and NOT delivered;
    4. deliver — POST an EG1-shaped CloudEvent (the same envelope class the
       8443 ingest admits) → 200 `{"received": true}` and the registered
       in-process subscriber receives `{:event_grid_webhook, name, id, ev}`;
    5. byte-shape — the delivered map equals the published envelope under
       JSON round-trip equality (all EG1 fields present, nothing added).

  Chicago school: the only collaborators are REAL — a real Bandit/Thousand-
  Island listener on a real socket, the real receiver plug, the real
  delivery GenServer, and the real `Transport.Httpc` client over loopback.
  No mocks.

  KD-101 status is unchanged (remote push stays air-gapped); this leg closes
  the LOCAL delivery face and leaves the register row alone.

  Receipt (run/0 return), house style:
    {:ok,    "egd=OK(<port>:handshake1-handshake2-delivery-eg1shape)"}
    {:skip,  "egd=SKIP(kd101-airgap:local-delivery-unimplemented)"}  -- typed
    {:error, "egd=FAIL(<step>:<reason>)"}
  """

  alias PopcornDemo.Transport.Httpc
  alias Smalt.EventGridWebhook

  @subscriber "egd-x4-sub"
  @origin "egd.example"

  @doc """
  Runs the delivery walk. The Bandit listener is ephemeral (port 0); it is
  ALWAYS shut down before run/0 returns — success, SKIP, or FAIL.
  """
  @spec run() :: {:ok, binary()} | {:skip, binary()} | {:error, binary()}
  def run do
    case mount() do
      {:ok, listener, port} ->
        try do
          walk(port)
        after
          teardown(listener)
        end

      {:skip, _} = skip ->
        skip

      {:error, _} = err ->
        err
    end
  end

  # -- Steps -------------------------------------------------------------------

  # Warm the host code path with the substrate build's compiled ebins (the
  # popcorn_demo project does not declare bandit/plug deps; the beams live in
  # the smalt checkout's test build — live_param/live_matrix precedent).
  defp mount do
    code_paths()

    if Code.ensure_loaded?(Bandit) and Code.ensure_loaded?(Smalt.EventGridWebhook) do
      do_mount()
    else
      {:skip, "egd=SKIP(kd101-airgap:local-delivery-unimplemented)"}
    end
  end

  defp do_mount do
    case ensure_registry() do
      {:ok, _reg} ->
        case Bandit.start_link(
               plug: {Smalt.EventGridWebhookPlug, []},
               scheme: :http,
               ip: {127, 0, 0, 1},
               port: 0
             ) do
          {:ok, listener} ->
            case ThousandIsland.listener_info(listener) do
              {:ok, {{127, 0, 0, 1}, port}} when is_integer(port) and port > 0 ->
                {:ok, listener, port}

              other ->
                {:error, "egd=FAIL(mount:listener-info-#{inspect(other)})"}
            end

          {:error, reason} ->
            {:error, "egd=FAIL(mount:bandit-#{redact(inspect(reason))})"}
        end

      {:error, reg_err} ->
        {:error, "egd=FAIL(mount:registry-#{redact(inspect(reg_err))})"}
    end
  end

  defp ensure_registry do
    if Process.whereis(EventGridWebhook) do
      EventGridWebhook.reset()
      {:ok, Process.whereis(EventGridWebhook)}
    else
      case EventGridWebhook.start_link([]) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp walk(port) do
    EventGridWebhook.register(@subscriber)
    base = "http://127.0.0.1:#{port}/eventgrid/hooks/#{@subscriber}"

    with :ok <- handshake1(base),
         {:ok, _code} <- handshake2(base),
         :ok <- deliver(base) do
      {:ok, "egd=OK(#{port}:handshake1-handshake2-delivery-eg1shape)"}
    else
      {:error, _} = err -> err
    end
  end

  # Handshake 1: WebHook-Request-Origin answered 200 + allowed-origin/rate
  # headers, and NO delivery consumed (delivered/1 stays empty).
  defp handshake1(base) do
    # Handshake 1 rides GET/OPTIONS with WebHook-Request-Origin (the plug's
    # CORS-style face); :httpc refuses a bodyless POST (invalid_request), and
    # the receiver plug answers OPTIONS/GET identically.
    case Httpc.request(%{
           method: "GET",
           url: base,
           headers: [
             {"webhook-request-origin", @origin},
             {"webhook-request-rate", "500K"}
           ]
         }) do
      {:ok, %{status: 200, headers: headers}} ->
        lower = downcase_headers(headers)

        if Enum.member?(lower, {"webhook-allowed-origin", @origin}) and
             Enum.member?(lower, {"webhook-allowed-rate", "500K"}) do
          assert_no_delivery("handshake1")
        else
          {:error, "egd=FAIL(handshake1:missing-allowed-headers-#{inspect(lower)})"}
        end

      {:ok, %{status: s, body: b}} ->
        {:error, "egd=FAIL(handshake1:status-#{s}-#{redact(short(b))})"}

      {:error, reason} ->
        {:error, "egd=FAIL(handshake1:transport-#{redact(inspect(reason))})"}
    end
  end

  # Handshake 2: SubscriptionValidationEvent answered with the echoed code,
  # NOT delivered.
  defp handshake2(base) do
    code = "VAL-" <> Integer.to_string(System.unique_integer([:positive]))

    body =
      Jason.encode!([
        %{
          "specversion" => "1.0",
          "id" => "val-" <> code,
          "source" => "/smalt/egd",
          "type" => "Microsoft.EventGrid.SubscriptionValidationEvent",
          "data" => %{"validationCode" => code}
        }
      ])

    case post_events(base, body) do
      {:ok, %{status: 200, body: resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"validationResponse" => ^code}} ->
            {:ok, code}

          {:ok, other} ->
            {:error, "egd=FAIL(handshake2:wrong-response-#{redact(inspect(other))})"}

          _ ->
            {:error, "egd=FAIL(handshake2:non-json-#{redact(short(resp))})"}
        end

      {:ok, %{status: s, body: b}} ->
        {:error, "egd=FAIL(handshake2:status-#{s}-#{redact(short(b))})"}

      {:error, reason} ->
        {:error, "egd=FAIL(handshake2:transport-#{redact(inspect(reason))})"}
    end
  end

  # Delivery: EG1 CloudEvent over the real wire; the registered subscriber
  # (this process) receives the delivered envelope; byte-shape via exact map
  # equality after JSON round trip.
  defp deliver(base) do
    id = "egd-" <> Integer.to_string(System.unique_integer([:positive]))

    event = %{
      "specversion" => "1.0",
      "id" => id,
      "source" => "/smalt/egd/publish",
      "type" => "smalt.egd.delivered",
      "data" => %{"topic" => "pegl3-egd", "seq" => 1},
      "datacontenttype" => "application/json"
    }

    case post_events(base, Jason.encode!(event)) do
      {:ok, %{status: 200, body: resp}} ->
        case Jason.decode(resp) do
          {:ok, %{"received" => true}} ->
            await_delivery(id, event)

          {:ok, other} ->
            {:error, "egd=FAIL(delivery:unexpected-body-#{redact(inspect(other))})"}

          _ ->
            {:error, "egd=FAIL(delivery:non-json-#{redact(short(resp))})"}
        end

      {:ok, %{status: s, body: b}} ->
        {:error, "egd=FAIL(delivery:status-#{s}-#{redact(short(b))})"}

      {:error, reason} ->
        {:error, "egd=FAIL(delivery:transport-#{redact(inspect(reason))})"}
    end
  end

  # Bounded receive (no-sleep law): the message rides the same GenServer call
  # the plug made, so it is already in this mailbox when the 200 lands — a
  # plain receive is structurally synchronized; the 2s deadline only turns a
  # broken contract into a typed FAIL, never a wait-and-hope pass.
  defp await_delivery(id, event) do
    receive do
      {:event_grid_webhook, @subscriber, ^id, ev} ->
        if normalize(ev) == normalize(event) do
          assert_pull_record(id, event)
        else
          {:error, "egd=FAIL(eg1shape:delivered-#{redact(inspect(ev))})"}
        end

      {:event_grid_webhook, _sub, other_id, _ev} ->
        {:error, "egd=FAIL(delivery:wrong-id-#{other_id})"}
    after
      2_000 ->
        {:error, "egd=FAIL(delivery:no-message-timeout-#{id})"}
    end
  end

  defp assert_pull_record(id, event) do
    case Map.get(EventGridWebhook.delivered(@subscriber), id) do
      %{"event" => stored} ->
        if normalize(stored) == normalize(event) do
          :ok
        else
          {:error, "egd=FAIL(delivery:pull-record-mismatch-#{id})"}
        end

      nil ->
        {:error, "egd=FAIL(delivery:no-pull-record-#{id})"}
    end
  end

  defp assert_no_delivery(step) do
    case map_size(EventGridWebhook.delivered(@subscriber)) do
      0 -> :ok
      n -> {:error, "egd=FAIL(#{step}:unexpected-deliveries-#{n})"}
    end
  end

  # -- Transport -----------------------------------------------------------------

  defp post_events(url, body) do
    Httpc.request(%{
      method: "POST",
      url: url,
      headers: [{"content-type", "application/cloudevents-batch+json"}],
      body: body
    })
  end

  defp downcase_headers(headers) do
    for {k, v} <- headers do
      {String.downcase(to_string(k)), to_string(v)}
    end
  end

  # JSON round trip normalizes atom/binary keys so map equality is the
  # byte-shape claim (all published EG1 attributes present, nothing added).
  defp normalize(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), normalize(v)} end)
  defp normalize(other), do: other

  defp short(b) when is_binary(b), do: String.slice(b, 0, 120)
  defp short(other), do: inspect(other) |> String.slice(0, 120)

  defp redact(text) do
    if Code.ensure_loaded?(PopcornDemo.Redact) do
      PopcornDemo.Redact.fragment(text)
    else
      text
    end
  end

  defp teardown(listener) do
    if Process.alive?(listener) do
      ThousandIsland.stop(listener)
    end

    if pid = Process.whereis(EventGridWebhook) do
      GenServer.stop(pid, :normal)
    end

    :ok
  end

  defp code_paths do
    # popcorn_demo lives inside the smalt checkout; the substrate's own test
    # build carries the compiled bandit/plug/smalt beams this leg mounts.
    root = Path.expand("../../../_build/test/lib", __DIR__)

    case File.ls(root) do
      {:ok, apps} ->
        Enum.each(apps, fn app ->
          path = Path.join([root, app, "ebin"])

          if File.dir?(path), do: :code.add_pathz(String.to_charlist(path))
        end)

      _ ->
        :ok
    end

    :ok
  end
end
