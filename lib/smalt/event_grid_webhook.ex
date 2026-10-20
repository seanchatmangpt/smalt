defmodule Smalt.EventGridWebhook do
  @moduledoc """
  Event Grid webhook RECEIVER surface (KD-101 loopback parity face, AZB lane
  C3, v26.10.19).

  Real Event Grid PUSHES CloudEvents 1.0 to subscriber webhooks. smalt is
  loopback-only under the air-gap law — outbound push-to-remote is banned —
  so the Azure-parity shape inside those constraints is the RECEIVER face:
  the substrate exposes the webhook delivery endpoint class Event Grid would
  call, honors the validation handshake headers Event Grid sends, delivers
  CloudEvents POST-bodies into registered in-process subscribers, and records
  every accepted event for pull. The remaining divergence is honest:
  push-to-remote-subscriber, which the air-gap law forbids.

  ## Wire contract

    * `POST /eventgrid/hooks/:subscriber` — delivery/validation endpoint.
    * Validation handshake 1 (CORS-style): any request carrying
      `WebHook-Request-Origin` is answered `200` with
      `WebHook-Allowed-Origin: <origin>` + `WebHook-Allowed-Rate: <rate|1M>`
      — the Event Grid handshake response — WITHOUT consuming a delivery.
    * Validation handshake 2 (inline): a CloudEvent of type
      `Microsoft.EventGrid.SubscriptionValidationEvent` (single or in batch)
      is answered `200 {"validationResponse": "<code>"}` and NOT delivered.
    * Delivery: a CloudEvents 1.0 body (single object or batch array) is
      validated (mandatory `specversion`/`id`/`source`/`type`), delivered to
      the registered subscriber as
      `{:event_grid_webhook, subscriber, id, event}` and recorded for pull
      via `delivered/1`. Delivery-attempt headers (`aeg-event-type`,
      `aeg-subscription-name`, `aeg-data-version`, `aeg-delivery-count`) are
      recorded as metadata.
    * `WebHook-Event-Handler-Version` request header is honored: recorded
      with the delivery record and echoed as `WebHook-Event-Handler-Version`
      on the response.

  Zero-auth `/eventgrid` path class (subscriber endpoints are registered
  loopback faces, not ARM surfaces). This plug is mountable but NOT mounted
  by this lane — see the mount-point handoff in the lane receipt.
  """

  use GenServer

  @name __MODULE__
  @max_records 1000
  @validation_event_type "Microsoft.EventGrid.SubscriptionValidationEvent"

  # -- Client API ---------------------------------------------------------------

  @doc "Starts the receiver registry (lazy-start, QueueStore pattern)."
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
  Registers `name` (default pid: self()) as an in-proc webhook subscriber.
  Re-registration replaces the pid (recovery, EventGrid pattern).
  """
  @spec register(term(), pid() | nil) :: :ok
  def register(name, pid \\ nil) do
    pid = pid || self()
    GenServer.call(server(), {:register, name, pid})
  end

  @doc "Unregisters `name`."
  @spec unregister(term()) :: :ok
  def unregister(name), do: GenServer.call(server(), {:unregister, name})

  @doc """
  Pull API: returns the delivery records for `name` —
  `%{id => %{"event" => event, "meta" => meta, "delivered_at" => ts}}` —
  oldest first.
  """
  @spec delivered(term()) :: %{optional(term()) => map()}
  def delivered(name), do: GenServer.call(server(), {:delivered, name})

  @doc "Returns true when `id` was delivered to subscriber `name`."
  @spec delivered?(term(), term()) :: boolean()
  def delivered?(name, id), do: Map.has_key?(delivered(name), id)

  @doc "Clears registry + delivery log (test seam)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(server(), :reset)

  # -- Server -------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{subscribers: %{}, records: %{}}}

  @impl true
  def handle_call({:register, name, pid}, _from, state) do
    {:reply, :ok, put_in(state.subscribers[name], pid)}
  end

  def handle_call({:unregister, name}, _from, state) do
    {:reply, :ok, %{state | subscribers: Map.delete(state.subscribers, name)}}
  end

  def handle_call({:delivered, name}, _from, state) do
    {:reply, Map.get(state.records, name, %{}), state}
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, %{subscribers: %{}, records: %{}}}

  def handle_call({:registered?, name}, _from, state),
    do: {:reply, Map.has_key?(state.subscribers, name), state}

  def handle_call({:pid_for, name}, _from, state),
    do: {:reply, state.subscribers[name], state}

  def handle_call({:record, name, id, ev, meta, now}, _from, state) do
    recs = Map.get(state.records, name, %{})

    rec =
      recs
      |> Map.put(id, %{"event" => ev, "meta" => meta, "delivered_at" => now})
      |> cap_ring(@max_records)

    {:reply, :ok, put_in(state.records[name], rec)}
  end

  # -- Delivery core (called from the plug process) --------------------------------

  @doc """
  Validates a decoded CloudEvents body (single map or batch list) against the
  CloudEvents 1.0 mandatory attribute set. Returns `:ok` or
  `{:error, reason}` with a typed reason.
  """
  @spec validate_events(term()) :: :ok | {:error, term()}
  def validate_events(%{"specversion" => _} = single), do: validate_events([single])

  def validate_events(events) when is_list(events) do
    if events == [] do
      {:error, :empty_batch}
    else
      events
      |> Enum.reduce_while(:ok, fn ev, :ok ->
        case validate_one(ev) do
          :ok -> {:cont, :ok}
          {:error, _} = err -> {:halt, err}
        end
      end)
    end
  end

  def validate_events(_other), do: {:error, :invalid_body_shape}

  defp validate_one(%{"specversion" => sv, "id" => id, "source" => _src, "type" => _t} = _ev)
       when is_binary(sv) and is_binary(id),
       do: :ok

  defp validate_one(%{"id" => nil}), do: {:error, {:missing_attribute, "id"}}
  defp validate_one(%{"specversion" => _}), do: {:error, {:missing_attribute, "id"}}
  defp validate_one(%{}), do: {:error, {:missing_attribute, "specversion"}}
  defp validate_one(_), do: {:error, :invalid_event_shape}

  @doc """
  Delivers a validated CloudEvents body to registered subscriber `name`.
  Returns `{:ok, :delivered, n}` (n events accepted), `{:ok, :validation, code}`
  for a SubscriptionValidationEvent batch (NOT delivered), or
  `{:error, :unknown_subscriber}`.
  """
  @spec deliver(term(), list() | map(), map()) ::
          {:ok, :delivered, non_neg_integer()}
          | {:ok, :validation, String.t()}
          | {:error, :unknown_subscriber}
  def deliver(name, events, meta \\ %{})

  def deliver(name, %{"specversion" => _} = single, meta), do: deliver(name, [single], meta)

  def deliver(name, events, meta) when is_list(events) do
    case Process.whereis(@name) && GenServer.call(server(), {:registered?, name}) do
      true ->
        case validation_events(events) do
          {true, code} ->
            {:ok, :validation, code}

          false ->
            now = DateTime.utc_now()

            Enum.each(events, fn ev ->
              record(name, ev, meta, now)
              deliver_to_pid(name, ev)
            end)

            {:ok, :delivered, length(events)}
        end

      _ ->
        {:error, :unknown_subscriber}
    end
  end

  def deliver(_name, _other, _meta), do: {:error, :invalid_body_shape}

  defp validation_events(events) do
    codes =
      for %{"type" => @validation_event_type, "data" => %{"validationCode" => code}} <-
            events,
          is_binary(code),
          do: code

    case codes do
      [code | _] -> {true, code}
      [] -> false
    end
  end

  defp record(name, ev, meta, now) do
    GenServer.call(@name, {:record, name, ev["id"], ev, meta, now})
  end

  defp deliver_to_pid(name, ev) do
    case GenServer.call(server(), {:pid_for, name}) do
      pid when is_pid(pid) -> send(pid, {:event_grid_webhook, name, ev["id"], ev})
      _ -> :ok
    end
  end

  # Keeps the newest @max_records records by dropping the oldest delivered.
  defp cap_ring(recs, max) when map_size(recs) <= max, do: recs

  defp cap_ring(recs, max) do
    {oldest_key, _} = Enum.min_by(recs, fn {_k, v} -> v["delivered_at"] end)
    recs |> Map.delete(oldest_key) |> cap_ring(max)
  end
end

defmodule Smalt.EventGridWebhookPlug do
  @moduledoc """
  Mountable plug for the `/eventgrid` webhook receiver path class
  (`Smalt.EventGridWebhook`). Match-on-prefix: mount BEFORE auth/parsers in a
  Plug.Router chain, or invoke directly via `Smalt.EventGridWebhookPlug.call/2`
  in tests / a Bandit Phoenix router piped through it.

  Routes (zero-auth by contract):
    * `WebHook-Request-Origin` on ANY path under the plug → handshake 200.
    * `POST /eventgrid/hooks/:subscriber` → validation-event response or
      CloudEvents delivery (200/202-style 200), typed 404/400 otherwise.
  """

  @behaviour Plug

  alias Smalt.EventGridWebhook

  # Cross-lane unblock fix (compile-freeze SLA, c13-router lane): the plug
  # called get_req_header/2 with no Plug.Conn import. Minimal addition only —
  # the owning lane owns the rest of this in-flight file.
  import Plug.Conn, only: [get_req_header: 2]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{} = conn, _opts) do
    case conn.path_info do
      ["eventgrid" | _rest] -> handle(conn)
      _ -> conn
    end
  end

  defp handle(%Plug.Conn{method: m} = conn) when m in ["OPTIONS", "GET"] do
    case get_req_header(conn, "webhook-request-origin") do
      [origin | _] ->
        # Handshake 1: answer the CORS-style validation without consuming a
        # delivery. Rate echo: honor the request's WebHook-Request-Rate when
        # present, else the Event Grid default "1M".
        rate = get_req_header(conn, "webhook-request-rate") |> List.first() || "1M"
        version = get_req_header(conn, "webhook-event-handler-version") |> List.first()

        conn
        |> Plug.Conn.put_resp_header("webhook-allowed-origin", origin)
        |> Plug.Conn.put_resp_header("webhook-allowed-rate", rate)
        |> maybe_put_version_header(version)
        |> Plug.Conn.send_resp(200, "")

      [] ->
        conn
    end
  end

  defp handle(%Plug.Conn{method: "POST", path_info: ["eventgrid", "hooks", subscriber]} = conn) do
    # Handshake 1 can also ride a POST (real Event Grid sends the header on
    # the validation request itself).
    if get_req_header(conn, "webhook-request-origin") != [] do
      handshake_response(conn)
    else
      delivery(conn, subscriber)
    end
  end

  defp handle(conn), do: conn

  defp delivery(conn, subscriber) do
    with {:ok, body, conn} <- read_whole_body(conn),
         {:ok, events} <- decode(body) do
      meta = delivery_meta(conn)

      case EventGridWebhook.validate_events(events) do
        :ok ->
          case EventGridWebhook.deliver(subscriber, events, meta) do
            {:ok, :validation, code} ->
              json_resp(conn, 200, %{"validationResponse" => code})

            {:ok, :delivered, _n} ->
              json_resp(conn, 200, %{"received" => true})

            {:error, :unknown_subscriber} ->
              json_resp(conn, 404, %{
                "error" => %{"code" => "UnknownSubscriber", "target" => to_string(subscriber)}
              })
          end

        {:error, reason} ->
          json_resp(conn, 400, %{"error" => %{"code" => "InvalidCloudEvent", "reason" => inspect(reason)}})
      end
    else
      {:error, :bad_json} ->
        json_resp(conn, 400, %{"error" => %{"code" => "InvalidJsonBody"}})

      {:error, :too_large} ->
        json_resp(conn, 413, %{"error" => %{"code" => "BodyTooLarge"}})
    end
  end

  defp read_whole_body(conn, acc \\ "") do
    case Plug.Conn.read_body(conn) do
      {:ok, chunk, conn} ->
        acc = acc <> chunk

        if byte_size(acc) > 4 * 1024 * 1024 do
          {:error, :too_large}
        else
          {:ok, acc, conn}
        end

      {:more, chunk, conn} ->
        read_whole_body(conn, acc <> chunk)

      {:error, _} ->
        {:error, :bad_json}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :bad_json}
    end
  end

  # Delivery-attempt headers (aeg-*) + handler version are preserved as
  # delivery-record metadata.
  defp delivery_meta(conn) do
    for header <- [
          "aeg-event-type",
          "aeg-subscription-name",
          "aeg-data-version",
          "aeg-delivery-count",
          "webhook-event-handler-version"
        ],
        [v] <- [get_req_header(conn, header)],
        do: {header, v},
        into: %{}
  end

  defp handshake_response(conn) do
    origin = get_req_header(conn, "webhook-request-origin") |> List.first() || "*"

    conn
    |> Plug.Conn.put_resp_header("webhook-allowed-origin", origin)
    |> Plug.Conn.put_resp_header("webhook-allowed-rate", "1M")
    |> Plug.Conn.send_resp(200, "")
  end

  defp maybe_put_version_header(conn, nil), do: conn
  defp maybe_put_version_header(conn, version) do
    Plug.Conn.put_resp_header(conn, "webhook-event-handler-version", version)
  end

  defp json_resp(conn, status, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
end
