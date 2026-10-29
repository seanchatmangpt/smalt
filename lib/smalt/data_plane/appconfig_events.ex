defmodule Smalt.DataPlane.AppConfigEvents do
  @moduledoc """
  App Configuration key-value change event-notification face (PRD-APPCONF
  push sub-claim, v26.10.21).

  Real Azure App Configuration has no WebSocket/push channel for SDK
  `ConfigurationClient` — the real mechanism is Event Grid: a topic with an
  event subscription whose WebHook destination receives a typed Event Grid
  envelope on every key-value create/modify. This module implements that
  webhook contract inside the air-gap law:

    * **Subscription registry** — `subscribe/3` registers an endpoint that is
      either (a) an in-process `pid` receiver, or (b) a webhook endpoint URL
      that must be loopback (127.0.0.1 / localhost / [::1]); a non-loopback
      URL is a typed refusal, fail-closed (SSRF / air-gap law). Duplicated
      name re-registration replaces the endpoint.
    * **Event emission** — `emit/3` builds the typed Event Grid envelope
      (eventType `Microsoft.AppConfiguration.KeyValueModified` /
      `...KeyValueDeleted`, subject `AppConfiguration.KeyValue:<key>:<label>`,
      data carrying key/label/etag) and delivers to every subscriber.
    * **Delivery** — pid subscribers receive
      `{:appconfig_kv_event, name, event}` in their inbox and the event is
      recorded for pull (`events/0`). URL (loopback webhook) subscribers are
      recorded with their endpoint but HTTP POST delivery is typed
      **UNSUPPORTED-by-airgap**: the substrate has zero outbound dial
      (zero outbound-dial sites in `lib/` — no HTTP client, no outbound
      :gen_tcp.connect anywhere), so the honest cell is a recorded
      `{:error, {:unsupported, :http_delivery_airgap}}` outcome per event,
      never a silent drop and never a faked pass.

  The envelope shape matches what a real Event Grid → webhook receiver sees
  (id / topic / subject / eventType / eventTime / data / dataVersion), so a
  receiver that parses real Event Grid POST bodies parses this.
  """

  use GenServer

  @name __MODULE__
  @loopback_hosts MapSet.new(["127.0.0.1", "localhost", "::1", "[::1]"])
  @max_events 1000
  @modified "Microsoft.AppConfiguration.KeyValueModified"
  @deleted "Microsoft.AppConfiguration.KeyValueDeleted"

  # -- Client API ---------------------------------------------------------------

  @doc "Starts the registry (lazy-start, EventGridWebhook pattern)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  @doc "Ensures the registry runs; returns the server pid."
  @spec server() :: pid()
  def server do
    case Process.whereis(@name) do
      nil ->
        case start_link([]) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  @doc """
  Registers subscription `name`. `endpoint` is `pid()` (in-process receiver)
  or a binary webhook URL (must be loopback — non-loopback is a typed refusal,
  fail-closed). Returns `:ok` or `{:error, {:refused, :non_loopback_endpoint}}`.
  """
  @spec subscribe(term(), pid() | String.t()) ::
          :ok | {:error, {:refused, :non_loopback_endpoint}}
  def subscribe(name, endpoint, pid \\ nil)

  def subscribe(name, endpoint, _pid) when is_binary(endpoint) do
    case loopback?(endpoint) do
      true ->
        GenServer.call(server(), {:subscribe, name, {:url, endpoint}})
        :ok

      false ->
        {:error, {:refused, :non_loopback_endpoint}}
    end
  end

  def subscribe(name, pid, _) when is_pid(pid), do: subscribe_pid(name, pid)

  @doc "Registers `name` with an explicit in-process receiver pid."
  @spec subscribe_pid(term(), pid()) :: :ok
  def subscribe_pid(name, pid), do: GenServer.call(server(), {:subscribe, name, {:pid, pid}})

  @doc "Unregisters `name`."
  @spec unsubscribe(term()) :: :ok
  def unsubscribe(name), do: GenServer.call(server(), {:unsubscribe, name})

  @doc "Returns the subscription table: %{name => {:pid, pid} | {:url, url}}."
  @spec subscriptions() :: map()
  def subscriptions, do: GenServer.call(server(), :subscriptions)

  @doc "Returns recorded events (newest last), capped ring."
  @spec events() :: [map()]
  def events, do: GenServer.call(server(), :events)

  @doc "Clears registry + event log (test seam)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(server(), :reset)

  @doc """
  Emits a typed Event Grid envelope for a key-value write (create or modify).
  `record` needs `"key"`, `"label"`, `"etag"`. Delivers to pid subscribers
  (send) and records one outcome per subscriber (url subscribers get the
  typed `{:error, {:unsupported, :http_delivery_airgap}}` outcome).
  """
  @spec emit(String.t(), String.t(), String.t(), :modified | :deleted) :: [map()]
  def emit(key, label, etag, change \\ :modified) when change in [:modified, :deleted] do
    event = envelope(key, label, etag, change)
    GenServer.call(server(), {:emit, event})
  end

  # -- Server -------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{subs: %{}, events: :queue.new(), count: 0}}

  @impl true
  def handle_call({:subscribe, name, ep}, _from, state) do
    {:reply, :ok, put_in(state.subs[name], ep)}
  end

  def handle_call({:unsubscribe, name}, _from, state) do
    {:reply, :ok, %{state | subs: Map.delete(state.subs, name)}}
  end

  def handle_call(:subscriptions, _from, state), do: {:reply, state.subs, state}

  def handle_call(:events, _from, state),
    do: {:reply, state.events |> :queue.to_list() |> Enum.reverse(), state}

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{subs: %{}, events: :queue.new(), count: 0}}

  def handle_call({:emit, event}, _from, state) do
    {deliveries, state} =
      Enum.map_reduce(state.subs, state, fn {name, ep}, st ->
        case ep do
          {:pid, pid} ->
            send(pid, {:appconfig_kv_event, name, event})
            {{:ok, name, :pid, event["id"]}, st}

          {:url, _url} ->
            # Typed-down honest cell: the substrate has zero outbound dial
            # (air-gap law); the loopback HTTP POST variant is
            # UNSUPPORTED-by-airgap. Recorded, never silently dropped.
            {outcome(st, event), st}
        end
      end)

    state = record(state, event)
    {:reply, deliveries, state}
  end

  defp outcome(_st, _event), do: {:error, {:unsupported, :http_delivery_airgap}}

  defp record(%{events: q, count: c} = state, event) do
    q = :queue.in(event, q)
    {q, c} = if c >= @max_events, do: {elem(:queue.out(q), 1), c}, else: {q, c + 1}
    %{state | events: q, count: c}
  end

  defp envelope(key, label, etag, change) do
    %{
      "id" => "accfg-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)),
      "topic" => "/subscriptions/smalt/resourceGroups/smalt/providers/Microsoft.AppConfiguration/configurationStores/smalt",
      "subject" => "AppConfiguration.KeyValue:" <> key <> ":" <> label,
      "eventType" => if(change == :modified, do: @modified, else: @deleted),
      "eventTime" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "data" => %{
        "key" => key,
        "label" => label,
        "etag" => etag,
        "syncToken" => nil
      },
      "dataVersion" => "1.0"
    }
  end

  defp loopback?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) ->
        MapSet.member?(@loopback_hosts, String.downcase(host))

      _ ->
        false
    end
  end

end
