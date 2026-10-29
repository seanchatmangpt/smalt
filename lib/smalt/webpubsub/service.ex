defmodule Smalt.WebPubSub do
  @moduledoc """
  Web PubSub face (AZ-5): the cloud-side broker model over the landed
  domain-blind WS relay substrate. Real Azure Web PubSub decouples the
  client WebSocket from the service edge with a broker: clients
  authenticate with client-access JWTs carrying `webpubsub.role`
  permissions, join groups, and the service pushes (server-initiated
  REST send) raw payloads to every group member -- the gap the workspace
  transport law (smaltFetch-only, `fetch` cannot do WebSockets) left
  TYPED-PERMANENT in BK-58.

  Server-side face: group registry + server push + CloudEvents webhook
  emission. Client protocol: `Smalt.WebPubSub.Socket`. Tokens:
  `Smalt.WebPubSub.Token`. REST face: `Smalt.WebPubSub.Router`.

  Air-gap law: outbound CloudEvents POSTs are loopback-only (host check
  on the handler URL, fail-closed).

  `# KD-COVERS: KD-166`
  """

  use GenServer

  @name __MODULE__
  @event_buffer_cap 100

  # -- Client API ---------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: @name)

  @doc "Adds `pid` to `group` under `hub`."
  @spec join(binary, binary, pid) :: :ok
  def join(hub, group, pid), do: GenServer.call(@name, {:join, hub, group, pid})

  @doc "Removes `pid` from `group` under `hub`."
  @spec leave(binary, binary, pid) :: :ok
  def leave(hub, group, pid), do: GenServer.call(@name, {:leave, hub, group, pid})

  @doc """
  Server push: delivers raw bytes to every member of `hub/group`.
  Returns `{:ok, delivered_count}`.
  """
  @spec publish(binary, binary, binary) :: {:ok, non_neg_integer}
  def publish(hub, group, data), do: GenServer.call(@name, {:publish, hub, group, data})

  @doc "Current members of `hub/group` (live processes only)."
  @spec members(binary, binary) :: [pid]
  def members(hub, group), do: GenServer.call(@name, {:members, hub, group})

  @doc """
  Witness buffer of CloudEvents emitted by this face (connect /
  disconnected). Capped ring, last #{@event_buffer_cap}.
  """
  @spec events() :: [map]
  def events, do: GenServer.call(@name, :events)

  # -- Server -------------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{groups: %{}, events: :queue.new()}}

  @impl true
  def handle_call({:join, hub, group, pid}, _from, state) do
    groups =
      Map.update(state.groups, hub, %{group => [pid]}, fn gs ->
        Map.update(gs, group, [pid], fn ps -> if pid in ps, do: ps, else: [pid | ps] end)
      end)

    {:reply, :ok, %{state | groups: groups}}
  end

  @impl true
  def handle_call({:leave, hub, group, pid}, _from, state) do
    {:reply, :ok, drop_member(state, hub, group, pid)}
  end

  @impl true
  def handle_call({:publish, hub, group, data}, _from, state) do
    # EXPL-11 F3: the alive-filter pass has the list in hand -- prune dead
    # pids from state, never just filter at read time.
    {ps, groups} = prune_members(state.groups, hub, group)

    Enum.each(ps, fn pid -> send(pid, {:wps_push, data}) end)
    {:reply, {:ok, length(ps)}, %{state | groups: groups}}
  end

  @impl true
  def handle_call({:members, hub, group}, _from, state) do
    {ps, groups} = prune_members(state.groups, hub, group)
    {:reply, ps, %{state | groups: groups}}
  end

  @impl true
  def handle_call(:events, _from, state) do
    {:reply, :queue.to_list(state.events), state}
  end

  @impl true
  def handle_cast({:record_event, event}, state) do
    {:noreply, record_event(state, event)}
  end

  # EXPL-11 F2: the async delivery process reports the real POST outcome;
  # the witness event flips from pending to delivered/refused by id.
  # Both report shapes are accepted (4-tuple {id, delivered?, status} and
  # 3-tuple {id, {:delivered, code} | {:refused, reason} | {:no_handler, nil}}).
  @impl true
  def handle_cast({:delivery_result, event_id, {tag, code_or_reason}}, state)
      when tag in [:delivered, :refused, :no_handler] do
    {delivered?, status} =
      case tag do
        :delivered -> {true, "delivered:#{code_or_reason}"}
        :refused -> {false, "refused:#{inspect(code_or_reason)}"}
        :no_handler -> {false, "no_handler"}
      end

    handle_cast({:delivery_result, event_id, delivered?, status}, state)
  end

  @impl true
  def handle_cast({:delivery_result, event_id, delivered?, status}, state) when is_boolean(delivered?) do
    events =
      :queue.fold(
        fn ev, acc ->
          if Map.get(ev, "id") == event_id do
            :queue.in(%{ev | "delivered" => delivered?, "delivery_status" => status}, acc)
          else
            :queue.in(ev, acc)
          end
        end,
        :queue.new(),
        state.events
      )

    {:noreply, %{state | events: events}}
  end

  # -- Internals ----------------------------------------------------------------

  @doc false
  def record_event(state, event) do
    q =
      state.events
      |> then(&:queue.in(event, &1))
      |> drop_overflow()

    %{state | events: q}
  end

  defp drop_overflow(q) do
    if :queue.len(q) > @event_buffer_cap do
      drop_overflow(:queue.drop(q))
    else
      q
    end
  end

  # EXPL-11 F3: drop dead pids from `hub/group` and return {live, groups'}.
  # Empty groups/hubs are removed so churn cannot grow state unboundedly.
  defp prune_members(groups, hub, group) do
    ps =
      groups
      |> Map.get(hub, %{})
      |> Map.get(group, [])
      |> Enum.filter(&Process.alive?/1)

    gs =
      groups
      |> Map.get(hub, %{})
      |> Map.put(group, ps)
      |> Map.reject(fn {_g, ps} -> ps == [] end)

    groups2 =
      if gs == %{} do
        Map.delete(groups, hub)
      else
        Map.put(groups, hub, gs)
      end

    {ps, groups2}
  end

  defp drop_member(state, hub, group, pid) do
    gs =
      state.groups
      |> Map.get(hub, %{})
      |> Map.update(group, [], fn ps -> List.delete(ps, pid) end)
      |> Map.reject(fn {_g, ps} -> ps == [] end)

    groups =
      if gs == %{} do
        Map.delete(state.groups, hub)
      else
        Map.put(state.groups, hub, gs)
      end

    %{state | groups: groups}
  end
end
