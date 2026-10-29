defmodule Smalt.EventGrid.PushRouter do
  @moduledoc """
  Event Grid PUSH-style routing (W1 lane, v26.10.22). Reuses the KD-101
  webhook receiver (`Smalt.EventGridWebhookPlug`, mounted upstream in
  `Smalt.EgressRouter`) as the push ENTRY face, and sieves each delivered
  CloudEvents 1.0 event through a law_compiler-compiled SHACL guard per
  subscription before any delivery. KD-COVERS: KD-169 — real Event Grid
  pushes to remote webhook subscribers; the loopback air-gap bans remote
  push, so push-style routing lands IN-SUBSTRATE: matched events append as
  WAL frames (durable JSON-lines, per-subscription file) or land as real
  Service Bus queue messages (`Smalt.DataPlane.QueueStorage`), never a
  remote HTTP push.

  ## Subscription model

  `PUT/POST /eventgrid/subscriptions` body:

      %{
        "name"        => "billing-high",
        "scope"       => "/smalt/prod",
        "shape_ref"   => %{
          "shape" => "BillingShape",
          "ttl"   => "ex:BillingShape a sh:NodeShape; sh:property [...]."
        },
        "destination" => %{"type" => "wal"}
      }

  The `shape_ref.ttl` is compiled at subscribe time via
  `Smalt.POWL2.LawCompiler.compile_shape/2` — a malformed shape or an
  unknown shape IRI is a typed 400 refusal at the boundary, never a lazy
  runtime failure. The compiled guard runs on the event's `"data"` map.
  Delivery destinations: `"wal"` (durable JSON-lines append, per-subscription
  file under `:smalt, :eventgrid_push, :wal_dir`, default `tmp/eventgrid-wal`)
  or `"sb_queue"` (real `QueueStorage.put_message/4`; the queue is created
  with real `create_queue` at subscribe time, typed refusal on failure).
  Delivery errors are typed counters (`:delivery_error`), never raises across
  the seam.

  ## Matching semantics

    * scope match: segment-boundary — the source equals the scope or is a
      "/"-prefixed child of it (`/smalt/prod` matches `/smalt/prod/x` but
      never `/smalt/prod2/x`; EXPL-10 F4)
    * shape match: `guard.(event["data"] || %{}) == :ok` (conformance)
    * an event matching zero subscriptions increments the typed
      `:no_matching_subscription` counter and delivers nothing.
  """

  use GenServer

  alias Smalt.DataPlane.QueueStorage
  alias Smalt.POWL2.LawCompiler

  require Logger

  @name __MODULE__
  @max_records 1000
  @default_wal_dir Path.join(["tmp", "eventgrid-wal"])

  # -- Client API ---------------------------------------------------------------

  @doc "Starts the push router (lazy-start, QueueStore pattern)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  @doc "Ensures the router runs; returns the server pid."
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
  Creates or replaces subscription `name`. Returns `{:ok, sub}` (guard
  redacted) or a typed `{:error, {:invalid_shape, reason}}` /
  `{:error, {:invalid_scope, _}}` / `{:error, {:invalid_destination, reason}}`.
  """
  @spec put_subscription(String.t(), String.t(), map(), map()) ::
          {:ok, map()} | {:error, term()}
  def put_subscription(name, scope, shape_ref, destination)
      when is_binary(name) and is_binary(scope) and is_map(shape_ref) and is_map(destination) do
    GenServer.call(server(), {:put_subscription, name, scope, shape_ref, destination})
  end

  @doc "Deletes subscription `name`; `{:ok, name}` or `{:error, :unknown_subscription}`."
  @spec delete_subscription(String.t()) :: {:ok, String.t()} | {:error, :unknown_subscription}
  def delete_subscription(name), do: GenServer.call(server(), {:delete_subscription, name})

  @doc "Fetches one subscription (guard redacted) or `:error`."
  @spec get_subscription(String.t()) :: {:ok, map()} | :error
  def get_subscription(name), do: GenServer.call(server(), {:get_subscription, name})

  @doc "Lists subscriptions (guards redacted)."
  @spec list_subscriptions() :: [map()]
  def list_subscriptions, do: GenServer.call(server(), :list_subscriptions)

  @doc """
  Push-routing pipeline: sieves a CloudEvents batch (list of maps, or a
  single map) through every subscription. Returns
  `{:ok, %{matched: n, delivered: n, no_match_events: n}}`, or `:router_down`
  (typed no-op — the receiver face must not crash because the router is not
  started).
  """
  @spec ingest(list() | map()) ::
          {:ok,
           %{matched: non_neg_integer(), delivered: non_neg_integer(), no_match_events: non_neg_integer()}}
          | {:error, :invalid_events}
          | :router_down
  def ingest(%{"specversion" => _} = single), do: ingest([single])

  def ingest(events) when is_list(events) do
    case Process.whereis(@name) do
      nil -> :router_down
      _pid -> GenServer.call(server(), {:ingest, events})
    end
  end

  def ingest(_other), do: {:error, :invalid_events}

  @doc "Delivery records for `name` — list, oldest first."
  @spec deliveries(String.t()) :: [map()]
  def deliveries(name), do: GenServer.call(server(), {:deliveries, name})

  @doc "Typed delivery counters."
  @spec counters() :: map()
  def counters, do: GenServer.call(server(), :counters)

  @doc "Clears subscriptions, records and counters (test seam)."
  @spec reset() :: :ok
  def reset, do: GenServer.call(server(), :reset)

  # -- Server -------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{subs: %{}, records: %{}, counters: new_counters()}}

  @impl true
  def handle_call({:put_subscription, name, scope, shape_ref, destination}, _from, state) do
    case compile_subscription(name, scope, shape_ref, destination) do
      {:ok, sub} ->
        {:reply, {:ok, redact(sub)}, put_in(state.subs[name], sub)}

      {:error, _} = err ->
        {:reply, err, state}
    end
  end

  def handle_call({:delete_subscription, name}, _from, state) do
    case Map.fetch(state.subs, name) do
      {:ok, _sub} -> {:reply, {:ok, name}, %{state | subs: Map.delete(state.subs, name)}}
      :error -> {:reply, {:error, :unknown_subscription}, state}
    end
  end

  def handle_call({:get_subscription, name}, _from, state) do
    reply =
      case Map.fetch(state.subs, name) do
        {:ok, sub} -> {:ok, redact(sub)}
        :error -> :error
      end

    {:reply, reply, state}
  end

  def handle_call(:list_subscriptions, _from, state),
    do: {:reply, state.subs |> Map.values() |> Enum.map(&redact/1), state}

  def handle_call({:ingest, events}, _from, state) do
    {summary, recs, counters} =
      Enum.reduce(
        events,
        {%{matched: 0, delivered: 0, no_match_events: 0}, %{}, state.counters},
        fn ev, acc -> sieve_one(ev, state, acc) end
      )

    {:reply, {:ok, Map.take(summary, [:matched, :delivered, :no_match_events])},
     %{state | records: merge_records(state.records, recs), counters: counters}}
  end

  def handle_call({:deliveries, name}, _from, state),
    do: {:reply, state.records[name] |> List.wrap() |> Enum.reverse(), state}

  def handle_call(:counters, _from, state), do: {:reply, state.counters, state}

  def handle_call(:reset, _from, _state),
    do: {:reply, :ok, %{subs: %{}, records: %{}, counters: new_counters()}}

  # -- Subscription compilation ---------------------------------------------------

  defp compile_subscription(name, scope, shape_ref, destination) do
    with :ok <- validate_scope(scope),
         {:ok, guard} <- compile_guard(shape_ref),
         {:ok, dest} <- resolve_destination(name, destination) do
      {:ok,
       %{
         name: name,
         scope: scope,
         shape: shape_ref["shape"],
         guard: guard,
         destination: dest,
         created_at: DateTime.utc_now()
       }}
    end
  end

  defp validate_scope(scope) do
    if is_binary(scope) and scope != "" and String.starts_with?(scope, "/") do
      :ok
    else
      {:error, {:invalid_scope, "scope must be a non-empty source path starting with '/'"}}
    end
  end

  defp compile_guard(%{"shape" => shape, "ttl" => ttl}) when is_binary(shape) and is_binary(ttl) do
    case LawCompiler.compile_shape(shape, ttl) do
      {:ok, guard} -> {:ok, guard}
      {:error, {:parse_error, desc}} -> {:error, {:invalid_shape, {:parse_error, desc}}}
      {:error, {:unknown_shape, iri}} -> {:error, {:invalid_shape, {:unknown_shape, iri}}}
    end
  end

  defp compile_guard(_other),
    do: {:error, {:invalid_shape, "shape_ref must carry \"shape\" + \"ttl\" binaries"}}

  defp resolve_destination(name, %{"type" => "wal"}) do
    {:ok, %{type: :wal, file: wal_path(name)}}
  end

  defp resolve_destination(_name, %{"type" => "sb_queue", "account" => account, "queue" => queue} = dest)
       when is_binary(account) and is_binary(queue) do
    case QueueStorage.create_queue(account, queue) do
      {:ok, _status, _headers} ->
        {:ok, %{type: :sb_queue, account: account, queue: queue, ttl: dest["ttl_seconds"]}}

      {:error, status, code, msg} ->
        {:error, {:invalid_destination, {:sb_create_failed, status, code, msg}}}
    end
  end

  defp resolve_destination(_name, other),
    do: {:error, {:invalid_destination, {:unknown_destination_type, other["type"]}}}

  # -- Ingest (the sieve) ---------------------------------------------------------

  defp sieve_one(ev, state, {sum, recs, ctr}) do
    case matching_subs(ev, state.subs) do
      [] ->
        {%{sum | no_match_events: sum.no_match_events + 1}, recs, bump(ctr, :no_matching_subscription)}

      subs ->
        ctr = bump(ctr, :matched, length(subs))

        Enum.reduce(subs, {sum, recs, ctr}, fn sub, acc -> deliver_one(sub, ev, acc) end)
    end
  end

  defp matching_subs(%{"source" => source} = ev, subs) when is_binary(source) do
    subs
    |> Map.values()
    |> Enum.filter(fn sub ->
      scope_matches?(source, sub.scope) and sub.guard.(ev["data"] || %{}) == :ok
    end)
  end

  # An event without a binary "source" can never scope-match: zero delivery,
  # typed counter (fail-closed, never a crash).
  defp matching_subs(_ev, _subs), do: []

  # EXPL-10 F4: segment-boundary scope match. A bare prefix test matched
  # `/smalt/prod2/x` under scope `/smalt/prod` (over-delivery into another
  # tenant's subscription). The scope matches its own source exactly or any
  # child one "/" below it — never an arbitrary suffix.
  defp scope_matches?(source, scope), do: source == scope or String.starts_with?(source, scope <> "/")

  defp deliver_one(sub, ev, {sum, recs, ctr}) do
    now = DateTime.utc_now()
    sum = %{sum | matched: sum.matched + 1}

    case deliver(sub.destination, sub.name, ev, now) do
      :ok ->
        rec = %{
          "subscription" => sub.name,
          "event_id" => ev["id"],
          "destination" => dest_view(sub.destination),
          "delivered_at" => now
        }

        {%{sum | delivered: sum.delivered + 1}, Map.update(recs, sub.name, [rec], &[rec | &1]),
         ctr |> bump(:delivered) |> bump(frame_counter(sub.destination))}

      {:error, reason} ->
        Logger.error("eventgrid push delivery error (sub=#{sub.name}): #{inspect(reason)}")
        {sum, recs, bump(ctr, :delivery_error)}
    end
  end

  defp deliver(%{type: :wal, file: file}, sub_name, ev, now),
    do: wal_append(file, sub_name, ev, now)

  defp deliver(%{type: :sb_queue, account: account, queue: queue, ttl: ttl}, _sub_name, ev, _now) do
    body = "<QueueMessage><MessageText>" <> Base.encode64(Jason.encode!(ev)) <> "</MessageText></QueueMessage>"
    opts = %{} |> maybe_ttl(ttl)

    case QueueStorage.put_message(account, queue, body, opts) do
      {:ok, 201, _headers, _xml} -> :ok
      {:error, _, _, _} = err -> err
      {:error, :store_not_ready} = err -> err
    end
  end

  defp maybe_ttl(opts, nil), do: opts
  defp maybe_ttl(opts, s) when is_integer(s), do: Map.put(opts, "messagettl", Integer.to_string(s))

  defp frame_counter(%{type: :wal}), do: :wal_frames
  defp frame_counter(%{type: :sb_queue}), do: :sb_messages

  defp dest_view(%{type: :wal, file: file}), do: %{"type" => "wal", "file" => file}

  defp dest_view(%{type: :sb_queue, account: a, queue: q}),
    do: %{"type" => "sb_queue", "account" => a, "queue" => q}

  # -- WAL (durable append, JSON-lines) ---------------------------------------------

  defp wal_path(sub_name), do: Path.join(wal_dir(), "wal-#{sub_name}.jsonl")

  defp wal_dir do
    :smalt
    |> Application.get_env(:eventgrid_push, [])
    |> Keyword.get(:wal_dir, @default_wal_dir)
    |> Path.expand()
  end

  # Durable frame: one JSON line per delivery. Sequence numbers are derived
  # from the file (line count) at write time, so they survive router
  # restarts without router-held state.
  defp wal_append(file, sub_name, ev, now) do
    seq = wal_seq(file)
    frame = %{seq: seq, subscription: sub_name, event_id: ev["id"], event: ev, delivered_at: now}

    with :ok <- File.mkdir_p(Path.dirname(file)),
         :ok <- File.write(file, Jason.encode!(frame) <> "\n", [:append, :sync]) do
      :ok
    else
      {:error, posix} -> {:error, {:wal_write, posix}}
    end
  end

  defp wal_seq(file) do
    case File.read(file) do
      {:ok, content} -> content |> String.split("\n", trim: true) |> length()
      {:error, _} -> 0
    end
  end

  # -- bookkeeping -----------------------------------------------------------------

  defp merge_records(records, new) do
    Map.merge(records, new, fn _k, old_list, new_list ->
      (new_list ++ old_list) |> Enum.take(@max_records)
    end)
  end

  defp new_counters do
    %{
      matched: 0,
      delivered: 0,
      wal_frames: 0,
      sb_messages: 0,
      guard_reject: 0,
      no_matching_subscription: 0,
      delivery_error: 0
    }
  end

  defp bump(ctr, key), do: Map.update!(ctr, key, &(&1 + 1))
  defp bump(ctr, key, n), do: Enum.reduce(1..n, ctr, fn _, c -> bump(c, key) end)

  defp redact(sub), do: Map.drop(sub, [:guard])
end

defmodule Smalt.EventGrid.PushRouterPlug do
  @moduledoc """
  Zero-auth subscription-management face for `Smalt.EventGrid.PushRouter`,
  mounted in `Smalt.EgressRouter` directly after `Smalt.EventGridWebhookPlug`
  (same /eventgrid zero-auth path class, before `Smalt.Auth.Bearer`). Routes:

    * `PUT` / `POST /eventgrid/subscriptions` — create/replace; 201 with the
      stored subscription; typed 400 (`InvalidScope` / `InvalidShape` /
      `InvalidDestination`) on refusal.
    * `GET /eventgrid/subscriptions` — list (guards redacted).
    * `GET /eventgrid/subscriptions/:name` — one subscription or typed 404.
    * `GET /eventgrid/subscriptions/:name/deliveries` — delivery records.
    * `DELETE /eventgrid/subscriptions/:name` — 200 `{deleted: name}` or
      typed 404. Deletion STOPS delivery (the sieve skips missing subs).
  """

  @behaviour Plug

  alias Smalt.EventGrid.PushRouter

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["eventgrid", "subscriptions" | rest]} = conn, _opts) do
    route(conn, conn.method, rest)
  end

  def call(conn, _opts), do: conn

  defp route(conn, m, []) when m in ["PUT", "POST"] do
    with {:ok, body, conn} <- read_body(conn),
         {:ok, params} <- decode(body),
         :ok <- validate_params(params) do
      case PushRouter.put_subscription(
             params["name"],
             params["scope"],
             params["shape_ref"] || %{},
             params["destination"] || %{}
           ) do
        {:ok, sub} ->
          json(conn, 201, sub)

        {:error, {:invalid_scope, _}} ->
          json(conn, 400, %{"error" => %{"code" => "InvalidScope"}})

        {:error, {:invalid_shape, reason}} ->
          json(conn, 400, %{"error" => %{"code" => "InvalidShape", "reason" => inspect(reason)}})

        {:error, {:invalid_destination, reason}} ->
          json(conn, 400, %{"error" => %{"code" => "InvalidDestination", "reason" => inspect(reason)}})
      end
    else
      {:error, :bad_json} -> json(conn, 400, %{"error" => %{"code" => "InvalidJsonBody"}})
      {:error, :too_large} -> json(conn, 413, %{"error" => %{"code" => "BodyTooLarge"}})
      {:error, code} when is_binary(code) -> json(conn, 400, %{"error" => %{"code" => code}})
    end
  end

  defp route(conn, "GET", []) do
    json(conn, 200, %{"subscriptions" => PushRouter.list_subscriptions()})
  end

  defp route(conn, "GET", [name]) do
    case PushRouter.get_subscription(name) do
      {:ok, sub} -> json(conn, 200, sub)
      :error -> json(conn, 404, %{"error" => %{"code" => "SubscriptionNotFound", "target" => name}})
    end
  end

  defp route(conn, "GET", [name, "deliveries"]) do
    case PushRouter.get_subscription(name) do
      {:ok, _sub} -> json(conn, 200, %{"deliveries" => PushRouter.deliveries(name)})
      :error -> json(conn, 404, %{"error" => %{"code" => "SubscriptionNotFound", "target" => name}})
    end
  end

  defp route(conn, "DELETE", [name]) do
    case PushRouter.delete_subscription(name) do
      {:ok, name} -> json(conn, 200, %{"deleted" => name})
      {:error, :unknown_subscription} ->
        json(conn, 404, %{"error" => %{"code" => "SubscriptionNotFound", "target" => name}})
    end
  end

  defp route(conn, _m, _rest), do: json(conn, 405, %{"error" => %{"code" => "MethodNotAllowed"}})

  # EXPL-10 F10: validate params BEFORE dispatch — a nil `name`/`scope` or a
  # non-integer `destination.ttl_seconds` previously hit the `put_subscription`
  # guard / `maybe_ttl/2` clause head as a FunctionClauseError inside the
  # server (untyped 500). Typed 400s instead, in the same error-envelope
  # idiom as the router's own refusals.
  defp validate_params(params) when is_map(params) do
    name = params["name"]
    scope = params["scope"]
    ttl = get_in(params, ["destination", "ttl_seconds"])

    cond do
      not is_binary(name) or name == "" -> {:error, "InvalidSubscriptionName"}
      not is_binary(scope) -> {:error, "InvalidScope"}
      ttl != nil and not is_integer(ttl) -> {:error, "InvalidDestination"}
      true -> :ok
    end
  end

  defp read_body(conn, acc \\ "") do
    case Plug.Conn.read_body(conn) do
      {:ok, chunk, conn} ->
        acc = acc <> chunk

        if byte_size(acc) > 4 * 1024 * 1024 do
          {:error, :too_large}
        else
          {:ok, acc, conn}
        end

      {:more, chunk, conn} ->
        read_body(conn, acc <> chunk)

      {:error, _} ->
        {:error, :bad_json}
    end
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{} = params} -> {:ok, params}
      {:error, _} -> {:error, :bad_json}
    end
  end

  defp json(conn, status, body),
    do:
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
end
