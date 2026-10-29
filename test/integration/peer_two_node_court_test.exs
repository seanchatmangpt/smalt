Code.require_file("poll_helper.exs", Path.join(__DIR__, "../internal"))

defmodule Smalt.Integration.PeerTwoNodeCourtTest do
  alias SmaltTest.Internal.Poll

  @moduledoc """
  AR-OBS-04 peer testbed court (OTP-29, :peer + :erpc).

  Two ephemeral BEAM nodes over loopback distribution: the ExUnit runner is
  the local node; a remote node is started with `:peer.start_link/1` —
  linked to the runner, so lifecycle is deterministic (immediate kill on
  runner halt). The remote boots a minimal Smalt faces subset:
  `Smalt.Store` (ETS store) + a minimal health GenServer (`PeerCourt.Health`,
  defined here in the court, shipped to the remote as beam binaries via
  `:code.load_binary/3` — court-side, never faked in lib/).

  Legs:
    (a) faces boot + bidirectional :erpc round-trip latency (µs, informational);
    (b) injected disconnect: remote node stopped mid-call → the local caller
        receives a typed `{:error, {:node_down, node}}`, not a hang;
    (c) deterministic teardown: `:peer.stop(pid)` kills the remote, the epmd
        name is deregistered (named-port free), re-stop exits typed `:noproc`
        immediately (no hang);
    (d) partition simulation leg via standard distribution control
        (`:erlang.disconnect_node/1` — opaque, monitor-based, no firewall).

  No sleeps as coordination: every wait is a bounded poll on a real
  observable with a deadline. The only `Process.sleep` lives inside the
  audited poll implementation (`poll_until/3`) as a POLL-STEP.

  Runs only when the runner node is distributed
  (`elixir --name court@127.0.0.1 --cookie smalt_peer_court -S mix test ...`);
  otherwise the skip is loud on stderr, never a fake pass.
  """

  use ExUnit.Case, async: false

  @node_name :peer_court_a
  @full_name :"peer_court_a@127.0.0.1"
  @cookie ~c"smalt_peer_court"
  @poll_timeout 15_000

  # ---------------------------------------------------------------------------
  # Court-side helper faces — compiled here, shipped to the peer as beams.
  # ---------------------------------------------------------------------------

  helper_src = ~S"""
  defmodule Smalt.Integration.PeerCourt do
    @moduledoc "Court-side helper faces shipped to the peer node as beam binaries."

    def boot_faces do
      # Faces must outlive the transient erpc worker that boots them: a
      # start_link straight from the worker would take them down when the
      # worker exits after replying. Boot under a registered long-lived
      # owner process instead (deterministic handshake, no sleep).
      case Process.whereis(:peer_court_faces_owner) do
        nil ->
          parent = self()

          spawn(fn ->
            Process.register(self(), :peer_court_faces_owner)
            send(parent, :owner_up)

            {:ok, _} = Smalt.Store.start_link([])
            {:ok, _} = GenServer.start_link(__MODULE__.Health, :ok, name: __MODULE__.Health)
            send(parent, :faces_up)

            receive do
              after :infinity -> :ok
            end
          end)

          receive do
            :owner_up -> :ok
          end

          receive do
            :faces_up -> :ok
          end

          :ok

        _pid ->
          :ok
      end
    end

    defmodule Health do
      @moduledoc "Minimal health GenServer face (court-side, AR-OBS-04)."
      use GenServer

      def init(_), do: {:ok, %{calls: 0}}

      def handle_call(:health, _from, st),
        do: {:reply, {:ok, %{status: :ready, node: node(), calls: st.calls + 1}},
             %{st | calls: st.calls + 1}}

      # `:hold_open` never replies: the caller's call stays in flight until
      # the node dies. The server itself stays responsive (noreply), so the
      # entry IS observable: `:health` reports the incremented call counter.
      def handle_call(:hold_open, _from, st), do: {:noreply, %{st | calls: st.calls + 1}}
    end
  end
  """

  @helpers Map.new(Code.compile_string(helper_src))

  # ---------------------------------------------------------------------------
  # Lifecycle helpers
  # ---------------------------------------------------------------------------

  # Bounded poll on a real observable. The only sleep in this file.
  # SLEEP-CLASS: POLL-STEP
  defp poll_until(fun, deadline, desc) do
    now = :erlang.monotonic_time(:millisecond)

    if now >= deadline do
      raise "peer court poll deadline exceeded waiting for " <> desc
    end

    case fun.() do
      true ->
        :ok

      _ ->
        Process.sleep(5)
        poll_until(fun, deadline, desc)
    end
  end

  # BK-POL: `:peer.start_link/1` returned `{:error, :not_alive}` under batch
  # load (bknsp-ensure-loaded residue: 2/3 loaded runs failed at the start
  # line) — the one-shot start races epmd registration / remote boot exactly
  # when the machine is loaded. Bounded poll-retry on the real observable
  # (peer actually up + faces answering), via the one audited Poll
  # implementation; a partial start (faces not yet loadable) stops the peer
  # so the retry starts from a clean epmd name.
  defp start_remote do
    args =
      Enum.flat_map(:code.get_path(), fn p -> [~c"-pa", p] end) ++ [~c"-setcookie", @cookie]

    case Poll.eventually(fn -> try_start_remote(args) end,
           timeout_ms: @poll_timeout,
           poll_ms: 100
         ) do
      {:ok, {pid, node}} -> {:ok, pid, node}
      {:timeout, last} -> raise "peer court: remote start never converged: #{inspect(last)}"
    end
  end

  defp try_start_remote(args) do
    with {:ok, pid, node} <- peer_start_link(args) do
      # ship court-side helper beams (PeerCourt + nested Health). A load race
      # here surfaces as an erpc raise — Poll retries it, but the half-booted
      # peer must die first or the retry collides with the epmd name.
      for {mod, beam} <- @helpers do
        :module = elem(:erpc.call(node, :code, :load_binary, [mod, ~c"", beam]), 0)
      end

      case :erpc.call(node, Smalt.Integration.PeerCourt, :boot_faces, []) do
        :ok ->
          {:ok, {pid, node}}

        other ->
          :peer.stop(pid)
          {:error, {:boot_faces, other}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  # `:peer.start_it/2` EXITs `time out` (rather than returning
  # `{:error, :not_alive}`) when the remote is slow to answer — the exact
  # load-dependent shape BK-POL repairs. Normalize the exit so the audited
  # Poll (which rescues raises but not exits) can retry it.
  defp peer_start_link(args) do
    try do
      :peer.start_link(%{
        name: @node_name,
        host: ~c"127.0.0.1",
        longnames: true,
        args: args
      })
    catch
      :exit, reason -> {:error, {:start_exit, reason}}
    end
  end

  defp c_health(node), do: {Smalt.Integration.PeerCourt.Health, node}

  defp health_call(node) do
    :erpc.call(node, GenServer, :call, [c_health(node), :health, @poll_timeout])
  end

  defp reverse_store_read(node, key) do
    # reverse direction: the REMOTE calls the RUNNER's Smalt.Store (the runner
    # boots the full :smalt app under `mix test`, so the store face is up on
    # both sides) and reads a row the runner wrote locally.
    :erpc.call(node, :erpc, :call, [
      node(),
      Smalt.Store,
      :get,
      [:smalt_subscriptions, key]
    ])
  end

  defp call_typed_health(node) do
    call_typed(node, GenServer, :call, [
      {Smalt.Integration.PeerCourt.Health, node},
      :health,
      @poll_timeout
    ])
  end

  # Typed face for a cross-node call that must not hang: normalizes the erpc
  # exit signal into the court's typed `{:error, {:node_down, node}}`.
  defp call_typed(node, mod, fun, args) do
    try do
      {:ok, :erpc.call(node, mod, fun, args, @poll_timeout)}
    rescue
      e in ErlangError ->
        case e do
          %ErlangError{original: {:erpc, :noconnection}} -> {:error, {:node_down, node}}
          %ErlangError{original: {:erpc, reason}} -> {:error, {:erpc, reason}}
          other -> raise "peer court: unexpected erpc failure: #{inspect(other)}"
        end
    catch
      :exit, {:erpc, :noconnection} -> {:error, {:node_down, node}}
      :exit, {:erpc, reason} -> {:error, reason}
    end
  end

  defp avg_latency_us(fun, n) do
    t0 = :erlang.monotonic_time()

    for _ <- 1..n, do: fun.()

    t1 = :erlang.monotonic_time()
    div(System.convert_time_unit(t1 - t0, :native, :microsecond), n)
  end

  defp catch_exit_do(fun) do
    try do
      fun.()
      :no_exit
    rescue
      e -> {:raised, e.message}
    catch
      :exit, reason -> reason
    end
  end

  defp epmd_name_free? do
    case :net_adm.names() do
      {:ok, names} -> not List.keymember?(names, @node_name, 0)
      {:error, :address} -> true
    end
  end

  # ---------------------------------------------------------------------------
  # Setup / teardown
  # ---------------------------------------------------------------------------

  # BK-PATW conversion: the loud-skip is typed, not batch-killing. When the
  # runner is not distributed, the :peer_two_node_court tag is excluded at
  # module-load time (loud stderr line) so a batched
  # `mix test test/integration` skips the court instead of invalidating 4
  # tests. The court itself is unchanged: with a distributed runner (or
  # --include peer_two_node_court), all 4 legs run verbatim.
  if node() == :nonode@nohost do
    IO.puts(:stderr, """
    [peer-court] SKIP (loud): runner node is not distributed.
    Run with: elixir --name court@127.0.0.1 --cookie smalt_peer_court \
    -S mix test test/integration/peer_two_node_court_test.exs --include peer_two_node_court
    """)
  end

  setup _ctx do
    {:ok, pid, node} = start_remote()

    on_exit(fn ->
      try do
        :peer.stop(pid)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end)

    [remote: node, remote_pid: pid]
  end

  # ---------------------------------------------------------------------------
  # Legs
  # ---------------------------------------------------------------------------

  @tag :peer_two_node_court
  test "(a) faces boot + bidirectional erpc round-trip latency (informational)", ctx do
    node = ctx.remote
    deadline = :erlang.monotonic_time(:millisecond) + @poll_timeout

    # health face observable cross-node
    {:ok, %{status: :ready, node: ^node}} = health_call(node)

    # runner-side write: the reverse leg reads THIS row from the remote
    :ok = Smalt.Store.put(:smalt_subscriptions, "court-key-a", %{v: 1})

    # store face observable cross-node: put on remote, then poll-read back
    :ok = :erpc.call(node, Smalt.Store, :put, [:smalt_subscriptions, "court-key-a", %{v: 1}])

    poll_until(
      fn ->
        match?(
          {:ok, %{v: 1}},
          :erpc.call(node, Smalt.Store, :get, [:smalt_subscriptions, "court-key-a"])
        )
      end,
      deadline,
      "store face readable cross-node"
    )

    # (a) bidirectional round-trip latency, µs, informational
    fwd =
      avg_latency_us(
        fn -> match?({:ok, _}, health_call(node)) end,
        100
      )

    rev = avg_latency_us(fn -> {:ok, _} = reverse_store_read(node, "court-key-a") end, 100)

    IO.puts("""
        [peer-court] faces subset UP on #{node} (Smalt.Store + PeerCourt.Health)
        [peer-court] forward erpc round-trip: #{fwd} µs/op avg (n=100)
        [peer-court] reverse erpc round-trip: #{rev} µs/op avg (n=100)
    """)

    assert is_integer(fwd) and fwd >= 0
    assert is_integer(rev) and rev >= 0
  end

  @tag :peer_two_node_court
  test "(b) injected disconnect: remote stopped mid-call yields typed node_down, not a hang",
       ctx do
    node = ctx.remote
    parent = self()

    # local caller blocks in a cross-node GenServer call to the never-replying
    # :hold_open handle_call (server stays responsive via noreply)
    spawn(fn ->
      res = call_typed(node, GenServer, :call, [c_health(node), :hold_open, @poll_timeout])
      send(parent, {:caller_done, res})
    end)

    # observe the call ENTERED the remote face structurally: the health
    # GenServer stayed responsive (noreply) and its call counter advanced
    # past the leg-(a)-independent baseline (>= 2: this health poll + hold_open).
    deadline = :erlang.monotonic_time(:millisecond) + @poll_timeout

    poll_until(
      fn ->
        match?({:ok, %{calls: calls}} when calls >= 2, health_call(node))
      end,
      deadline,
      "hold_open entry observable on remote face"
    )

    # stop the remote node while the call is in flight
    :ok = :peer.stop(ctx.remote_pid)

    receive do
      {:caller_done, res} ->
        assert res == {:error, {:node_down, node}},
               "expected typed node_down, got: #{inspect(res)}"

        IO.puts("    [peer-court] injected disconnect -> typed #{inspect(res)}")
    after
      5_000 -> raise "peer court FAIL: local caller hung after remote node stop"
    end
  end

  @tag :peer_two_node_court
  test "(c) teardown: peer.stop kills the remote; epmd name deregistered (named-port free)",
       ctx do
    pid = ctx.remote_pid
    :ok = :peer.stop(pid)
    deadline = :erlang.monotonic_time(:millisecond) + @poll_timeout

    poll_until(
      fn ->
        @full_name not in :erlang.nodes() and :net_adm.ping(@full_name) == :pang and
          epmd_name_free?()
      end,
      deadline,
      "remote node dead + epmd name deregistered"
    )

    # re-stop of the dead controller exits typed :noproc immediately (no hang)
    assert :noproc == catch_exit_do(fn -> :peer.stop(pid) end)

    IO.puts(
      "    [peer-court] teardown: node dead, epmd name free, re-stop of dead controller -> :noproc (typed, no hang)"
    )
  end

  @tag :peer_two_node_court
  test "(d) partition simulation: disconnect_node tears the link, monitor sees node_down, reconnect restores",
       ctx do
    node = ctx.remote
    deadline = :erlang.monotonic_time(:millisecond) + @poll_timeout

    # link is up: health face answers
    {:ok, _} = health_call(node)

    # opaque, monitor-based partition via standard distribution control
    # (no firewall): force disconnect, observe via node monitor. Peer
    # lifecycle note: a :peer child is connection-bound — losing the
    # distribution link halts it — so "reconnect" here means distribution
    # recovers by booting a fresh peer under the same node name.
    :erlang.monitor_node(node, true)
    true = :erlang.disconnect_node(node)

    received =
      receive do
        {:nodedown, ^node} -> :observed
      after
        5_000 -> :timeout
      end

    assert received == :observed, "monitor did not report nodedown after disconnect_node"

    # while partitioned: erpc fails typed, and does not hang
    assert {:error, {:node_down, ^node}} = call_typed_health(node)

    # the connection-bound child is gone from epmd (named-port free)
    poll_until(fn -> epmd_name_free?() end, deadline, "epmd name free after disconnect")

    # distribution recovery: fresh peer under the same name answers again
    {:ok, pid2, node2} = start_remote()
    assert node2 == node

    poll_until(
      fn -> match?({:ok, _}, call_typed_health(node2)) end,
      deadline,
      "fresh-peer recovery after partition"
    )

    :ok = :peer.stop(pid2)
  end
end
