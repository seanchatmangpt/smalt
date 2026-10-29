defmodule Smalt.Cluster do
  @moduledoc """
  Native DNS-based cluster interconnect (stdlib-only; no libcluster).

  Config-gated, default OFF — a solo boot never starts the poller and the
  boot path is byte-identical with `enabled: false` (the default).

      config :smalt, :cluster,
        enabled: false,          # default false
        dns_name: nil,           # headless-service FQDN whose A records to poll
        port: 0,                 # informational: expected remote dist port
        poll_ms: 5000,           # DNS poll interval
        node_prefix: "smalt",    # remote node name = `:"\#{prefix}@{ip}"`
        max_retries: 3           # bounded reconnect budget per address

  Each poll resolves `dns_name` to A records (`:inet_res.resolve/3` first,
  falling back to `:inet.gethostbyname/2` for /etc/hosts-style names), then
  attempts `Node.connect/1` to `:"\#{prefix}@{ip}"` for every address that is
  not yet connected and has not exhausted its reconnect budget. An address
  that burns its budget is dropped from attempts until DNS stops listing it;
  the address set changing resets budgets — re-resolution is the retry, not
  a clock (no sleeps; the poll interval is runtime scheduling via
  Process.send_after, `# SLEEP-CLASS: SCHEDULING` semantics).

  Readiness is surfaced via `cluster_status/0` (module API only; HTTP
  endpoint wiring belongs to the adaptive-probe lane).
  """

  use GenServer

  @poll_msg :cluster_poll
  @poll_done_msg :cluster_poll_done

  ## Public API

  @doc "Starts the poller. Requires enabled: true and a dns_name; raises otherwise."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Cluster readiness snapshot:

      %{
        enabled: boolean(),
        self: node(),
        nodes: [node()],      # connected members
        joined: count,        # |nodes|
        dns_name: binary(),
        port: integer(),
        exhausted: [address()],
        last_error: term() | nil
      }
  """
  @spec cluster_status() :: map()
  def cluster_status do
    GenServer.call(__MODULE__, :status)
  catch
    :exit, {:noproc, _} -> not_running()
    :exit, {:normal, _} -> not_running()
    :exit, {:shutdown, _} -> not_running()
  end

  defp not_running do
    %{
      enabled: false,
      self: node(),
      nodes: [],
      joined: 0,
      dns_name: nil,
      port: 0,
      exhausted: [],
      last_error: :not_started
    }
  end

  @doc "Forces an immediate poll (test/witness hook)."
  @spec poll_now() :: :ok
  def poll_now do
    GenServer.cast(__MODULE__, @poll_msg)
  end

  ## Callbacks

  @impl true
  def init(opts) do
    cfg = resolve_cfg(opts)

    unless cfg.enabled do
      raise ArgumentError,
            "Smalt.Cluster started while disabled — start it only under " <>
              "config :smalt, :cluster, enabled: true (solo boots stay byte-identical: nothing starts by default)"
    end

    unless is_binary(cfg.dns_name) and cfg.dns_name != "" do
      raise ArgumentError, "Smalt.Cluster requires config :smalt, :cluster, dns_name: <fqdn>"
    end

    Process.send_after(self(), @poll_msg, 0)
    {:ok, %{cfg: cfg, attempts: %{}, last_error: nil, in_flight: false}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_map(state), state}
  end

  @impl true
  def handle_cast(@poll_msg, state) do
    {:noreply, maybe_spawn_poll(state)}
  end

  @impl true
  def handle_info(@poll_msg, state) do
    {:noreply, maybe_spawn_poll(state)}
  end

  @impl true
  def handle_info({@poll_done_msg, attempts, last_error}, state) do
    # Worker result: fold the fresh attempt budget back into the state.
    {:noreply, %{state | attempts: attempts, last_error: last_error, in_flight: false}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    # The worker crashed: the budget snapshot is lost, the next poll simply
    # retries with a clean budget (crash-first; the poller is restartable by
    # construction — attempts are advisory, not authoritative).
    {:noreply, %{state | in_flight: false}}
  end

  @impl true
  def handle_info(_other, state), do: {:noreply, state}

  ## Internals

  defp resolve_cfg(opts) do
    base = Application.get_env(:smalt, :cluster, [])
    keys = [:enabled, :dns_name, :port, :poll_ms, :node_prefix, :max_retries]
    merged = Keyword.merge(base, opts)

    Map.new(keys, fn k ->
      {k, Keyword.get(merged, k, default_for(k))}
    end)
  end

  defp default_for(:enabled), do: false
  defp default_for(:dns_name), do: nil
  defp default_for(:port), do: 0
  defp default_for(:poll_ms), do: 5_000
  defp default_for(:node_prefix), do: "smalt"
  defp default_for(:max_retries), do: 3

  defp status_map(state) do
    members = Node.list(:connected)

    %{
      enabled: state.cfg.enabled,
      self: node(),
      nodes: members,
      joined: length(members),
      dns_name: state.cfg.dns_name,
      port: state.cfg.port,
      exhausted: Map.keys(state.attempts),
      last_error: state.last_error
    }
  end

  # Spawn the blocking poll (DNS resolve + Node.connect) off the server
  # process: Node.connect can block for net_ticktime on an unreachable
  # host, and the server must keep answering cluster_status/0 (the
  # readiness face) while a connect is in flight. Armstrong: the error
  # kernel (this server) never performs the blocking work itself.
  defp maybe_spawn_poll(%{in_flight: true} = state), do: state

  defp maybe_spawn_poll(state) do
    %{cfg: cfg, attempts: attempts, last_error: last_error} = state
    parent = self()

    {:ok, pid} =
      Task.start(fn ->
        {attempts, last_error} = run_poll(cfg, attempts, last_error)
        schedule_next(parent, cfg.poll_ms)
        send(parent, {@poll_done_msg, attempts, last_error})
      end)

    Process.monitor(pid)
    %{state | in_flight: true}
  end

  defp run_poll(cfg, attempts, prev_last_error) do
    {addrs, dns_error} = resolve(cfg.dns_name)

    {attempts, connect_last_error} =
      Enum.reduce(addrs, {attempts, nil}, fn addr, {att, err} ->
        target = target_node(cfg.node_prefix, addr)

        cond do
          target in Node.list(:connected) ->
            # healthy member: clear its budget
            {Map.delete(att, addr), err}

          Map.get(att, addr, 0) >= cfg.max_retries ->
            # budget exhausted for this address until DNS stops listing it
            {att, err}

          true ->
            case Node.connect(target) do
              true -> {Map.delete(att, addr), err}
              false -> {Map.put(att, addr, Map.get(att, addr, 0) + 1), {:connect_failed, target}}
              :ignored -> {Map.put(att, addr, Map.get(att, addr, 0) + 1), {:connect_ignored, target}}
            end
        end
      end)

    # drop budgets for addresses that left the DNS answer set (reset on reappear)
    addr_set = MapSet.new(addrs)

    attempts =
      attempts |> Enum.filter(fn {a, _} -> MapSet.member?(addr_set, a) end) |> Map.new()

    last_error =
      case dns_error do
        nil -> connect_last_error || prev_last_error
        err -> err
      end

    {attempts, last_error}
  end

  defp target_node(prefix, addr) do
    ip = :inet.ntoa(addr) |> List.to_string()
    String.to_atom("#{prefix}@#{ip}")
  end

  defp resolve(name) do
    # :inet.gethostbyname consults the BEAM resolver (DNS via /etc/resolv.conf)
    # with hosts-table fallback — covers headless-service FQDNs and "localhost".
    case :inet.gethostbyname(String.to_charlist(name), :inet, :infinity) do
      {:ok, {:hostent, _name, _aliases, _af, _len, addrs}} -> {addrs, nil}
      {:error, reason} -> {[], {:dns_failure, name, reason}}
    end
  end

  defp schedule_next(parent, poll_ms) do
    Process.send_after(parent, @poll_msg, poll_ms)
  end
end
