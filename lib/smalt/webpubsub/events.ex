defmodule Smalt.WebPubSub.Events do
  @moduledoc """
  CloudEvents 1.0 webhook emission for the Web PubSub face (AZ-5).

  Real Azure Web PubSub pushes client lifecycle events (`connect`,
  `connected`, `disconnected`) to the configured upstream event handler
  as CloudEvents, in binary-mode (the `ce-*` HTTP headers carry the
  envelope; cite https://learn.microsoft.com/azure/azure-web-pubsub/
  cloud-events-reference:
    ce-type: azure.webpubsub.sys.connect / azure.webpubsub.sys.connected /
             azure.webpubsub.sys.disconnected
    ce-source: /hubs/<hub>/client/<connectionId>
    ce-specversion: 1.0, `"delivered"` / `"delivery_status"` witness keys
    (EXPL-11 F2)).
  The emulator emits the same binary-mode headers. The body is a JSON
  document of connection details (real service sends an empty body for
  connect/connected/disconnected -- divergence noted in the receipt).

  Air-gap law: the handler URL must be loopback (fail-closed host check).
  `# KD-COVERS: KD-166`

  EXPL-11 F2 law: the witness buffer never launders a dropped POST.
  Every recorded event carries `"delivered"` (boolean) and
  `"delivery_status"` (one of `"no_handler"` | `"pending"` | `"delivered"`
  | `"refused:<reason>"`). `connect/3` still returns `:ok` (async module
  contract) but the witness buffer tells the truth: only a real 2xx from
  the handler flips `delivered` to true.
  """

  @spec connect(binary, binary, binary) :: :ok
  def connect(hub, conn_id, user_id), do: emit(hub, conn_id, user_id, "azure.webpubsub.sys.connect")

  @spec connected(binary, binary, binary) :: :ok
  def connected(hub, conn_id, user_id),
    do: emit(hub, conn_id, user_id, "azure.webpubsub.sys.connected")

  @spec disconnected(binary, binary, binary) :: :ok
  def disconnected(hub, conn_id, user_id),
    do: emit(hub, conn_id, user_id, "azure.webpubsub.sys.disconnected")

  @doc "User event from the client (`event` message, ce-type ...sys.custom)."
  @spec emit_custom(binary, binary, binary, binary, term) :: :ok
  def emit_custom(hub, conn_id, user_id, evt, data) do
    :ok = emit(hub, conn_id, user_id, "azure.webpubsub.sys.custom", %{"event" => evt, "data" => data})
  end

  defp emit(hub, conn_id, user_id, ce_type) do
    emit(hub, conn_id, user_id, ce_type, nil)
  end

  defp emit(hub, conn_id, user_id, ce_type, data) do
    event = %{
      "specversion" => "1.0",
      "id" => event_id(),
      "type" => non_nil_ce(ce_type),
      "source" => "/hubs/#{hub}/client/#{conn_id}",
      "time" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "hub" => hub,
      "connectionId" => conn_id,
      "userId" => user_id,
      "data" => data,
      # EXPL-11 F2: delivery typing. `false` until a real 2xx from the
      # handler proves delivery — never a bare :ok-only story.
      "delivered" => false,
      "delivery_status" => "pending"
    }

    # Witness buffer (in-process) -- always, HTTP-independent.
    GenServer.cast(Smalt.WebPubSub, {:record_event, event})

    case handler_url() do
      nil ->
        GenServer.cast(Smalt.WebPubSub, {:delivery_result, event["id"], false, "no_handler"})
        :ok

      url ->
        # Delivery stays async (module contract), but the result of the
        # real POST is checked and the witness buffer is told the truth.
        spawn(fn -> deliver(url, event) end)
        :ok
    end
  end

  @doc false
  def deliver(url, event) do
    body = Jason.encode!(event)

    headers = [
      {~c"content-type", ~c"application/json"},
      {~c"ce-specversion", ~c"1.0"},
      {~c"ce-id", to_charlist(event["id"])},
      {~c"ce-source", to_charlist(event["source"])},
      {~c"ce-type", to_charlist(event["type"])},
      {~c"ce-time", to_charlist(event["time"])},
      {~c"ce-hub", to_charlist(event["hub"])},
      {~c"ce-connectionId", to_charlist(event["connectionId"])},
      {~c"ce-userId", to_charlist(event["userId"])}
    ]

    {delivered?, status} =
      case :httpc.request(:post, {to_charlist(url), headers, ~c"application/json", body}, [
             {:timeout, 5_000},
             {:connect_timeout, 5_000}
           ], []) do
        {:ok, {{_http_ver, code, _phrase}, _hdrs, _body}} when code in 200..299 ->
          {true, "delivered"}

        {:ok, {{_http_ver, code, _phrase}, _hdrs, _body}} ->
          {false, "refused:#{code}"}

        {:error, reason} ->
          {false, "refused:#{inspect(reason)}"}
      end

    GenServer.cast(Smalt.WebPubSub, {:delivery_result, event["id"], delivered?, status})
  rescue
    e ->
      GenServer.cast(Smalt.WebPubSub, {:delivery_result, event["id"], false, "refused:#{inspect(e)}"})
  end

  defp event_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # ce-type and ce-userId headers must be binary strings; a nil userId is
  # emitted as an empty header value (real service omits it — documented
  # divergence), never a crash.
  defp non_nil_ce(nil), do: ""
  defp non_nil_ce(v) when is_binary(v), do: v
  defp non_nil_ce(v), do: to_string(v)

  defp handler_url do
    case Application.get_env(:smalt, :web_pubsub_event_handler_url, nil) do
      nil -> nil
      url -> assert_loopback!(to_string(url))
    end
  end

  # Air-gap law: fail-closed loopback host check on the configured handler.
  defp assert_loopback!(url) do
    host = URI.parse(url).host || ""

    unless host in ["127.0.0.1", "localhost", "::1"] do
      raise ArgumentError, "webpubsub event handler must be loopback, got: #{host}"
    end

    url
  end
end
