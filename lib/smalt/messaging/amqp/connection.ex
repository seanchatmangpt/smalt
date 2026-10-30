defmodule Smalt.Amqp.Connection do
  @redelivery_tick_idle_ms 1_000
  @redelivery_tick_floor_ms 250
  @redelivery_tick_cap_ms 20_000

  @moduledoc """
  One AMQP 1.0 connection per accepted `:gen_tcp` socket (passive, binary) with a short-recv mailbox-servicing pump.

  T08 (v26.10.29) split: the protocol-phase logic moved verbatim into
  `Smalt.Amqp.Connection.Handshake` (header peel + SASL + open — the
  byte-pinion surface), `Smalt.Amqp.Connection.Session` (begin/flow/end),
  `Smalt.Amqp.Connection.Link` (attach/detach/credit/EH epoch), and
  `Smalt.Amqp.Connection.Delivery` (transfer ingestion, `$cbs`/`$management`
  RPC, credit-driven delivery, disposition settlement). This root stays the
  crash-only actor (temporary restart, terminate releases session locks) and
  shrinks to the input pump, delegation, and state routing.

  Wire state machine:

  1. SASL layer first — server offers `[ANONYMOUS]`, expects `sasl-init` with
     mechanism `ANONYMOUS`, replies `sasl-outcome` code 0.
  2. AMQP layer — protocol header exchange, then open (container-id
     `"smalt-local"`, max-frame-size 1048576) -> begin -> attach routing:

     | address              | handler                              |
     |----------------------|--------------------------------------|
     | `"$cbs"`             | `Smalt.Amqp.CbsRouter` (GenServer)   |
     | "$management" or "<entity>/$management" | `Smalt.Amqp.ManagementRpc.handle/2` |
     | anything else        | queue link via `Smalt.Amqp.QueueStore` |

  Sender links (client role sender) ingest transfers via `QueueStore.enqueue/3`,
  settled server-side with a `disposition` `accepted` after the store write.
  Receiver links deliver on flow credit via `QueueStore.dequeue_matching/2`
  (`delivery-tag` = lock token); payload sections come from
  `DeliveryEncoder.build_sections/1` encoded by `FrameCodec.encode_message/1`.

  Disposition settlement: `accepted` -> complete, `released` / `modified` ->
  release (re-queue), `modified` + `undeliverable-here` -> defer, `rejected` ->
  deadletter.

  Unknown/malformed frames -> close frame with error condition, socket closed.
  Attaching a queue entity without a valid CBS claim for its audience -> detach
  with `amqp:unauthorized-access` / `"UNAUTHORIZED_ENTITY"` (enforced only while
  the `Smalt.Amqp.CbsRouter` claim cache process is running; open otherwise so
  the standalone lane run does not gate on the CBS lane).
  """

  use GenServer, restart: :temporary
  require Logger

  alias Smalt.Amqp.Connection.{Delivery, Handshake, Link, Session}
  alias Smalt.Amqp.{FrameCodec, QueueStore}

  @recv_timeout 300_000
  @pre_open_timeout 5_000
  # KD-COVERS: KD-69 — short-recv mailbox-servicing pump slice width.
  @pump_wait_ms 100

  # ===========================================================================
  # API
  # ===========================================================================

  @doc "Starts a connection GenServer. Opts: `socket:` (required, accepted socket)."
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  AZB-07: broker-forced partition detach — sends the typed
  `amqp:link:detach-forced` detach for the receiver link(s) on `address`,
  keeping the connection up so the client relink is clean (real Event Hubs
  service behavior).
  """
  def force_partition_detach(conn_pid, address) when is_pid(conn_pid) do
    send(conn_pid, {:azb07_force_partition_detach, address})
    :ok
  end

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    sock = Keyword.fetch!(opts, :socket)
    mode = Keyword.get(opts, :mode, :sb)
    Process.set_label(%{service: :amqp, role: :connection, correlation_id: mode})
    :ok = :inet.setopts(sock, active: false, mode: :binary)
    send(self(), :recv)

    {:ok,
     %{
       sock: sock,
       mode: mode,
       buffer: <<>>,
       halted: false,
       recv_deadline: nil,
       peer_max_frame_size: nil,
       phase: :sasl_header,
       session: nil,
       links: %{},
       sessions: %{},
       next_delivery_id: 0,
       outbound_deliveries: %{},
       eh_cursors: %{},
       # KD-COVERS: KD-127 — next in-pump redelivery-sweep deadline (ms).
       next_redeliver_at: 0,
       # KD-COVERS: KD-134 — requester-preference memory: {queue, seq} ->
       # MapSet of {channel, handle} links that delivered the message and
       # have not settled it yet. Pruned on settlement (disposition handler).
       redelivery_holders: %{}
     }}
  end

  # -- KD-127 in-pump redelivery sweep ------------------------------------------
  #
  # The broker-side Sweeper (Smalt.Amqp.Sweeper) re-avails expired message
  # locks in the store, but deliver_available/1 runs only on inbound :flow and
  # on the enqueue path. A receiver whose client holds link credit open
  # (rhea/SDK receivers keep a credit window outstanding) never sees the
  # re-availed message: no :flow arrives, so no claim is attempted. This
  # bounded sweep re-runs deliver_available/1 so expired-lock redelivery
  # reaches attached receivers WITHOUT dropping the link. Interval law: when
  # queue links are open, the sweep rides the SHORTEST lock-duration expiry of
  # the queues involved (read from the ARM queue record), so an expired lock
  # is noticed within ~one lock window of the Sweeper's re-avail; with no
  # eligible links the deadline idles at a slow heartbeat.
  defp redelivery_sweep(state) do
    now = :os.system_time(:millisecond)

    if state.phase == :amqp_frames and now >= state.next_redeliver_at do
      state2 = Delivery.deliver_available(state)
      %{state2 | next_redeliver_at: now + redelivery_tick_interval(state2)}
    else
      sweep_skipped(state)
      state
    end
  end

  # Typed skip marker keeps the skip branch honest (no silent fall-through).
  defp sweep_skipped(%{phase: :amqp_frames}), do: :deadline_not_reached
  defp sweep_skipped(_), do: :connection_not_open

  defp redelivery_tick_interval(state) do
    case queue_link_addresses(state) do
      [] ->
        @redelivery_tick_idle_ms

      addrs ->
        addrs
        |> Enum.map(fn addr ->
          case QueueStore.queue_settings(addr) do
            %{lock_duration_ms: d} when is_integer(d) and d > 0 -> d
            _ -> @redelivery_tick_cap_ms
          end
        end)
        |> Enum.min()
        |> max(@redelivery_tick_floor_ms)
        |> min(@redelivery_tick_cap_ms)
    end
  end

  # Distinct queue addresses of open sender-role queue links with credit.
  defp queue_link_addresses(state) do
    state.links
    |> Map.values()
    |> Enum.filter(fn link ->
      link.role == :sender and link.kind == :queue and Map.get(link, :credit, 0) > 0
    end)
    |> Enum.map(& &1.address)
    |> Enum.uniq()
  end

  @impl true
  def handle_info(:recv, state) do
    # KD-COVERS: KD-69 — fresh await deadline per pump iteration (set in
    # need_more/2 when the wait begins, cleared on arrival / requeue).
    state = %{state | recv_deadline: nil}

    event =
      try do
        next_input(state)
      rescue
        # Pump-level containment (lens-4 cycle-3 hardening): a decode/handler
        # raise here used to kill the connection with no diagnosis on the wire
        # or in the log. Emit the typed close and halt.
        e ->
          Logger.error("[amqp-conn] pump raise: #{Exception.message(e)}")
          {:error, {:raised, Exception.message(e)}, %{state | halted: true}}
      end

    case event do
      {:ok, event, state} ->
        case do_handle_event(event, state) do
          %{halted: true} = state ->
            {:stop, :normal, state}

          state ->
            send(self(), :recv)
            {:noreply, state}
        end

      # KD-COVERS: KD-69 — the short-recv drain requeued a typed detach
      # message (evict / AZB-07) to the mailbox tail; stop pumping and let
      # the GenServer dispatch it against the latest state. The clause that
      # handles it resumes the pump via send(self(), :recv).
      {:requeued, state} ->
        {:noreply, state}

      {:closed, state} ->
        {:stop, :normal, state}

      {:error, reason, state} ->
        Logger.warning("[amqp-conn] closing on #{inspect(reason)}")

        # recv :timeout after open = the peer blew the negotiated
        # idle-time-out (R3 slowloris finding): close with a typed error
        # instead of holding the socket for the full default window.
        close_reason =
          case reason do
            :timeout -> "amqp:resource-limit-exceeded"
            # AZB-07: profile-configured frame cap (integration plane) — typed
            # condition, connection close, never a crash.
            {:frame_exceeds_configured_max, _declared, _max} ->
              "amqp:frame-size-too-small"

            _other -> "amqp:internal-error"
          end

        {:stop, :normal, close_with_error(state, close_reason, inspect(reason))}
    end
  end

  # Cross-connection epoch eviction: the NEW attach's connection asked THIS
  # connection to detach the incumbent epoch-holding link (GAP-A2-02).
  def handle_info({:eh_epoch_evict, channel, handle, error}, state) do
    state =
      case Link.link_by_handle(state, channel, handle) do
        nil -> state
        link ->
          send_frame(state, link.channel, {:detach, %{handle: handle, closed: true, error: error}})
          Link.eh_epoch_release(link)
          %{state | links: Map.delete(state.links, {channel, handle})}
      end

    # KD-COVERS: KD-69 — resume the short-recv pump after applying the
    # detach (the drain requeued this message so the latest state applies;
    # the buffer may still hold bytes to parse).
    send(self(), :recv)
    {:noreply, state}
  end

  def handle_info({:azb07_force_partition_detach, address}, state) do
    # AZB-07: broker-forced partition detach (real Event Hubs behavior: the
    # service detaches a partition receiver with `amqp:link:detach-forced`;
    # well-behaved clients relink cleanly). Receiver links on `address` get
    # the typed detach; the connection stays up so the relink is clean.
    {detached, links} =
      Enum.flat_map_reduce(state.links, %{}, fn {{ch, h}, link}, acc ->
        if link[:kind] == :eventhubs and link[:role] in [:sender, false] and
             link[:address] == address do
          send_frame(state, ch, {:detach,
            %{handle: h, closed: true,
              error: %{condition: "amqp:link:detach-forced",
                      description: "PARTITION_DETACH"}}})

          Link.eh_epoch_release(link)
          {[{ch, h}], acc}
        else
          {[], Map.put(acc, {ch, h}, link)}
        end
      end)

    # KD-COVERS: KD-69 — resume the short-recv pump after the detach.
    if detached == [] do
      send(self(), :recv)
      {:noreply, state}
    else
      send(self(), :recv)
      {:noreply, %{state | links: links}}
    end
  end

  # T-12 (c) :sb_chaos_session_timeout_ms — the armed close timer FIRED
  # (Process.send_after scheduling per the no-sleep law, never a sleep).
  # Close the session with a typed error so the client's session/connection
  # recreation path is exercised deterministically. A stale timer (the client
  # already ended / re-began this channel) no-ops via the chaos_ref match;
  # cleanup mirrors the :end handler: drop the channel's links, release
  # their epoch registrations, retire its outbound deliveries.
  def handle_info({:sb_chaos_session_timeout, ch, ref}, state) do
    if Session.get_session(state, ch)[:chaos_ref] == ref do
      Smalt.Messaging.Chaos.emit(:session_timeout, %{timeout_ms: Smalt.Messaging.Chaos.session_close_bound()}, %{
        channel: ch
      })

      send_frame(state, ch, {
        :end,
        %{error: %{condition: "amqp:internal-error", description: "SMALT_CHAOS_SESSION_TIMEOUT"}}
      })

      state.links
      |> Map.filter(fn {_h, l} -> l.channel == ch end)
      |> Enum.each(&Link.eh_epoch_release/1)

      session =
        case state.session do
          %{channel: ^ch} -> nil
          _ -> state.session
        end

      {:noreply,
       %{
         state
         | session: session,
           links: Map.reject(state.links, fn {_h, l} -> l.channel == ch end),
           sessions: Map.delete(state.sessions || %{}, ch),
           outbound_deliveries:
             Map.reject(state.outbound_deliveries, fn {_id, d} -> d[:channel] == ch end)
       }}
      |> resume_pump()
    else
      # Stale timer (client already re-began): keep pumping.
      {:noreply, state}
      |> resume_pump()
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # KD-COVERS: KD-69 — resume the short-recv pump after a requeued
  # mailbox message was dispatched (same contract as the epoch-evict and
  # AZB-07 handlers: the drain yielded so the latest state applies).
  # Placement note (L9): kept AFTER the handle_info/2 clause group so the
  # clauses stay grouped (same compiler grouping rule as handle_amqp/4).
  defp resume_pump({:noreply, state}) do
    send(self(), :recv)
    {:noreply, state}
  end

  @impl true
  # SHIM-COURT: best-effort release of session locks held by this
  # connection's receiver links so a crashed connection cannot pin
  # sessions (acceptSession would otherwise wait out the lock TTL).
  def terminate(_reason, %{sock: sock, links: links}) when is_map(links) do
    links
    |> Map.values()
    |> Enum.each(fn link ->
      # Role note: the lock-holding link is a client-RECEIVER session link,
      # whose SERVER-side role is :sender (role is the server's AMQP role).
      # The previous :receiver gate never matched, so a closed/crashed
      # session receiver pinned the session lock until TTL (s5 probe 6).
      if is_map(link) and link[:kind] == :queue and link[:role] == :sender and
           is_binary(link[:session_id]) and link[:session_id] != "" do
        try do
          Smalt.Amqp.LockManager.session_release(link[:address], link[:session_id])
        rescue
          _ -> :ok
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :gen_tcp.close(sock)
  end

  def terminate(_reason, %{sock: sock}), do: :gen_tcp.close(sock)

  # ===========================================================================
  # Input pump: header peeling + frame framing
  # ===========================================================================

  defp next_input(%{phase: phase} = state) when phase in [:sasl_header, :amqp_header] do
    case Handshake.handle_header(state) do
      {:ok, state} -> next_input(state)
      other -> other
    end
  end

  defp next_input(%{buffer: buf} = state) do
    case configured_frame_size_violation(buf) do
      {declared, max} ->
        {:error, {:frame_exceeds_configured_max, declared, max}, state}

      nil ->
        case FrameCodec.decode_frame(buf) do
          {:ok, frame} ->
            {:ok, {:frame, frame}, %{state | buffer: rest_after(buf, frame)}}

          {:more, n} ->
            need_more(state, n - byte_size(buf))

          {:error, reason} ->
            {:error, reason, state}
        end
    end
  end

  # AZB-07 (:amqp profile read site, one-source via Smalt.Config.amqp/0): when
  # the integration-plane profile sets :max_frame_size, a frame whose declared
  # size exceeds the configured cap closes with the typed
  # amqp:frame-size-too-small condition — never a crash. Unset = the
  # frame_codec hard cap governs (default boot byte-identical).
  defp configured_frame_size_violation(buf) when byte_size(buf) >= 4 do
    with max when is_integer(max) <- Handshake.configured_max_frame_size(),
         <<declared::unsigned-integer-size(32), _::binary>> <- buf,
         true <- declared > max do
      {declared, max}
    else
      _ -> nil
    end
  end

  defp configured_frame_size_violation(_buf), do: nil

  # KD-COVERS: KD-69 — short-recv mailbox-servicing pump. The old
  # need_more/2 blocked in :gen_tcp.recv for the FULL pre-open / idle
  # connection timeout, so a cross-connection {:eh_epoch_evict, ...} typed
  # detach (eh_epoch_admit/3) sat unprocessed in an idle incumbent's mailbox
  # up to 300s, until its client next sent bytes (face-2 falsifier FAIL:
  # the detach was delivered only after the client sent a flow frame).
  # Segment the wait: 100ms recv slices with a selective mailbox drain
  # between slices, so typed detaches and the T-12 (c) armed session-timeout
  # close are applied while the connection idles. Non-matching mailbox
  # messages are NEVER stolen: the receive has no catch-all clause, so only
  # the typed messages matched below can be consumed here.
  defp need_more(%{sock: sock, buffer: buf} = state, want) do
    want = max(want, 1)

    # R3 clamp table, unchanged: pre-open (SASL/header phase) a short cap
    # closes truncated-frame / slow-start slowloris attacks; post-open the
    # negotiated idle-time-out governs (floor 60s, ceiling @recv_timeout).
    idle_timeout =
      if state[:conn_opened] == true,
        do: state[:idle_time_out] || @recv_timeout,
        else: @pre_open_timeout

    # One deadline per await: set when the wait begins, cleared on data
    # arrival and at pump entry.
    now = :os.system_time(:millisecond)
    deadline = state[:recv_deadline] || now + idle_timeout

    case :gen_tcp.recv(sock, want, min(@pump_wait_ms, max(deadline - now, 1))) do
      {:ok, data} ->
        next_input(%{state | buffer: <<buf::binary, data::binary>>, recv_deadline: nil})

      {:error, :timeout} ->
        if now >= deadline do
          # Clamp expiry: identical to the old single-recv :timeout handling
          # upstream ({:closed, state} → typed stop, no close frame).
          {:closed, state}
        else
          # KD-COVERS: KD-127 — bounded in-pump redelivery sweep. When the
          # global Sweeper re-avails an expired message lock, open
          # connections are not otherwise notified, so a receiver holding
          # outstanding link credit never sees the redelivery until it sends
          # a new :flow or re-attaches (K6 falsifier: no redelivery at
          # 2.6s/31.5s with the first receiver attached; only link close
          # restored re-claimability). The recv timeout slice is the one point
          # where an idle connection already wakes with current state, so the
          # sweep rides it (deadline-checked, never sleep-coordinated).
          # SLEEP-CLASS: POLL-STEP — the recv slice is the pump's existing
          # observation point; the sweep adds a real store check per interval.
          state = redelivery_sweep(%{state | recv_deadline: deadline})

          case pump_drain(state) do
            # Requeued typed detach: yield so the GenServer dispatches it
            # against the latest state; the clause resumes the pump.
            {:requeued, state2} -> {:requeued, state2}
            state2 -> need_more(state2, want)
          end
        end

      {:error, :closed} -> {:closed, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Handshake-phase wait entry point (the header peel needs more bytes).
  def pump_wait(state, want), do: need_more(state, want)

  # Selective mailbox drain between recv slices. Matches ONLY the typed
  # detach / chaos-timer messages: on a match the message is requeued to the
  # mailbox tail and the wait returns {:requeued, state} so the pump yields
  # and the GenServer dispatches it against the LATEST state (no forked
  # state).
  defp pump_drain(state) do
    receive do
      {:eh_epoch_evict, _, _, _} = msg ->
        send(self(), msg)
        {:requeued, %{state | recv_deadline: nil}}

      {:azb07_force_partition_detach, _} = msg ->
        send(self(), msg)
        {:requeued, %{state | recv_deadline: nil}}

      # T-12 (c): the armed session-timeout close must fire while the
      # connection IDLES (the whole point of the injection — the client is
      # quiescent and waits for the broker's typed :end). Without this
      # requeue the timer message starves behind the recv pump and the
      # session never closes until the peer speaks again.
      {:sb_chaos_session_timeout, _, _} = msg ->
        send(self(), msg)
        {:requeued, %{state | recv_deadline: nil}}
    after
      0 -> state
    end
  end

  # FrameCodec consumes exactly the leading frame; drop it from the buffer.
  defp rest_after(buf, _frame) do
    case buf do
      <<size::unsigned-integer-size(32), rest::binary>> when byte_size(rest) >= size - 4 ->
        binary_part(buf, size, byte_size(buf) - size)

      _ ->
        <<>>
    end
  end

  # ===========================================================================
  # Event handling: SASL + AMQP state routing
  # ===========================================================================

  defp do_handle_event({:frame, frame}, state) do
    perf = frame.performative
    channel = frame.channel

    if frame.type == :sasl do
      Handshake.handle_sasl(perf, state)
    else
      handle_amqp(perf.performative, Map.put(perf, :__payload__, frame[:payload]), channel, state)
    end
  end

  # --- AMQP performative routing (logic in the phase modules) -------------------

  defp handle_amqp(:attach, perf, channel, state), do: Link.handle_attach(perf, channel, state)

  defp handle_amqp(:flow, perf, ch, state), do: Session.handle_flow(perf, ch, state)

  defp handle_amqp(:open, perf, _ch, state), do: Handshake.handle_open(perf, state)

  defp handle_amqp(:begin, perf, ch, state), do: Session.handle_begin(perf, ch, state)

  defp handle_amqp(:transfer, perf, channel, state),
    do: Delivery.handle_transfer(perf, channel, state)

  defp handle_amqp(:disposition, perf, channel, state),
    do: Delivery.handle_disposition(perf, channel, state)

  defp handle_amqp(:detach, perf, ch, state), do: Link.handle_detach(perf, ch, state)

  defp handle_amqp(:end, perf, ch, state), do: Session.handle_end(perf, ch, state)

  defp handle_amqp(:close, perf, ch, state), do: Session.handle_close(perf, ch, state)

  # KD-COVERS: KD-129 — transport heartbeat (empty body frame, spec §2.3.1)
  # decodes to performative :heartbeat; it must be consumed silently, never
  # answered with amqp:not-implemented (which closed live idle connections).
  defp handle_amqp(:heartbeat, _perf, _ch, state), do: state

  defp handle_amqp(name, _perf, _ch, state) do
    error_close(state, "amqp:not-implemented", "unexpected performative #{inspect(name)}")
  end

  # ===========================================================================
  # Wire-out helpers (shared by the phase modules)
  # ===========================================================================

  def send_frame(state, channel, {name, fields}) do
    # Repair lane R96 (A24 follow-up): was an unguarded IO.puts(:stderr, ...)
    # debug print on every EH transfer — Logger-gated now, silent at default
    # verbosity.
    if name == :transfer,
      do: Logger.debug("DBG tf-send ch=#{channel} h=#{fields.handle}")

    channel = channel || state.session[:channel] || 0

    layer =
      if name in [:sasl_mechanisms, :sasl_init, :sasl_outcome, :sasl_challenge],
        do: :sasl,
        else: :amqp

    data =
      try do
        FrameCodec.encode_frame(layer, channel, {name, fields})
      rescue
        # Outbound encode is a raise-contract (lens-4 cycle-3): an
        # unrepresentable outbound value used to crash the connection
        # GenServer with no diagnosis and no AMQP close on the wire. Route
        # to the typed refusal instead: close frame + halted state.
        e in ArgumentError ->
          Logger.error("[amqp-conn] outbound encode failed: " <> Exception.message(e))

          FrameCodec.encode_frame(
            :amqp,
            channel,
            {:close, %{error: %{condition: "amqp:internal-error", description: "ENCODE_FAILED"}}}
          )
      end

    :gen_tcp.send(state.sock, data)
  end

  def close_with_error(state, condition, description) do
    channel = state.session[:channel] || 0

    data =
      FrameCodec.encode_frame(
        :amqp,
        channel,
        {:close, %{error: %{condition: condition, description: description}}}
      )

    :gen_tcp.send(state.sock, data)
    state
  end

  def error_close(state, condition, description) do
    close_with_error(state, condition, description)
    %{state | halted: true}
  end

  def plain({:symbol, s}) when is_binary(s), do: s
  def plain(s) when is_binary(s), do: s
  def plain(nil), do: nil
  def plain(other), do: other
end
