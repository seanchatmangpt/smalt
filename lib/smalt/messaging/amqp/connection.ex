defmodule Smalt.Amqp.Connection do
  @redelivery_tick_idle_ms 1_000
  @redelivery_tick_floor_ms 250
  @redelivery_tick_cap_ms 20_000

  @moduledoc """
  One AMQP 1.0 connection per accepted `:gen_tcp` socket (passive, binary) with a short-recv mailbox-servicing pump.

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

  alias Smalt.Amqp.{CbsRouter, DeliveryEncoder, FrameCodec, ManagementRpc, QueueStore}
  alias Smalt.Messaging.EventHubs
  alias Smalt.Messaging.EhThrottle

  @max_frame_size 1_048_576
  @protocol_header "AMQP\x00\x01\x00\x00"
  @sasl_protocol_header "AMQP\x03\x01\x00\x00"
  @recv_timeout 300_000
  # SHIM-COURT-eligible clamp: one inbound :flow must not be able to grant
  # unbounded link credit (AMQP §2.7.4 link_credit is a peer-declared cap).
  @max_link_credit 10_000
  @pre_open_timeout 5_000
  @container_id "smalt-local"
  @sasl_anonymous "ANONYMOUS"

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
       # have not settled it yet. Pruned on settlement (handle_disposition).
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
      state2 = deliver_available(state)
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
          case Smalt.Amqp.QueueStore.queue_settings(addr) do
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
      case link_by_handle(state, channel, handle) do
        nil -> state
        link ->
          send_frame(state, link.channel, {:detach, %{handle: handle, closed: true, error: error}})
          eh_epoch_release(link)
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

          eh_epoch_release(link)
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
  # cleanup mirrors handle_amqp(:end): drop the channel's links, release
  # their epoch registrations, retire its outbound deliveries.
  def handle_info({:sb_chaos_session_timeout, ch, ref}, state) do
    if get_session(state, ch)[:chaos_ref] == ref do
      Smalt.Messaging.Chaos.emit(:session_timeout, %{timeout_ms: Smalt.Messaging.Chaos.session_timeout()}, %{
        channel: ch
      })

      send_frame(state, ch, {
        :end,
        %{error: %{condition: "amqp:internal-error", description: "SMALT_CHAOS_SESSION_TIMEOUT"}}
      })

      state.links
      |> Map.filter(fn {_h, l} -> l.channel == ch end)
      |> Enum.each(fn {_h, l} -> eh_epoch_release(l) end)

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
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

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

  defp next_input(%{phase: phase, buffer: buf} = state)
       when phase in [:sasl_header, :amqp_header] do
    if byte_size(buf) >= 8 do
      <<hdr::binary-size(8), rest::binary>> = buf

      cond do
        # SASL-layer negotiation (AMQP spec header id 0x03)
        phase == :sasl_header and hdr == @sasl_protocol_header ->
          :gen_tcp.send(state.sock, @sasl_protocol_header)

          send_frame(
            state,
            0,
            {:sasl_mechanisms, %{server_mechanisms: [{:symbol, @sasl_anonymous}]}}
          )

          %{state | buffer: rest, phase: :sasl_frames}
          |> next_input()

        # plain AMQP header up front: client skips SASL entirely
        phase == :sasl_header and hdr == @protocol_header ->
          :gen_tcp.send(state.sock, @protocol_header)

          %{state | buffer: rest, phase: :amqp_frames}
          |> next_input()

        # AMQP-layer header after SASL outcome
        hdr == @protocol_header ->
          :gen_tcp.send(state.sock, @protocol_header)

          %{state | buffer: rest, phase: :amqp_frames}
          |> next_input()

        true ->
          # KD-COVERS: KD-45 — the ServiceBusAdministrationClient speaks HTTP
          # ATOM+XML to the SAME port as AMQP (base URL derived from the sb://
          # endpoint). Sniff the request line and serve it here instead of
          # dying with :bad_protocol_header (the SDK surfaced that as
          # HPE_INVALID_CONSTANT and every admin-provisioned probe aborted).
          if Smalt.Amqp.AtomBridge.http?(hdr) do
            Smalt.Amqp.AtomBridge.serve(state.sock, buf)
            {:closed, state}
          else
            {:error, :bad_protocol_header, state}
          end
      end
    else
      need_more(state, 8 - byte_size(buf))
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
    with max when is_integer(max) <- configured_max_frame_size(),
         <<declared::unsigned-integer-size(32), _::binary>> <- buf,
         true <- declared > max do
      {declared, max}
    else
      _ -> nil
    end
  end

  defp configured_frame_size_violation(_buf), do: nil

  defp configured_max_frame_size do
    case Smalt.Config.amqp()[:max_frame_size] do
      n when is_integer(n) and n > 0 -> min(n, FrameCodec.max_frame_size())
      _ -> nil
    end
  end

  # KD-COVERS: KD-69 — short-recv mailbox-servicing pump. The old
  # need_more/2 blocked in :gen_tcp.recv for the FULL pre-open / idle
  # connection timeout, so a cross-connection {:eh_epoch_evict, ...} typed
  # detach (eh_epoch_admit/3) sat unprocessed in an idle incumbent's mailbox
  # up to 300s, until its client next sent bytes (face-2 falsifier FAIL:
  # the detach was delivered only after the client sent a flow frame).
  # Segment the wait: 100ms recv slices with a selective mailbox drain
  # between slices, so typed detaches are applied while the connection
  # idles. Non-matching mailbox messages are NEVER stolen: the receive has
  # no catch-all clause, so only the two typed detach messages can be
  # consumed here.
  @pump_wait_ms 100

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

  # Selective mailbox drain between recv slices. Matches ONLY the two typed
  # detach messages: on a match the message is requeued to the mailbox tail
  # and the wait returns {:requeued, state} so the pump yields and the
  # GenServer dispatches it against the LATEST state (no forked state).
  defp pump_drain(state) do
    receive do
      {:eh_epoch_evict, _, _, _} = msg ->
        send(self(), msg)
        {:requeued, %{state | recv_deadline: nil}}

      {:azb07_force_partition_detach, _} = msg ->
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
  # Event handling: SASL + AMQP state machine
  # ===========================================================================

  defp do_handle_event({:frame, frame}, state) do
    perf = frame.performative
    channel = frame.channel

    if frame.type == :sasl do
      handle_sasl(perf, state)
    else
      handle_amqp(perf.performative, Map.put(perf, :__payload__, frame[:payload]), channel, state)
    end
  end

  # --- SASL -------------------------------------------------------------------

  defp handle_sasl(%{performative: :sasl_init} = perf, state) do
    mech = mech_name(perf.mechanism)

    cond do
      mech == @sasl_anonymous and configured_sasl_admits_anonymous?() ->
        send_frame(state, 0, {:sasl_outcome, %{code: 0}})
        %{state | phase: :amqp_header}

      mech == @sasl_anonymous ->
        # AZB-07 :amqp profile read site: a configured sasl_mechanisms list
        # that excludes :anonymous types the refusal. The advertised set on
        # the wire stays exactly [ANONYMOUS] (wire-compat pinion, verbatim).
        send_frame(state, 0, {:sasl_outcome, %{code: 1}})
        error_close(state, "amqp:unauthorized-access", "SASL :anonymous excluded by profile")

      true ->
        send_frame(state, 0, {:sasl_outcome, %{code: 1}})
        error_close(state, "amqp:unauthorized-access", "unsupported SASL mechanism")
    end
  end

  defp handle_sasl(_perf, state) do
    error_close(state, "amqp:internal-error", "unexpected SASL frame")
  end

  # AZB-07: nil/unset config = ANONYMOUS admitted (today's behavior).
  defp configured_sasl_admits_anonymous? do
    case Smalt.Config.amqp()[:sasl_mechanisms] do
      nil -> true
      mechs when is_list(mechs) -> :anonymous in mechs
      _ -> true
    end
  end

  defp mech_name({:symbol, s}) when is_binary(s), do: s
  defp mech_name(s) when is_binary(s), do: s
  defp mech_name(_), do: nil

  # --- AMQP performatives -------------------------------------------------------

  defp handle_amqp(:attach, perf, channel, state), do: handle_attach(perf, channel, state)

  # KD-COVERS: KD-133 — this handler treats flow fields as a DECODED MAP
  # (order-independent), and FrameCodec's flow field list is AMQP-spec-ordered
  # on emit; spec-ordered client flows witnessed granting credit
  # (verification/ts/fix4-raw-wire.exs + fix4.probe.cjs L3, receipt
  # docs/jira/v26.10.20/receipts/fix4-amqp-witness.md).
  defp handle_amqp(:flow, perf, ch, state) do
    # AMQP 1.0 §2.7.4: an inbound :flow carries an ABSOLUTE link-credit
    # snapshot, not a delta. rhea (link.js on_flow) computes
    # `credit = flow.delivery_count + flow.link_credit - this.delivery_count`;
    # this link state does not track a sent delivery counter, so the
    # delivery_count terms cancel to 0 and the granted credit is the flow's
    # link_credit value directly (see bump_credit/4 below — that helper stays
    # for our OWN outbound decrements, which remain relative by spec).
    # Clamped so a single flow can't request 2^62.
    credit = (perf.link_credit && min(perf.link_credit, @max_link_credit)) || 0

    if chaos_starved?(state, ch, perf.handle, credit) do
      # T-12 (b): the credit grant is WITHHELD while the starve flag is
      # armed — deliveries stall until the flag clears on a re-boot. Credit
      # already outstanding still drains (the stall is on NEW grants).
      deliver_available(state)
    else
      state =
        case perf.handle do
          nil -> add_credit(state, credit, ch)
          handle -> set_credit(state, ch, handle, credit)
        end

      deliver_available(state)
    end
  end

  # T-12 (b) :sb_chaos_starve_credits / :eh_chaos_starve_credits — namespace
  # resolved from the targeted link's kind (a session-level flow, handle
  # nil, only ever grants queue links -> :sb). Emits typed telemetry per
  # withheld grant. Flags off = the grant proceeds byte-identically.
  defp chaos_starved?(state, ch, handle, credit) do
    ns =
      case handle && link_by_handle(state, ch, handle) do
        %{kind: :eventhubs} -> :eh
        _ -> :sb
      end

    if Smalt.Messaging.Chaos.starve?(ns) do
      Smalt.Messaging.Chaos.emit(:credit_starved, %{withheld_credit: credit}, %{
        namespace: ns,
        channel: ch,
        handle: handle
      })

      true
    else
      false
    end
  end

  defp handle_amqp(:open, perf, _ch, state) do
    # KD-21 shim (KD-COVERS: KD-21): the clamped idle-time-out is computed
    # BEFORE the open reply and echoed non-nil in that reply — pyamqp
    # `_incoming_open` indexes frame[4] unguarded and crashes on the
    # spec-legal trailing-null trim. The `|| @recv_timeout` fallback below
    # guarantees a real (non-nil) pad.
    idle =
      case state[:session] do
        %{idle_time_out: t} when is_integer(t) -> t
        _ -> nil
      end ||
        case perf[:idle_time_out] do
          ms when is_integer(ms) and ms > 0 -> min(max(ms, 60_000), @recv_timeout)
          _ -> @recv_timeout
        end

    send_frame(state, 0, {
      :open,
      %{
        container_id: @container_id,
        max_frame_size: configured_max_frame_size() || @max_frame_size,
        channel_max: 65_535,
        idle_time_out: idle
      }
    })

    state =
      Map.put(state, :container_id, plain(perf.container_id))
      |> Map.put(:peer_max_frame_size, clamp_peer_frame_size(perf[:max_frame_size]))

    # Idle-time-out enforcement (R3 red-team finding): a silent or trickle
    # peer previously held the connection for the full 300s recv timeout.
    # Clamp the per-recv wait to the negotiated remote idle-time-out (floor
    # 60s, ceiling 300s); a timeout closes with amqp:resource-limit-exceeded.
    idle =
      case state[:session] do
        %{idle_time_out: t} when is_integer(t) -> t
        _ -> nil
      end ||
        case perf[:idle_time_out] do
          ms when is_integer(ms) and ms > 0 -> min(max(ms, 60_000), @recv_timeout)
          _ -> @recv_timeout
        end

    session = Map.merge(state[:session] || %{}, %{idle_time_out: idle})

    state
    |> Map.put(:session, session)
    |> Map.put(:conn_opened, true)
    |> Map.put(:idle_time_out, idle)
  end

  defp handle_amqp(:begin, perf, ch, state) do
    # Channel validation (R3 red-team finding): begin on an un-opened
    # connection is rejected with a session end error instead of being
    # silently accepted.
    if state[:conn_opened] != true do
      send_frame(state, ch, {
        :end,
        %{error: %{condition: "amqp:not-allowed", description: "SESSION_BEFORE_OPEN"}}
      })

      %{state | halted: true}
    else
      do_begin(perf, ch, state)
    end
  end

  defp handle_amqp(:transfer, perf, channel, state), do: handle_transfer(perf, channel, state)

  defp handle_amqp(:disposition, perf, channel, state),
    do: handle_disposition(perf, channel, state)

  defp handle_amqp(:detach, perf, ch, state) do
    case link_by_handle(state, ch, perf.handle) do
      nil ->
        state

      link ->
        # Release a held session lock when its receiver link detaches, so a
        # subsequent acceptSession can acquire it (real Service Bus parity).
        # Role note: the lock-holding link is a client-RECEIVER session link,
        # whose SERVER-side role is :sender — the previous :receiver gate
        # never matched and the lock waited out the TTL (s5 probe 6).
        if link.kind == :queue and link.role == :sender and is_binary(link.session_id) and
             link.session_id != "" do
          Smalt.Amqp.LockManager.session_release(link.address, link.session_id)
        end

        # GAP-A2-02: release this link's exclusive-receiver registration so a
        # subsequent epoch attach admits (only if it still names THIS link).
        eh_epoch_release(link)

        send_frame(state, link.channel, {:detach, %{handle: perf.handle, closed: true}})
        %{state | links: Map.delete(state.links, {ch, perf.handle})}
    end
  end

  defp handle_amqp(:end, _perf, ch, state) do
    # Session end is NOT a connection close (census wire finding): closing the
    # TCP socket here killed the SDK's whole connection after its first send
    # (core-amqp closes the session after a sender close) and every later
    # probe starved silently. Ack the end, drop this session's state, keep the
    # connection alive.
    send_frame(state, ch, {:end, %{error: nil}})

    # Drop only the ended channel's links; other sessions on the same
    # connection keep theirs (the SDK keeps the $cbs session open while
    # closing the send session).
    remaining = Map.reject(state.links, fn {_h, l} -> l.channel == ch end)

    # GAP-A2-02: release epoch registrations held by this session's links.
    state.links
    |> Map.filter(fn {_h, l} -> l.channel == ch end)
    |> Enum.each(fn {_h, l} -> eh_epoch_release(l) end)

    # SHIM-COURT: retire this session's in-flight outbound deliveries so a
    # re-begin (next_out restarts at 0) cannot collide delivery-ids and let
    # handle_disposition settle a stale message.
    outbound = Map.reject(state.outbound_deliveries, fn {_id, d} -> d[:channel] == ch end)

    case state.session do
      %{channel: ^ch} ->
        %{
          state
          | session: nil,
            links: remaining,
            sessions: Map.delete(state.sessions || %{}, ch),
            outbound_deliveries: outbound
        }

      _ ->
        %{
          state
          | links: remaining,
            sessions: Map.delete(state.sessions || %{}, ch),
            outbound_deliveries: outbound
        }
    end
  end

  defp handle_amqp(:close, _perf, ch, state) do
    send_frame(state, ch, {:close, %{error: nil}})
    %{state | halted: true}
  end

  # KD-COVERS: KD-129 — transport heartbeat (empty body frame, spec §2.3.1)
  # decodes to performative :heartbeat; it must be consumed silently, never
  # answered with amqp:not-implemented (which closed live idle connections).
  defp handle_amqp(:heartbeat, _perf, _ch, state), do: state

  defp handle_amqp(name, _perf, _ch, state) do
    error_close(state, "amqp:not-implemented", "unexpected performative #{inspect(name)}")
  end

  defp do_begin(perf, ch, state) do
    sess = get_session(state, ch)
    next_out = sess.next_out

    send_frame(state, ch, {
      :begin,
      %{
        remote_channel: ch,
        next_outgoing_id: next_out,
        incoming_window: 10_000,
        outgoing_window: 10_000,
        handle_max: 1000
      }
    })

    session = %{
      channel: ch,
      next_incoming_id: perf[:next_outgoing_id] || 0,
      next_outgoing_id: next_out
    }

    state
    |> Map.put(:session, session)
    |> put_session(ch, %{next_out: next_out, next_in: perf[:next_outgoing_id] || 0})
    |> chaos_arm_session_timeout(ch)
  end

  # T-12 (c) arm: :sb_chaos_session_timeout_ms (with the :eh_ twin honored —
  # the session layer is shared, so Chaos.session_timeout/0 returns the
  # shortest armed bound). Arms a deterministic close timer keyed by a
  # make_ref token so a stale timer can never close a NEWER session re-begun
  # on the same channel. Off (:infinity) = no timer, zero interference.
  defp chaos_arm_session_timeout(state, ch) do
    case Smalt.Messaging.Chaos.session_timeout() do
      ms when is_integer(ms) and ms > 0 ->
        ref = make_ref()
        Process.send_after(self(), {:sb_chaos_session_timeout, ch, ref}, ms)
        put_session(state, ch, Map.put(get_session(state, ch), :chaos_ref, ref))

      _ ->
        state
    end
  end

  defp send_flow(state, channel, extra) do
    sess = get_session(state, channel)

    fields =
      Map.merge(
        %{
          next_incoming_id: Map.get(sess, :next_in, 0),
          incoming_window: 10_000,
          next_outgoing_id: sess.next_out,
          outgoing_window: 10_000
        },
        extra
      )

    send_frame(state, channel, {:flow, fields})
  end

  # --- attach routing -----------------------------------------------------------

  defp handle_attach(perf, channel, state) do
    client_role = if perf.role == true, do: :receiver, else: :sender
    # our endpoint role is the inverse of the client's
    our_role = if client_role == :sender, do: :receiver, else: :sender

    address =
      if client_role == :sender do
        address_of(perf.target)
      else
        address_of(perf.source)
      end

    # Repair lane R96: pyamqp-dialect clients attach queue links with the FULL
    # "amqps://host:port/entity" source/target, but every store key (message
    # rows {queue, seq}, session locks {queue, sid}, ARM queue settings suffix
    # "/queues/<name>", management get-message-sessions queue field) is keyed
    # by the BARE entity name. Without stripping, queue_settings missed the
    # ARM row (requiresSession never fired for real SDK attaches) and
    # get-message-sessions keyed on the bare name found nothing stored under
    # NOTE: URI-form addresses are normalized to the bare entity name AFTER
    # the authorized? gate below — the CBS token audience is keyed by the full
    # scheme://host:port/entity form, so the raw address is what authorized?
    # must see.
    kind = route(address, state.mode)

    # Fixed-partition pinion: a partition-scoped EH attach outside the pinned
    # set ["0","1"] is refused (echo-attach + typed detach — the rhea/core-amqp
    # contract needs the attach echo first). Send side pins storage to the pair
    # (eh_pk_partition), so an out-of-pin receiver could never be delivered to.
    if kind == :eventhubs and eh_partition_scope(address) == :refused do
      send_frame(state, channel, {
        :attach,
        %{
          name: perf.name,
          handle: perf.handle,
          role: our_role == :receiver,
          initial_delivery_count: 0
        }
      })

      send_frame(state, channel, {
        :detach,
        %{
          handle: perf.handle,
          closed: true,
          error: %{
            condition: "amqp:not-allowed",
            description: "partition outside the fixed set [\"0\",\"1\"]"
          }
        }
      })

      state
    else
      # rhea (core-amqp) requires the broker attach echo BEFORE any detach
      # (Session.on_attach populates remote.handles only on attach; a bare
      # detach raises "Invalid handle N" client-side). Echo attach, then
      # detach typed.
      if kind == :queue and not authorized?(address) do
        send_frame(state, channel, {
          :attach,
          %{
            name: perf.name,
            handle: perf.handle,
            role: our_role == :receiver,
            initial_delivery_count: 0
          }
        })

        send_frame(state, channel, {
          :detach,
          %{handle: perf.handle, closed: true, error: unauthorized_error()}
        })

        state
      else
        {kind, address} = normalize_dql_casing(kind, address)

        # Repair lane R96: pyamqp-dialect clients attach queue links with the
        # FULL "amqps://host:port/entity" source/target, but every store key
        # (message rows {queue, seq}, session locks {queue, sid}, ARM queue
        # settings suffix "/queues/<name>", management get-message-sessions
        # queue field) is keyed by the BARE entity name. Without stripping,
        # queue_settings missed the ARM row (requiresSession never fired for
        # real SDK attaches) and get-message-sessions keyed on the bare name
        # found nothing stored under the URI form (session receiver starved +
        # enumeration returned []). Normalization stays AFTER the authorized?
        # gate: the CBS token audience is keyed by the full scheme://host:port
        # form, so the raw address is what authorized? must see.
        address = bare_entity(address)

        link = %{
          name: plain(perf.name),
          handle: perf.handle,
          channel: channel,
          role: our_role,
          session_id: extract_session_filter(perf.source),
          eh_cursor: 0,
          # GAP-A2-01/02 (KD-68/KD-69): per-link EH receiver cursor state —
          # eh_start is the eventPosition the receiver attached with, eh_cursor
          # tracks what THIS link has delivered, eh_min_enqueued carries an
          # enqueuedTime filter floor (epoch ms), eh_epoch the exclusive-receiver
          # epoch (com.microsoft:epoch).
          eh_start: nil,
          eh_link_cursor: nil,
          eh_min_enqueued: nil,
          eh_epoch: nil,
          address: address,
          kind: kind,
          credit: 0,
          partial: nil
        }

        # Disclosed cross-lane unblock (s5_sessions e2e lane): the Service Bus
        # SDK derives the granted session id from the attach response's source
        # filter (com.microsoft:session-filter). Without the source echo it
        # reads undefined and fails acceptSession with "session may be locked".
        # KD-COVERS: KD-49
        base_attach = %{
          name: perf.name,
          handle: perf.handle,
          role: our_role == :receiver,
          initial_delivery_count: 0,
          # KD-49 shim: echo the client's own source/target back. pyamqp
          # `_incoming_attach` requires both descriptors ("Invalid link" ->
          # detach otherwise); rhea tolerates the omission. frame_codec trims
          # nil, so a nil side is trimmed as before. The session case below
          # Map.merge's over these keys and still wins.
          source: perf.source,
          target: perf.target
        }

        # The enriched link must escape through the case result: rebinding `link`
        # inside a case branch does NOT leak to the enclosing scope (Elixir
        # scoping — the enriched value was silently dropped here, so every EH
        # selector/epoch receiver registered with eh_start/eh_epoch = nil,
        # GAP-A2-01/02 falsifier failures R69).
        {attach_fields, state, eh_link} =
          case {kind, our_role, link.session_id} do
            {:queue, :sender, sid} when is_binary(sid) and sid != "" ->
              # R178e (census stale-handle): the session lock must ride the
              # QUEUE's configured lockDuration (ARM/ATOM record), not the
              # LockManager default — expiry lands on the created schedule or
              # a PT15S session stays locked 30s and the post-expiry re-acquire
              # is refused SessionCannotBeLocked.
              case Smalt.Amqp.LockManager.session_acquire(address, sid,
                     duration_ms: QueueStore.queue_settings(address).lock_duration_ms
                   ) do
                {:ok, slock} ->
                  fields =
                    Map.merge(base_attach, %{
                      source: %{
                        address: address,
                        filter: {:map_rhea, %{{:symbol, "com.microsoft:session-filter"} => sid}}
                      },
                      properties: %{
                        # .NET filetime (100ns ticks since 0001-01-01), not
                        # raw-microseconds: the plain *10_000 multiply misses
                        # the epoch offset (~1969 years) and every real client
                        # read a lock expiry in 1969 (docs-lane finding).
                        "com.microsoft:locked-until-utc" =>
                          DeliveryEncoder.filetime_from_ms(slock.locked_until)
                      }
                    })

                  {fields, state, link}

                {:error, :already_locked} ->
                  # rhea (core-amqp) requires the broker attach echo BEFORE any
                  # detach: Session.on_attach populates remote.handles only on
                  # the attach, and a bare detach raises "Invalid handle N",
                  # crashing the client before it can map the error (census
                  # exclusive-session probe). Echo attach, then detach typed.
                  send_frame(state, channel, {:attach, base_attach})

                  send_frame(state, channel, {
                    :detach,
                    %{
                      handle: perf.handle,
                      closed: true,
                      error: %{
                        condition: "com.microsoft:session-cannot-be-locked",
                        description: "SESSION_CANNOT_BE_LOCKED"
                      }
                    }
                  })

                  {nil, state, link}
              end

            # R129 exploit 2 (W5-17): an UNFILTERED receiver (no
            # com.microsoft:session-filter) on a requiresSession queue used to
            # fall through to the catch-all clause and register with
            # session_id: nil — claim_candidates' nil filter then matched ALL
            # messages, draining other sessions' locked messages. Real Azure
            # refuses this attach: echo the attach, then detach typed
            # (session-cannot-be-locked class). Same echo-then-detach ordering
            # as the already_locked refusal above (rhea needs the broker echo
            # before any detach). A queue that does NOT require sessions
            # (including unknown queues -> default settings) passes through to
            # the default clause unchanged.
            {:queue, :sender, sid}
            when is_nil(sid) or sid == "" ->
              cond do
                # KD-COVERS: KD-121
                # KD-121: acceptNextSession sends a session-filter attach with
                # a NULL selector. extract_session_filter reads it as nil, so
                # this attach used to fall through to the unfiltered passthrough
                # (no session-filter echo, no locked-until-utc properties) and
                # the SDK's messageSession.js threw TypeError on the missing
                # lock fields. Real broker behavior: pick the next unlocked
                # session, lock it, and echo the attach with the chosen sid +
                # lock fields; none available -> echo + typed detach (the SDK
                # surfaces the detach error as a clean translated failure).
                nil_session_filter?(perf.source) ->
                  case next_unlocked_session(address) do
                    {sid2, slock} ->
                      fields =
                        Map.merge(base_attach, %{
                          source: %{
                            address: address,
                            filter:
                              {:map_rhea, %{{:symbol, "com.microsoft:session-filter"} => sid2}}
                          },
                          properties: %{
                            "com.microsoft:locked-until-utc" =>
                              DeliveryEncoder.filetime_from_ms(slock.locked_until)
                          }
                        })

                      {fields, state, link}

                    :none ->
                      send_frame(state, channel, {:attach, base_attach})

                      send_frame(state, channel, {
                        :detach,
                        %{
                          handle: perf.handle,
                          closed: true,
                          error: %{
                            condition: "com.microsoft:session-cannot-be-locked",
                            description: "NO_UNLOCKED_SESSIONS_AVAILABLE"
                          }
                        }
                        })

                      {nil, state, link}
                  end

                # R129 exploit 2 (W5-17): an UNFILTERED receiver (no
                # com.microsoft:session-filter) on a requiresSession queue
                # falls to the catch-all clause and registered with
                # session_id: nil — claim_candidates' nil filter then matched
                # ALL messages, draining other sessions' locked messages. Real
                # Azure refuses this attach: echo the attach, then detach typed
                # (session-cannot-be-locked class). Same echo-then-detach
                # ordering as the acceptNextSession refusal above (rhea needs
                # the broker echo before any detach). A queue that does NOT
                # require sessions (including unknown queues -> default
                # settings) passes through to the default clause unchanged.
                QueueStore.queue_settings(address).requires_session ->
                  send_frame(state, channel, {:attach, base_attach})

                  send_frame(state, channel, {
                    :detach,
                    %{
                      handle: perf.handle,
                      closed: true,
                      error: %{
                        condition: "com.microsoft:session-cannot-be-locked",
                        description: "SESSION_CANNOT_BE_LOCKED"
                      }
                    }
                  })

                  {nil, state, link}

                true ->
                  {base_attach, state, link}
              end

            # GAP-A2-01/02 (KD-68/KD-69): EH receiver attach — read the
            # `apache.org:selector-filter:string` source filter as the
            # eventPosition start cursor and enforce com.microsoft:epoch
            # exclusive-receiver semantics on the partition + consumer group.
            {:eventhubs, :sender, _} ->
              partition = eh_partition(address)

              link = Map.put(link, :eh_epoch, eh_attach_epoch(perf))

              # KD-68 (r200c falsifier FIRED): a present-but-unparseable
              # selector must detach typed, never silently pass through
              # unfiltered (that is the exact vacuity the falsifier caught).
              case eh_apply_selector_filter(link, perf, partition) do
                {:ok, link} ->
                  # rhea (core-amqp) requires the broker attach echo BEFORE any
                  # detach on this session (same rule as the session-cannot-be-
                  # locked refusal above). Echo first, THEN evict/refuse by epoch.
                  send_frame(state, channel, {:attach, base_attach})

                  case eh_epoch_admit(link, address, state) do
                    {:ok, state} ->
                      # The echo was already sent above; the outer registration
                      # case must not echo again.
                      {:echoed, state, link}

                    {:refused, state} ->
                      send_frame(state, channel, {
                        :detach,
                        %{
                          handle: perf.handle,
                          closed: true,
                          error: eh_epoch_error("EPOCH_REFUSED", link.eh_epoch)
                        }
                      })

                      {nil, state, link}
                  end

                {:error, selector} ->
                  # SHIM-COURT KD-68: unsupported selector form -> attach echo
                  # then typed detach (rhea needs the echo before any detach).
                  send_frame(state, channel, {:attach, base_attach})

                  send_frame(state, channel, {
                    :detach,
                    %{
                      handle: perf.handle,
                      closed: true,
                      error: eh_selector_error(selector)
                    }
                  })

                  {nil, state, link}
              end

            _ ->
              {base_attach, state, link}
          end

        case attach_fields do
          nil ->
            # Refused attach (session-cannot-be-locked): the attach echo + typed
            # detach were already sent. The link must NOT be registered: a later
            # cleanup detach from the client for this handle would then match
            # link_by_handle and — queue+session link that it is — release the
            # session lock held by the *legitimate* receiver, killing its
            # renewSessionLock (census exclusive-session probe, wire-traced
            # 09:16:22.501→.502 detach ch=2 h=0).
            state

          :echoed ->
            # EH epoch path (GAP-A2-02): the attach echo was already sent before
            # eviction/refusal — register the link without re-echoing. EH
            # receivers get credit from the client's own flow, none is granted
            # here.
            %{state | links: Map.put(state.links, {channel, perf.handle}, eh_link)}

          _ ->
            send_frame(state, channel, {:attach, attach_fields})

            # grant link credit for client-sender links so peer transfers can flow.
            # delivery_count MUST be present: rhea computes sender credit as
            # `flow.delivery_count + flow.link_credit - this.delivery_count`
            # (rhea/lib/link.js Sender.prototype.on_flow); omitting it makes the
            # credit NaN and 'sendable' never fires (every send times out).
            # It must agree with the attach reply's initial_delivery_count (0).
            eh_link =
              if client_role == :sender do
                send_flow(state, channel, %{
                  handle: perf.handle,
                  delivery_count: 0,
                  link_credit: 1000
                })

                %{eh_link | credit: 1000}
              else
                eh_link
              end

            %{state | links: Map.put(state.links, {channel, perf.handle}, eh_link)}
        end
      end
    end
  end

  defp route(nil, _mode), do: :unknown
  defp route("$cbs", _mode), do: :cbs

  defp route(address, mode) when is_binary(address) do
    cond do
      # Precise management rule (replaces substring match): real SDKs attach
      # the management node as bare "$management" (CBS-style) or as the
      # per-entity node "<entity>/$management" (azure-servicebus
      # managementClient.js). A queue merely NAMED e.g. "my-management-queue"
      # must route as a queue, never :management.
      address == "$management" or String.ends_with?(address, "/$management") -> :management
      mode == :eh -> :eventhubs
      String.contains?(address, "/eventhubs/") -> :eventhubs
      true -> :queue
    end
  end

  defp route(_, _), do: :unknown

  # SDKs send "$DeadLetterQueue" capitalized; the store uses lowercase.
  defp normalize_dql_casing(kind, address) when is_binary(address) do
    if kind == :queue and String.contains?(address, "$DeadLetterQueue") do
      {:queue, String.replace(address, "$DeadLetterQueue", "$deadletterqueue")}
    else
      {kind, address}
    end
  end

  defp normalize_dql_casing(kind, address), do: {kind, address}

  # com.microsoft:session-filter selector (FrameCodec decodes it as
  # {:session_filter, selector})
  defp extract_session_filter(%{
         filter: %{"com.microsoft:session-filter" => {:session_filter, selector}}
       }),
       do: selector

  defp extract_session_filter(%{filter: %{session_filter: selector}}), do: selector
  defp extract_session_filter(_), do: nil

  # KD-121: acceptNextSession attaches with the session-filter symbol PRESENT
  # but a NULL selector. extract_session_filter/1 reads that as nil — same as
  # "no filter" — so the attach used to be indistinguishable from an
  # unfiltered attach. Predicate: symbol present AND selector reads nil.
  defp nil_session_filter?(%{filter: f}) when is_map(f) do
    symbol_present? =
      Enum.any?(f, fn {k, _} ->
        key = if is_atom(k), do: Atom.to_string(k), else: k
        key == "com.microsoft:session-filter"
      end)

    symbol_present? and extract_session_filter(%{filter: f}) == nil
  end

  defp nil_session_filter?(_), do: false

  # KD-121: pick the next unlocked session for acceptNextSession. Enumerates
  # the queue's real session records (skip:0, top:100) and acquires the lock
  # on the first that yields; all locked/none -> :none.
  defp next_unlocked_session(address) do
    case QueueStore.list_sessions(address, skip: 0, top: 100, since: nil) do
      {:ok, entries} when is_list(entries) ->
        Enum.find_value(entries, :none, fn e ->
          case Smalt.Amqp.LockManager.session_acquire(address, e.session_id,
                 duration_ms: QueueStore.queue_settings(address).lock_duration_ms
               ) do
            {:ok, slock} -> {e.session_id, slock}
            {:error, _} -> nil
          end
        end)

      _ ->
        :none
    end
  end

  # --- GAP-A2-01/02 (KD-68/KD-69): EH selector filter + epoch exclusivity ----

  @eh_selector_key "apache.org:selector-filter:string"
  @eh_epoch_key "com.microsoft:epoch"

  # decode_source_target normalizes the described selector filter to the
  # literal string key; the rhea map-form path yields the `:selector_filter`
  # atom key.
  # KD-COVERS: KD-68
  defp eh_apply_selector_filter(link, perf, partition) do
    clause =
      case perf.source do
        %{filter: %{@eh_selector_key => {:selector_filter, selector}}} -> selector
        %{filter: %{selector_filter: selector}} -> selector
        _ -> nil
      end

    case eh_parse_event_position(clause, partition) do
      # KD-68: no selector present is fine; a present-but-unparseable
      # selector is a typed-detach error, never silent pass-through.
      nil when is_nil(clause) -> {:ok, link}
      nil -> {:error, clause}
      {:seq, n} -> {:ok, %{link | eh_start: n}}
      {:enqueued, ms} -> {:ok, %{link | eh_min_enqueued: ms}}
    end
  end

  # The SDK eventPosition shapes (partitionReceiver.js:357-360, core-amqp):
  #   fromOffset(o)             -> "amqp.annotation.x-opt-offset > 'o'"
  #   fromSequenceNumber(n)     -> "amqp.annotation.x-opt-sequence-number > 'n'"
  #   fromEnqueuedTime(ms)      -> "amqp.annotation.x-opt-enqueued-time > 'ms'"
  #   latest() / "@latest"      -> "amqp.annotation.x-opt-offset > '@latest'"
  # Those are EXCLUSIVE (strictly greater). The 6.x SDK startingPosition
  # {sequenceNumber: n, isInclusive: true} emits the INCLUSIVE `>=` form
  # (r200c witness: "amqp.annotation.x-opt-sequence-number >= '2'"), which
  # the old exclusive-only regex dropped, so the link delivered from
  # cursor 0 unconditionally. Inclusive positions normalize to the
  # exclusive floor (n-1 / ms-1) so delivery keeps `seq > after_seq`.
  defp eh_parse_event_position(nil, _partition), do: nil
  defp eh_parse_event_position(clause, _partition) when not is_binary(clause), do: nil

  defp eh_parse_event_position(clause, partition) when is_binary(clause) do
    with [_, ann, op, raw] <-
           Regex.run(~r/\Aamqp\.annotation\.(x-opt-[a-z-]+)\s*(>=?)\s*'([^']*)'\z/, clause) do
      floor = if op == ">=", do: 1, else: 0

      case {ann, raw} do
        {"x-opt-offset", "@latest"} when floor == 0 ->
          case EventHubs.last_enqueued(partition) do
            %{"seq" => n} -> {:seq, n}
            _ -> {:seq, 0}
          end

        {"x-opt-offset", v} ->
          eh_pos(eh_int(v), floor, :seq)

        {"x-opt-sequence-number", v} ->
          eh_pos(eh_int(v), floor, :seq)

        {"x-opt-enqueued-time", v} ->
          eh_pos(eh_int(v), floor, :enqueued)

        _ ->
          nil
      end
    end
  end

  defp eh_pos(nil, _floor, _kind), do: nil
  defp eh_pos(n, floor, kind), do: eh_event_position(n - floor, kind)

  defp eh_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp eh_int(_), do: nil

  # nil inputs are filtered by eh_pos/3 above; clauses here receive ints.
  defp eh_event_position(n, :seq), do: {:seq, n}
  defp eh_event_position(ms, :enqueued), do: {:enqueued, ms}

  # --- GAP-A2-02 (KD-69): exclusive receiver (com.microsoft:epoch) -----------

  # Cross-connection epoch registry: {hub, consumer_group, partition} ->
  # {epoch, conn_pid, channel, handle}. A new attach with an equal-or-higher
  # epoch evicts the registered link (typed detach, com.microsoft:epoch-lock-
  # lost); a lower epoch is refused (echo attach + typed detach, EPOCH_REFUSED).
  defp eh_epoch_table do
    case :ets.info(:smalt_eh_epochs) do
      :undefined ->
        try do
          :ets.new(:smalt_eh_epochs, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> :smalt_eh_epochs
        end

      _ ->
        :smalt_eh_epochs
    end
  end

  defp eh_address_parts(address) do
    case address |> String.split("/") |> Enum.reject(&(&1 == "")) do
      ["eventhubs", hub, cg, "Partitions", p] -> {hub, cg, p}
      ["eventhubs", hub, "partitions", p] -> {hub, "$Default", p}
      _ -> nil
    end
  end

  # Attach properties decode with raw {:symbol, k} keys on the wire path.
  defp eh_attach_epoch(perf) do
    case perf.properties do
      %{} = props ->
        Enum.find_value(props, fn
          {{:symbol, @eh_epoch_key}, v} when is_integer(v) -> v
          {@eh_epoch_key, v} when is_integer(v) -> v
          _ -> nil
        end)

      _ ->
        nil
    end
  end

  # Admit (or refuse) an EH receiver attach by epoch. `:refused` means the new
  # link must NOT be registered; eviction of the incumbent happens BEFORE the
  # new link is registered, so the detach always precedes the new delivery.
  defp eh_epoch_admit(link, _address, state) do
    case {link.eh_epoch, eh_address_parts(link.address)} do
      {nil, _} ->
        {:ok, state}

      {epoch, {hub, cg, p}} ->
        eh_epoch_table()
        key = {hub, cg, p}

        incumbent =
          case :ets.lookup(:smalt_eh_epochs, key) do
            [{^key, old_epoch, old_pid, old_ch, old_handle}] ->
              if is_pid(old_pid) and Process.alive?(old_pid) and old_epoch > epoch,
                do: {:incumbent, old_epoch, old_pid, old_ch, old_handle},
                else: nil

            _ ->
              nil
          end

        case incumbent do
          # GAP-A2-02 refusal: a strictly LOWER epoch never evicts — the
          # incumbent stays registered and the new link is refused.
          {:incumbent, _old_epoch, _old_pid, _old_ch, _old_handle} ->
            {:refused, state}

          nil ->
            # Equal-or-higher epoch (or a dead incumbent's stale entry) evicts
            # any registered link on this {consumer-group, partition} first,
            # THEN registers the new link.
            case :ets.lookup(:smalt_eh_epochs, key) do
              [{^key, old_epoch, old_pid, old_ch, old_handle}] when is_pid(old_pid) ->
                evict_error = eh_epoch_error("EPOCH_EVICTION", old_epoch)

                if old_pid == self() do
                  case link_by_handle(state, old_ch, old_handle) do
                    nil ->
                      :ok

                    _old_link ->
                      send_frame(state, old_ch, {
                        :detach,
                        %{handle: old_handle, closed: true, error: evict_error}
                      })
                  end

                  {:ok, %{state | links: Map.delete(state.links, {old_ch, old_handle})}}
                else
                  send(old_pid, {:eh_epoch_evict, old_ch, old_handle, evict_error})
                  {:ok, state}
                end

              _ ->
                {:ok, state}
            end
            |> then(fn
              {:ok, state} ->
                :ets.insert(:smalt_eh_epochs, {key, epoch, self(), link.channel, link.handle})
                {:ok, state}

              other ->
                other
            end)
        end

      _ ->
        {:ok, state}
    end
  end

  # Registry cleanup when an epoch-holding link goes away (client detach,
  # session end, connection close): delete the entry only if it still names
  # THIS link, never a successor's.
  defp eh_epoch_release(link) do
    if link.kind == :eventhubs and is_integer(link.eh_epoch) do
      case eh_address_parts(link.address) do
        {hub, cg, p} ->
          key = {hub, cg, p}

          case :ets.lookup(:smalt_eh_epochs, key) do
            [{^key, _ep, pid, ch, handle}]
            when pid == self() and ch == link.channel and handle == link.handle ->
              :ets.delete(:smalt_eh_epochs, key)

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end
  end

  defp eh_epoch_error(desc, epoch) do
    %{
      condition: "com.microsoft:epoch-lock-lost",
      description: "#{desc}: active epoch #{inspect(epoch)}"
    }
  end

  # KD-68: an unsupported selector-filter form detaches typed instead of
  # silently delivering unfiltered (r200c falsifier lesson). rhea maps
  # amqp:not-implemented to a typed SessionError; the description carries
  # the offending clause for the SDK caller.
  defp eh_selector_error(selector) do
    %{
      condition: "amqp:not-implemented",
      description: "SELECTOR_UNSUPPORTED: #{selector}"
    }
  end

  defp unauthorized_error do
    %{condition: "amqp:unauthorized-access", description: "UNAUTHORIZED_ENTITY"}
  end

  # --- transfer ingestion / RPC ---------------------------------------------------

  defp handle_transfer(perf, channel, state) do
    link = link_by_handle(state, channel, perf.handle)

    case link do
      %{kind: :queue, role: :receiver} = link ->
        state =
          put_session(state, channel, %{
            get_session(state, channel)
            | next_in: (perf[:delivery_id] || 0) + 1
          })

        payload = frame_payload(perf)

        if perf[:more] do
          put_link(state, %{link | partial: (link.partial || <<>>) <> payload})
        else
          payload = (link.partial || <<>>) <> payload
          ingest_message(put_link(state, %{link | partial: nil}), link, perf, payload)
        end

      %{kind: :cbs} ->
        handle_cbs(perf, state)

      %{kind: :management} ->
        handle_management(perf, channel, state)

      %{kind: :eventhubs} = link ->
        payload = frame_payload(perf)
        partition = eh_partition(link.address)
        EventHubs.ensure_tables()
        # GAP-A2-04: capture the sender's partition key (x-opt-partition-key
        # message annotation on the producer's batch envelope) so it can be
        # re-stamped on delivery; falls back closed to nil (no key).
        pk = eh_sender_partition_key(payload)
        # KD-COVERS: KD-76 — a pk-stamped event on a HUB-address sender link is
        # routed to one partition (deterministic hash of the key over the pinned
        # set ["0","1"]) instead of being parked under the bare hub key, so
        # partition-scoped receivers actually deliver it.
        storage_partition = eh_storage_partition(partition, pk, link.address)

        # T30-F1 wiring: an over-quota publish comes back as a typed throttle
        # face and settles REJECTED with the server-busy class condition
        # (EhThrottle.amqp_refusal mapping) — the link stays alive, the sender
        # sees the retry hint in the rejected error description.
        case EventHubs.send_event(storage_partition, payload, partition_key: pk) do
          {:ok, _seq, _event} ->
            delivery_id = perf[:delivery_id] || 0

            send_frame(state, link.channel, {
              :disposition,
              %{role: true, first: delivery_id, last: delivery_id, settled: true, state: :accepted}
            })

            state

          {:error, {:throttled, face}} ->
            {:error, {:resource_limit_exceeded, desc}} = EhThrottle.amqp_refusal(face)
            delivery_id = perf[:delivery_id] || 0

            send_frame(state, link.channel, {
              :disposition,
              %{
                role: true,
                first: delivery_id,
                last: delivery_id,
                settled: true,
                state:
                  {:rejected,
                   %{
                     condition: "amqp:resource-limit-exceeded",
                     description: desc,
                     info: %{"retry-after": face.retry_after_s}
                   }}
              }
            })

            state
        end

      _ ->
        error_close(
          state,
          "amqp:internal-error",
          "transfer on unknown handle #{inspect(perf[:handle])}"
        )
    end
  end

  defp frame_payload(perf) do
    case perf[:__payload__] do
      nil -> perf[:payload] || <<>>
      p -> p
    end
  end

  defp ingest_message(state, link, perf, payload) do
    # Disclosed cross-lane unblock (s5_sessions e2e lane): the SDK maps the
    # Service Bus sessionId to the AMQP properties group-id. Without decoding
    # it here, every send to a requiresSession queue failed
    # :session_required and the link was error-closed (sender "Invalid
    # handle 0" / ServiceTimeout on the SDK side).
    section_list =
      case FrameCodec.decode_message(payload) do
        {:ok, sl} -> sl
        _ -> []
      end

    # Service Bus message batching (census ordered-session probe): the SDK's
    # sendMessages batches N messages into ONE transfer whose payload carries
    # N nested encoded messages as consecutive body_data sections. Extract
    # each inner message and enqueue separately.
    inner_payloads = batched_inner_payloads(section_list)

    result =
      if is_list(inner_payloads) do
        Enum.reduce_while(inner_payloads, {:ok, state}, fn inner, {:ok, st} ->
          case ingest_single_message(st, link, inner, nil, perf) do
            {:ok, st2} -> {:cont, {:ok, st2}}
            err -> {:halt, err}
          end
        end)
      else
        ingest_single_message(state, link, payload, nil, perf)
      end

    case result do
      {:ok, state} ->
        delivery_id = perf[:delivery_id] || 0

        send_frame(state, link.channel, {
          :disposition,
          %{role: true, first: delivery_id, last: delivery_id, settled: true, state: :accepted}
        })

        # KD-COVERS: KD-115 — deliver_available/1 runs only on the :flow path
        # (handle_amqp(:flow,...)), so a receiver whose credit flow precedes
        # the message — streaming/credit-first receivers, a session receiver
        # parked on acceptSession/acceptNextSession — starves forever: the
        # enqueue never re-runs the dispatch. Re-run it on every successful
        # queue enqueue so credited links claim the message immediately.
        state = deliver_available(state)

        state

      {:error, :entity_not_found} ->
        # KD-COVERS: KD-86 — real-SB send-to-missing-entity face: settle the
        # transfer REJECTED with the com.microsoft:entity-not-found condition
        # (link stays alive); never a silent auto-create with the flag off.
        delivery_id = perf[:delivery_id] || 0

        send_frame(state, link.channel, {
          :disposition,
          %{
            role: true,
            first: delivery_id,
            last: delivery_id,
            settled: true,
            state:
              {:rejected,
               %{
                 condition: "com.microsoft:entity-not-found",
                 description: "The messaging entity '#{link.address}' could not be found."
               }}
          }
        })

        state

      {:error, :messaging_entity_not_found} ->
        # KD-COVERS: KD-86 — real Service Bus detaches the SENDER LINK with
        # amqp:not-found and a MessagingEntityNotFound description (the
        # connection stays up, unlike the generic error_close path).
        # BK-65 witness fix: the link must ALSO leave state.links here, or the
        # client's echoing detach finds it still registered and the server
        # re-echoes a second detach — rhea logs ERR_STREAM_WRITE_AFTER_END and
        # the connection dies (witnessed: q2 refusal then same-connection send
        # timed out on put-token; bk65.probe.cjs leg neg-conn-survives).
        send_frame(state, link.channel, {
          :detach,
          %{
            handle: link.handle,
            closed: true,
            error: %{
              condition: "amqp:not-found",
              description:
                "MessagingEntityNotFound: The messaging entity " <>
                  "#{inspect(link.address)} could not be found. Create the entity " <>
                  "before sending, or enable config :smalt, :sb_auto_ensure."
            }
          }
        })

        %{state | links: Map.delete(state.links, {link.channel, link.handle})}

      {:error, :capacity} ->
        # BK-78 / AMQP-spec §2.8.15 — a capacity refusal detaches the SENDER
        # LINK with amqp:link:message-size-exceeded and the CONNECTION
        # SURVIVES (real Service Bus quota/oversize face, same family as the
        # KD-86 amqp:not-found link detach above). The old error_close path
        # killed the whole connection — every later frame on it hit
        # "transfer on unknown handle" -> amqp:internal-error socket close.
        # The link must ALSO leave state.links or the client's echoing detach
        # re-echoes a second detach (BK-65 witness, KD-86).
        send_frame(state, link.channel, {
          :detach,
          %{
            handle: link.handle,
            closed: true,
            error: %{
              condition: "amqp:link:message-size-exceeded",
              description:
                "The entity '#{link.address}' is at capacity (4096 messages); " <>
                  "the sender link was detached (:capacity). The connection remains open."
            }
          }
        })

        %{state | links: Map.delete(state.links, {link.channel, link.handle})}

      {:error, :too_large} ->
        # Same link-detach face as :capacity — an oversized body is the
        # literal amqp:link:message-size-exceeded case (spec §2.8.15).
        send_frame(state, link.channel, {
          :detach,
          %{
            handle: link.handle,
            closed: true,
            error: %{
              condition: "amqp:link:message-size-exceeded",
              description:
                "The message on '#{link.address}' exceeds the maximum body size " <>
                  "(:too_large); the sender link was detached. The connection remains open."
            }
          }
        })

        %{state | links: Map.delete(state.links, {link.channel, link.handle})}

      {:error, reason} ->
        error_close(state, "amqp:internal-error", inspect(reason))
    end
  end

  # {:body_data, raw} sections whose content decodes as a full message = a
  # batched transfer; returns the list of inner payload binaries, or nil if
  # this is an ordinary single-message transfer.
  defp batched_inner_payloads(sections) do
    case Enum.filter(sections, fn {k, _} -> k == :body_data end) do
      [{:body_data, raw} | _] = bodies when length(bodies) > 1 and is_binary(raw) ->
        # sanity: first section must itself decode as a message
        case FrameCodec.decode_message(raw) do
          {:ok, _} -> Enum.map(bodies, fn {:body_data, r} -> r end)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp ingest_single_message(state, link, payload, sections, _perf) do
    sections = sections || decode_message_sections(payload)

    session_id =
      case sections do
        %{properties: %{group_id: gid}} when is_binary(gid) and gid != "" -> gid
        _ -> nil
      end

    # Preserve the body section AS SENT. The previous ingest stored the whole
    # path stored the whole payload; body_data stays body_data;
    # body_amqp_value stays body_amqp_value.
    body_section = extract_body_section(payload)

    message_id =
      case sections do
        %{properties: %{message_id: mid}} when is_binary(mid) -> mid
        _ -> nil
      end

    app_props =
      case sections do
        %{application_properties: ap} when is_map(ap) -> ap
        _ -> %{}
      end

    case QueueStore.enqueue(link.address, body_section,
           session_id: session_id,
           message_id: message_id,
           app_props: app_props
         ) do
      {:ok, _seq} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- $cbs / $management RPC ------------------------------------------------------

  defp handle_cbs(perf, state) do
    # KD-COVERS: KD-132 — a malformed message body (e.g. a map32/map8
    # application-properties section that fails decode) must never raise out of
    # the broker connection process: decode_message_sections/1 answers %{} on a
    # decode failure, so every field access below is normalized against the
    # defaulted section shape and the request falls through to the typed
    # 400 UNSUPPORTED_CBS_REQUEST refusal — the connection survives.
    message =
      %{application_properties: nil, body: nil, properties: %{}}
      |> Map.merge(decode_message_sections(perf.__payload__))

    props = message.application_properties || %{}
    # SDK CBS messages carry the operation in properties.subject
    op = props["operation"] || message.properties[:subject] || message.properties["subject"]
    body = message.body || %{}

    Logger.debug(
      "[amqp-cbs] op=#{inspect(op)} props=#{inspect(props)} body=#{inspect(body)} sections=#{inspect(message)}"
    )

    # SDK form: name/type in application-properties, token string in the body
    request = %{
      operation: op,
      type: props["type"],
      name: props["name"],
      expiration: props["expiration"] || (is_map(body) && body["expiration"]) || nil,
      token: body
    }

    {status, description} =
      case op do
        "put-token" ->
          case safe_put_token(request) do
            {code, desc} = _res when code in [200, 401, 400, 429] and is_integer(code) ->
              Logger.debug("[amqp-cbs] put-token status=#{code} desc=#{desc}")
              res2 = {code, desc}
              res2

            {:ok, {code, desc}} ->
              Logger.debug("[amqp-cbs] put-token status=#{code} desc=#{desc}")
              {code, desc}

            {:error, {code, desc}} ->
              Logger.debug("[amqp-cbs] put-token status=#{code} desc=#{desc}")
              {code, desc}

            other ->
              {500, inspect(other)}
          end

        "delete-token" ->
          {200, "OK"}

        _ ->
          {400, "UNSUPPORTED_CBS_REQUEST"}
      end

    # the SDK matches the reply by the request's correlation_id (falling back
    # to message_id)
    correlation_id =
      message.properties[:correlation_id] || message.properties["correlation_id"] ||
        message.properties[:message_id] || message.properties["message_id"]

    reply_cbs(
      state,
      perf,
      %{"statusCode" => status, "statusDescription" => description},
      correlation_id
    )
  end

  defp safe_put_token(request) do
    ensure_cbs_router()

    if cbs_running?() do
      CbsRouter.put_token(CbsRouter, request, self())
    else
      {200, "LOCAL_SIGNATURE_VERIFIED_NOT_AZURE_AUTHORITY"}
    end
  end

  # the CBS claim cache lives outside the broker supervision tree; start it on
  # first use so SAS verification (and unauthorized-entity) is enforced
  defp ensure_cbs_router do
    # census-run passes the broker key via SMALT_SB_SHARED_KEY; nothing else
    # maps it to the app env, so pin it here before SasVerifier reads it
    # KD-COVERS: KD-131 — this >=32-byte admission guard is the runtime half
    # of the key-floor policy; boot half pinned in scripts/substrate.sh
    # (per-host dev_env derivation), witness fix4-amqp-witness.md
    case Application.get_env(:smalt, :sb_shared_key) do
      nil ->
        case System.get_env("SMALT_SB_SHARED_KEY") do
          key when is_binary(key) and byte_size(key) >= 32 ->
            Application.put_env(:smalt, :sb_shared_key, key)

          _ ->
            :ok
        end

      _ ->
        :ok
    end

    if cbs_running?() do
      :ok
    else
      # unlinked start: a dying connection must not take the shared claim
      # cache down with it
      case GenServer.start(CbsRouter, [], name: CbsRouter) do
        {:ok, _} -> :ok
        {:error, {:already_started, _}} -> :ok
        other -> Logger.warning("[amqp-conn] CbsRouter start failed: #{inspect(other)}")
      end
    end
  end

  defp cbs_running? do
    GenServer.whereis(CbsRouter) != nil
  end

  defp reply_cbs(state, perf, body, correlation_id) do
    link = find_reply_link(state, perf, :cbs, perf[:__channel__] || 0)

    case link do
      nil ->
        Logger.warning("[amqp-conn] no $cbs reply link for reply-to #{inspect(body)}")
        state

      link ->
        {state, _delivery_id} =
          send_message(
            state,
            link,
            %{
              handle: link.handle,
              delivery_tag: <<>>,
              message_format: 0,
              settled: true,
              more: false
            },
            [
              # the SDK correlates via correlation-id and reads the verdict from
              # application-properties "statusCode"/"statusDescription"
              {:properties, %{correlation_id: correlation_id}},
              {:application_properties,
               %{
                 # core-amqp 4.5.1 reads the dotted "status-code"/"status-description"
                 # symbol keys; older paths read "statusCode". Emit both.
                 "status-code" => body["statusCode"],
                 "status-description" => body["statusDescription"],
                 "statusCode" => body["statusCode"],
                 "statusDescription" => body["statusDescription"]
               }},
              {:body_amqp_value, body}
            ]
          )

        state
    end
  end

  defp handle_management(perf, channel, state) do
    message = decode_message_sections(perf.__payload__)
    props = message.application_properties || %{}
    props = normalize_keys(props)

    # core-amqp matches the $management reply by correlation-id; when the
    # request carries no correlation-id (SDK peek/renew requests use only
    # message-id), real Service Bus echoes the message-id as the reply's
    # correlation-id. A null correlation-id makes core-amqp discard the reply
    # ("correlationId undefined ... does not match any request-id") and the
    # request times out (census renewal-peek probe).
    correlation_id =
      message.properties[:correlation_id] || message.properties["correlation_id"] ||
        message.properties[:message_id] || message.properties["message_id"]

    # Real Service Bus resolves the entity for session-scoped management ops
    # (renew-session-lock) from the request's associated-link-name: the SDK
    # sends only {"session-id": ...} in the body, no queue (census finding).
    # Resolve it from the named link this connection owns.
    associated_queue =
      case Map.get(props, "associated-link-name") do
        name when is_binary(name) ->
          Enum.find_value(state.links, fn {_k, link} ->
            if link.name == name, do: link.address
          end)

        _ ->
          nil
      end

    # KD-118: the SDK opens the per-entity management node as
    # "<entity>/$management" (managementClient.js), and sender.scheduleMessages
    # may fire while the queue sender link is still attaching — the
    # associated-link-name resolution above then finds no sender link and the
    # op cannot resolve the entity. The mgmt node's own address names the
    # entity: strip the "/$management" suffix from the receiving mgmt link.
    entity_from_mgmt_node =
      case find_mgmt_node_addr(state.links, perf, channel) do
        addr when is_binary(addr) ->
          case String.replace_suffix(addr, "/$management", "") do
            "" -> nil
            entity -> entity
          end

        _ ->
          nil
      end

    request = %{
      operation: props["operation"],
      # KD-COVERS: KD-19 — Event Hubs READ management ops carry type/name/partition as
      # application properties (managementClient.js sends body = JSON "[]" —
      # the entity name is NOT in the body).
      type: props["type"],
      name: props["name"],
      partition: props["partition"],
      body: message.body,
      queue: associated_queue || entity_from_mgmt_node,
      correlation_id: correlation_id
    }

    result = ManagementRpc.handle(request, %{conn_pid: self()})

    status = result.status_code

    # KD-77 residual (2026-10-16): a nil op body previously merged the
    # statusCode/statusDescription map into the amqp-value BODY; the Python
    # SDK's mgmt default handler returns message.value, so every 200 carried
    # a spurious body map and mgmt_handlers.default could not read "no
    # content". Real Azure puts the status in application-properties (already
    # emitted below) and leaves the 200 body EMPTY. # KD-COVERS: KD-77
    body =
      case result.body do
        nil ->
          nil

        body ->
          body
          |> normalize_mgmt_bodies()
          |> then(
            &Map.merge(
              %{"statusCode" => status, "statusDescription" => result.status_description},
              stringify_map(&1)
            )
          )
      end

    status_code_for_props = if is_map(body), do: body["statusCode"], else: status

    status_desc_for_props =
      if is_map(body), do: body["statusDescription"], else: result.status_description

    reply_management(state, perf, body, request.correlation_id, channel,
      status_code: status_code_for_props,
      status_description: status_desc_for_props
    )
  end

  defp reply_management(state, perf, body, correlation_id, channel, opts) do
    status_code = opts[:status_code] || body["statusCode"]
    status_desc = opts[:status_description] || body["statusDescription"]
    link = find_reply_link(state, perf, :management, channel)

    case link do
      nil ->
        Logger.warning("[amqp-conn] no $management reply link")
        state

      link ->
        {state, _delivery_id} =
          send_message(
            state,
            link,
            %{
              handle: link.handle,
              delivery_tag: <<>>,
              message_format: 0,
              settled: true,
              more: false
            },
            [
              {:properties, %{correlation_id: correlation_id}},
              {:application_properties,
               %{
                 # core-amqp 4.5.1 reads the dotted "status-code"/"status-description"
                 # symbol keys; older paths read "statusCode". Emit both.
                 "status-code" => status_code,
                 "status-description" => status_desc,
                 "statusCode" => status_code,
                 "statusDescription" => status_desc
               }},
              {:body_amqp_value, body}
            ]
          )

        state
    end
  end

  defp find_reply_link(state, perf, kind, req_channel) do
    # KD-COVERS: KD-132 — same normalization as handle_cbs: a decode failure
    # answers %{} (no :application_properties key), and Map.get/3 keeps the
    # reply-link lookup from raising on a malformed request body.
    payload_props = Map.get(decode_message_sections(perf.__payload__), :application_properties, nil) || %{}
    reply_to = normalize_keys(payload_props)["reply-to"]

    links = Map.values(state.links)

    # 1. exact reply-to link name (protocol answer)
    # 2. the management SENDER paired on the SAME channel as the request's
    #    receiver — the SDK opens a receiver/sender pair per $management
    #    entity. The old fallback ("first mgmt sender in the map") answered on
    #    an EARLIER probe's detached link and rhea discarded every reply after
    #    the first probe ended (census full-run: renewal-peek and everything
    #    after timed out with the broker logging 200 replies).
    Enum.find(links, fn link -> reply_to != nil and link.name == reply_to end) ||
      Enum.find(links, fn link ->
        link.kind == kind and link.role == :sender and link.channel == req_channel
      end) ||
      Enum.find(links, fn link -> link.kind == kind and link.role == :sender end)
  end

  # KD-118: the receiving $management link for this transfer — matched on
  # (channel, handle, role, kind) so a co-attached per-entity mgmt node for a
  # DIFFERENT entity never answers. Address form "<entity>/$management"
  # (bare "$management" returns itself; the strip-side nils it).
  defp find_mgmt_node_addr(links, perf, channel) do
    Enum.find_value(links, fn {_k, l} ->
      if l[:kind] == :management and l[:role] == :receiver and l[:channel] == channel and
           l[:handle] == perf.handle do
        l[:address]
      end
    end)
  end

  # Stored bodies are tagged AMQP body sections ({:body_data, bin} /
  # {:body_amqp_value, v}). The $management peek reply embeds them as the
  # "message" value inside an amqp-value body; PrimitiveCodec has no clause
  # for those tuples, so encoding the reply raised ArgumentError and the
  # connection GenServer crashed — no reply, 8s SDK timeout (census
  # renewal-peek probe). Re-emit the stored section bytes verbatim.
  defp normalize_mgmt_bodies(%{"messages" => messages} = body) when is_list(messages) do
    Map.put(body, "messages", Enum.map(messages, &normalize_mgmt_message/1))
  end

  defp normalize_mgmt_bodies(body), do: body

  # The peek reply's "message" field must be an AMQP binary (vbin) of the raw
  # message sections. rhea decodes vbin as a Buffer and
  # ManagementClient.peekBySequenceNumber re-decodes it with
  # rhea-promise message.decode, deriving sequenceNumber from the
  # message-annotations x-opt-sequence-number (_lastPeekedSequenceNumber,
  # managementClient.js:315). Without the annotation the SDK crashes
  # undefined.add on the next peek (census renewal-peek probe).
  defp normalize_mgmt_message(%{"message" => body_section} = msg) do
    annotations =
      case msg do
        %{"sequence-number" => seq} when is_integer(seq) ->
          %{"x-opt-sequence-number" => embedded_seq(msg)}

        _ ->
          %{}
      end

    sections =
      if(annotations == %{}, do: [], else: [{:message_annotations, annotations}]) ++
        maybe_delivery_count_section(msg) ++
        maybe_properties_section(msg) ++
        [body_section_to_section(body_section)]

    Map.put(msg, "message", {:vbin, FrameCodec.encode_message(sections) |> IO.iodata_to_binary()})
  end

  # Kept grouped with the clause above (warnings-as-errors fence: an
  # ungrouped same-name/arity clause pair warns on every recompile).
  defp normalize_mgmt_message(other), do: other

  # R178e (census deferred-receive): the 7.10.0 SDK reads deliveryCount from
  # the decoded message HEADER section (managementClient.js builds
  # ServiceBusMessageImpl with rheaMessage.delivery_count). Emit it when the
  # management handler supplied one.
  # KD-COVERS: KD-46
  defp maybe_delivery_count_section(%{"delivery-count" => dc}) when is_integer(dc) and dc >= 0,
    do: [{:header, %{delivery_count: dc}}]

  defp maybe_delivery_count_section(_), do: []

  # The receive-by-sequence reply carries its own explicit sequence number;
  # prefer it over a peek-order index.
  defp embedded_seq(%{"sequence-number" => seq}) when is_integer(seq), do: seq
  defp embedded_seq(_), do: nil

  defp maybe_properties_section(%{"message-id" => mid}) when is_binary(mid),
    do: [{:properties, %{message_id: mid}}]

  defp maybe_properties_section(_), do: []

  defp body_section_to_section({:body_data, data}) when is_binary(data),
    do: {:body_data, data}

  defp body_section_to_section({:body_amqp_value, value}),
    do: {:body_amqp_value, value}

  defp body_section_to_section({:body_sequence, seqs}) when is_list(seqs),
    do: {:body_sequence, seqs}

  defp body_section_to_section(data) when is_binary(data),
    do: {:body_data, data}

  defp body_section_to_section(other), do: other

  defp decode_message_sections(payload) when is_binary(payload) do
    case FrameCodec.decode_message(payload) do
      {:ok, sections} -> sections_to_message(sections)
      # mechanical warning fix (store+graphlaw lane): catch-all — the compiler
      # types decode_message/1 as {:ok, _} only; runtime path preserved.
      _other -> %{}
    end
  end

  defp decode_message_sections(_), do: %{}

  defp sections_to_message(sections) do
    Enum.reduce(sections, %{application_properties: nil, body: nil, properties: %{}}, fn
      {:application_properties, map}, acc -> Map.put(acc, :application_properties, map)
      {:properties, map}, acc -> Map.put(acc, :properties, map || %{})
      {:body_amqp_value, value}, acc -> Map.put(acc, :body, value)
      {:body_data, value}, acc -> Map.put(acc, :body, value)
      _, acc -> acc
    end)
  end

  # --- delivery ------------------------------------------------------------------

  defp deliver_available(state) do
    state.links
    |> Map.values()
    |> Enum.filter(fn link ->
      link.role == :sender and link.kind in [:queue, :eventhubs] and link.credit > 0
    end)
    |> Enum.reduce(state, &deliver_link_reducer/2)
  end

  defp deliver_link_reducer(link, st) do
    if link.kind == :eventhubs, do: deliver_eventhubs(st, link), else: deliver_to_link(st, link)
  end

  defp deliver_eventhubs(state, link) do
    # KD-COVERS: KD-76 — a HUB-address receiver link has no /partitions
    # tail; real service semantics there are "see every partition's
    # events", so the aggregate path merges the hub's partitions.
    # r200h repair: classification is case-insensitive and STRUCTURALLY
    # exact (a `{partitions}/{n}` tail), not a lowercase substring probe —
    # the real @azure/event-hubs SDK attaches partition consumers at
    # `{hub}/ConsumerGroups/$Default/Partitions/{n}` (capital P), which the
    # substring probe misrouted onto the aggregate path (zero events to
    # partition-scoped receivers).
    case eh_partition_scope(link.address) do
      {hub, p} -> deliver_eventhubs_partition(state, link, "#{hub}/partitions/#{p}")
      nil -> deliver_eventhubs_aggregate(state, link, eh_partition(link.address))
    end
  end

  # HUB-address receiver: aggregate the pinned partition set ["0","1"] plus
  # the legacy bare-hub key (pre-KD-76 unkeyed hub sends still park there, so
  # they stay visible). Cursors are LINK-LOCAL per source partition
  # (`eh_agg_cursors`) — the shared per-partition `eh_cursors` belong to the
  # partition-scoped links, and a hub link draining after a partition link
  # must not inherit their position (independent consumers, real-service
  # semantics).
  defp deliver_eventhubs_aggregate(state, link, hub) do
    sources = for p <- ["0", "1"], do: "#{hub}/partitions/#{p}"
    sources = sources ++ [hub]
    agg_cursors = Map.get(link, :eh_agg_cursors) || %{}

    {tagged, _st} =
      Enum.flat_map_reduce(sources, state, fn src, st ->
        after_seq =
          Map.get(agg_cursors, src, 0) |> max(link.eh_start || 0)

        events =
          src
          |> EventHubs.receive_events(after_seq, link.credit)
          |> Enum.map(&Map.put(&1, "__src", src))

        {events, st}
      end)

    tagged
    |> Enum.sort_by(&{&1["enqueued"] || 0, &1["seq"]})
    |> Enum.take(link.credit)
    |> Enum.reduce(state, fn ev, st ->
      src = ev["__src"]
      seq = ev["seq"]
      body = ev["body"]

      sections = [
        {:message_annotations, eh_event_annotations(ev)}
        | eh_delivery_annotations(src) ++ [eh_body_section(body)]
      ]

      {st, _id} =
        send_message(
          st,
          link,
          %{
            handle: link.handle,
            delivery_tag: <<seq::unsigned-64>>,
            message_format: 0
          },
          sections
        )

      st
      |> then(&bump_credit(&1, link.channel, link.handle, -1))
      |> then(fn st2 ->
        link2 = st2.links[{link.channel, link.handle}]
        agg = Map.put(Map.get(link2, :eh_agg_cursors) || %{}, src, seq)

        # lane283 compile-freeze unblock (disclosed): Map.put, not update
        # syntax — link maps are not guaranteed to pre-carry these keys.
        put_link(
          st2,
          link2
          |> Map.put(:eh_link_cursor, seq)
          |> Map.put(:eh_agg_cursors, agg)
        )
      end)
    end)
  end

  # r200h (KD-76 repair): structural, case-insensitive partition-tail
  # classifier. Returns {hub, partition} when the address ends in a
  # partitions segment + partition id (any of the wire shapes below);
  # nil means entity-level (hub) address -> aggregate delivery path.
  defp eh_partition_scope(address) when is_binary(address) do
    segs = address |> String.split("/") |> Enum.reject(&(&1 == ""))

    case segs do
      # legacy emulator form: /eventhubs/{hub}/partitions/{n}
      ["eventhubs", hub, ptail, p] -> eh_scope(hub, ptail, p)
      # {hub}/Partitions/{n}
      [hub, ptail, p] -> eh_scope(hub, ptail, p)
      # {hub}/ConsumerGroups/{cg}/Partitions/{n} (real @azure/event-hubs SDK form)
      [hub, "ConsumerGroups", _cg, ptail, p] -> eh_scope(hub, ptail, p)
      # /eventhubs/{hub}/ConsumerGroups/{cg}/Partitions/{n}
      ["eventhubs", hub, "ConsumerGroups", _cg, ptail, p] -> eh_scope(hub, ptail, p)
      _ -> nil
    end
  end

  defp eh_scope(hub, ptail, p) do
    # EH fixed-partition pinion: only the pinned partitions ["0","1"] exist.
    # A partition-scoped attach outside the pin is refused — the send side
    # already pins storage to the pair (eh_pk_partition rem 2), so accepting
    # "2" would silently attach a receiver that can never be delivered to.
    # Hub-scoped and non-partition tails stay nil (aggregate path).
    cond do
      String.downcase(ptail) == "partitions" and p != "" and p in ["0", "1"] -> {hub, p}
      String.downcase(ptail) == "partitions" and p != "" -> :refused
      true -> nil
    end
  end

  # KD-COVERS: KD-76 — storage partition for an inbound EH transfer. A
  # pk-stamped event sent on a hub-address (no /partitions) sender link is
  # routed to ONE partition of the pinned set ["0","1"] by a deterministic
  # hash of the key (real service: consistent hashing over the entity's
  # partitions); the x-opt-partition-key annotation still rides the stored
  # event. Partition-scoped or unkeyed sends keep the previous key.
  defp eh_storage_partition(partition, pk, address) do
    case eh_partition_scope(address) do
      {hub, p} ->
        # r200h: partition-scoped sender (any casing of the partitions
        # segment) stores under the canonical lowercase key, so a
        # {hub}/Partitions/{n} or .../ConsumerGroups/.../Partitions/{n}
        # sender and receiver meet at the same storage partition.
        "#{hub}/partitions/#{p}"

      nil when pk != nil ->
        # `partition` for a hub address is the bare hub name (eh_partition
        # strips the /eventhubs/ prefix). KD-COVERS: KD-76 — pk routing.
        "#{partition}/partitions/#{eh_pk_partition(pk)}"

      nil ->
        partition
    end
  end

  defp eh_pk_partition(pk) do
    bin = if is_binary(pk), do: pk, else: :erlang.term_to_binary(pk)
    <<first::unsigned-8, _::binary>> = :erlang.md5(bin)
    Integer.to_string(rem(first, 2))
  end

  defp deliver_eventhubs_partition(state, link, partition) do
    global = get_in(state, [:eh_cursors, partition]) || 0

    # GAP-A2-01 (KD-68): the link's eventPosition start cursor (selector
    # filter) floors the global cursor, and a link-local cursor keeps a
    # filtered link from being pushed backward by other links on the same
    # partition.
    after_seq =
      global
      |> max(link.eh_start || 0)
      |> max(link.eh_link_cursor || 0)

    # V261014-04 F1: `receive_events/3` returns a BARE list (its @spec and the
    # public contract consumed by c7_events.exs + reconcile callers), so a
    # `{:ok, events}` match on {:ok, events} could never succeed. Match the
    # bare-list shape; an empty list (or any other shape) falls through closed.

    case EventHubs.receive_events(partition, after_seq, link.credit) do
      [_ | _] = events ->
        # GAP-A2-01: enqueuedTime eventPosition filters on the event's
        # enqueued timestamp (epoch ms), exclusive like the real service.
        events =
          case link.eh_min_enqueued do
            nil -> events
            floor -> Enum.filter(events, fn ev -> (ev["enqueued"] || 0) > floor end)
          end

        Enum.reduce(events, state, fn ev, st ->
          seq = ev["seq"]
          body = ev["body"]

          sections =
            [
              # GAP-A2-04: x-opt-offset / x-opt-enqueued-time /
              # x-opt-partition-key surface on every delivery; the SDK's
              # fromRheaMessage maps them to event.offset / enqueuedTimeUtc /
              # partitionKey. x-opt-sequence-number is pre-existing.
              {:message_annotations, eh_event_annotations(ev)}
              | eh_delivery_annotations(partition) ++ [eh_body_section(body)]
            ]

          {st, _id} =
            send_message(
              st,
              link,
              %{
                handle: link.handle,
                delivery_tag: <<seq::unsigned-64>>,
                # KD-COVERS: KD-18,KD-20 — format 0 = standard decoded-message
                # path (SB path below). Keep consistent on EVERY EH arm; the
                # credit bump below closes KD-20.
                message_format: 0
              },
              sections
            )

          # SHIM-COURT R13/V261014-04-F1 fix: re-read the link refreshed by
          # bump_credit (deliver_to_link pattern) — the outer `link`'s credit
          # was never decremented, so put_link used to restore stale credit
          # and the :1389 guard kept draining past the grant (over-delivery).
          st
          |> Map.update!(:eh_cursors, fn m -> Map.put(m || %{}, partition, seq) end)
          |> then(&bump_credit(&1, link.channel, link.handle, -1))
          |> then(fn st2 ->
            put_link(st2, %{st2.links[{link.channel, link.handle}] | eh_link_cursor: seq})
          end)
        end)

      _ ->
        state
    end
  end

  # KD-COVERS: KD-68 — partition identity is scoped by the EH entity (hub),
  # not the bare partition label: real Event Hubs sequence spaces are
  # per-hub, and last-segment-only keying routed every hub's events into one
  # shared row (R69: selector-filter exact-sequence courts could not hold).
  defp eh_partition(address) when is_binary(address) do
    case String.split(address, "/eventhubs/") do
      [_, rest] -> String.replace_leading(rest, "/", "")
      _ -> address |> String.split("/") |> List.last()
    end
  end

  # GAP-A2-04: per-event x-opt-* stamps. SDK contract (core-amqp
  # constants.js:5-10 + event-hubs eventData.js fromRheaMessage switch):
  # x-opt-offset -> event.offset (string, required on ReceivedEventData),
  # x-opt-enqueued-time -> event.enqueuedTimeUtc (AMQP timestamp ms),
  # x-opt-partition-key -> event.partitionKey (only when the sender set one).
  # KD-COVERS: KD-71
  defp eh_event_annotations(ev) when is_map(ev) do
    %{
      "x-opt-sequence-number" => ev["seq"],
      "x-opt-offset" => ev["offset"],
      "x-opt-enqueued-time" => {:timestamp, ev["enqueued"]}
    }
    |> maybe_put_eh("x-opt-partition-key", ev["partition_key"])
  end

  defp maybe_put_eh(map, _k, nil), do: map
  defp maybe_put_eh(map, k, v), do: Map.put(map, k, v)

  # GAP-A2-03: EH delivery annotations carry the partition's last_enqueued_*
  # truth (eventData.js: `msg.delivery_annotations.last_enqueued_offset` /
  # `.last_enqueued_sequence_number` / `.last_enqueued_time_utc`). Offset is a
  # STRING on the wire, sequence a ulong, time an AMQP timestamp. `:none`
  # (empty partition) -> no delivery-annotations section; rhea tolerates a
  # missing section.
  # KD-COVERS: KD-70
  defp eh_delivery_annotations(partition) do
    case EventHubs.last_enqueued(partition) do
      :none ->
        []

      %{"offset" => offset, "seq" => seq, "enqueued" => enqueued} ->
        [
          {:delivery_annotations,
           %{
             "last_enqueued_offset" => offset,
             "last_enqueued_sequence_number" => seq,
             "last_enqueued_time_utc" => {:timestamp, enqueued}
           }}
        ]
    end
  end

  # GAP-A2-04 capture side: the producer stamps x-opt-partition-key as a
  # message annotation. On a single-event transfer it sits on the message
  # itself; on a KD-53 producer createBatch the envelope carries NO
  # annotations — @azure/event-hubs stamps x-opt-partition-key on EACH INNER
  # event message (eventDataBatch.js _encodeMessage -> toRheaMessage), and the
  # KD-53 split-at-ingest stores those inners, so the capture must scan the
  # envelope, then fall back into the batch body's inner messages. Anything
  # undecodable reads as nil (no key) — the transfer still enqueues.
  defp eh_sender_partition_key(payload) when is_binary(payload) do
    with {:ok, sections} when is_list(sections) <- FrameCodec.decode_message(payload),
         nil <- eh_find_partition_key(sections) do
      r = eh_inner_partition_key(sections)
      r
    else
      pk when pk != nil -> pk
    end
  end

  defp eh_find_partition_key(sections) do
    Enum.find_value(sections, fn
      {:message_annotations, anns} when is_map(anns) -> anns["x-opt-partition-key"]
      _ -> nil
    end)
  end

  # Scan the batch body's concatenated inner messages for the first
  # x-opt-partition-key message annotation. Falls back closed to nil.
  defp eh_inner_partition_key(sections) do
    data =
      sections
      |> Enum.filter(fn
        {:body_data, b} when is_binary(b) -> true
        _ -> false
      end)
      |> Enum.map(fn {:body_data, b} -> b end)
      |> IO.iodata_to_binary()

    with {:ok, inner_sections} when is_list(inner_sections) <- FrameCodec.decode_message(data) do
      Enum.find_value(inner_sections, fn
        {:message_annotations, anns} when is_map(anns) -> anns["x-opt-partition-key"]
        _ -> nil
      end)
    else
      _ -> nil
    end
  end

  # KD-18: stored EH bodies are raw client transfer payloads. The producer
  # path stores the SDK's BATCH ENVELOPE message (header / message-annotations
  # / properties / body_data), and the batch body itself is ANOTHER encoded
  # message stream, so unwrap body sections recursively until the payload is
  # no longer a section stream. Body sections are located by header bytes:
  # described(0x00 0x53 0x75 body-data, vbin8/vbin32) — FrameCodec
  # .decode_message/1 is all-or-nothing, so a raw byte scan is used. Falls
  # back closed to the whole payload when no body section is present.
  # KD-COVERS: KD-18
  defp eh_body_section(payload) when is_binary(payload) do
    case eh_body_section_scan(payload) do
      {:ok, section} -> eh_body_section(section)
      :error -> {:body_data, payload}
    end
  end

  defp eh_body_section_scan(payload) do
    case :binary.match(payload, <<0x00, 0x53, 0x75>>) do
      {pos, _} ->
        rest = binary_part(payload, pos, byte_size(payload) - pos)

        case rest do
          <<0x00, 0x53, 0x75, 0xA0, len, body::binary-size(len), _::binary>> ->
            {:ok, body}

          <<0x00, 0x53, 0x75, 0xB0, len::32, body::binary-size(len), _::binary>> ->
            {:ok, body}

          _ ->
            {:ok, binary_part(payload, pos, byte_size(payload) - pos)}
        end

      :nomatch ->
        :error
    end
  end

  defp deliver_to_link(state, link) do
    case QueueStore.dequeue_matching(link.address, session_id: link.session_id) do
      {:ok, msg, lock} ->
        # KD-COVERS: KD-134 — requester-preference on redelivery: if THIS
        # link already holds an unsettled delivery of the dequeued message
        # and another credited non-holder link for the same queue+session
        # exists, yield: release the just-acquired lock so the requesting
        # receiver takes the re-availed message instead of the idle first
        # holder (W21-B: rx2 starved while idle rx1 re-took the transfer).
        # The release is a real settlement transition (delivery_count
        # increments once per yielded claim — real Service Bus also counts
        # each attempted delivery). No recursion after a yield.
        if kd134_yield_to_requester?(state, link, msg) do
          QueueStore.release(msg.queue, msg.seq, lock_token: lock.lock_token)

          Logger.debug(
            "[amqp-conn] KD-134 yield: " <>
              "seq=#{msg.seq} held by ch=#{link.channel} h=#{link.handle}, credited requester exists"
          )

          state
        else
          deliver_to_link_claimed(state, link, msg, lock)
        end

      :empty ->
        state

      {:error, _} ->
        state
    end
  end

  defp deliver_to_link_claimed(state, link, msg, lock) do
    sections = delivery_sections(msg)

        delivery_result =
          try do
            send_message(
              state,
              link,
              %{
                handle: link.handle,
                # AMQP delivery-tag = lock token, .NET GUID byte layout (see
                # LockManager.token_to_wire/1 doc: the SDK reorders the bytes
                # back before uuid_to_string). Straight uuid layout made every
                # client echo a permuted token on update-disposition → 410
                # MESSAGE_LOCK_LOST (census session probes).
                delivery_tag: Smalt.Amqp.LockManager.token_to_wire(lock.lock_token),
                message_format: 0,
                settled: false,
                more: false
              },
              sections
            )
          rescue
            # Store-and-forward lock leak (lens-4 cycle-3): dequeue_matching
            # acquires the message lock BEFORE the encode+send; an encode
            # raise here used to leave the message locked forever with no
            # release/deadletter decision. Release it back and close typed.
            e in ArgumentError ->
              # SHIM-COURT: encode failure must end delivery on this link.
              # Release the store lock, close typed, and DO NOT fall through
              # to the success tail — the old fall-through registered a bogus
              # delivery id 0, decremented credit and re-entered deliver_to_link
              # while credit remained, re-dequeuing and re-locking the message
              # just released (lock flapping after the close frame was already
              # on the wire; delivery_count inflated one per credit).
              QueueStore.release(msg.queue, msg.seq)

              Logger.error(
                "[amqp-conn] delivery encode failed, lock released: " <> Exception.message(e)
              )

              error_close(state, "amqp:internal-error", "DELIVERY_ENCODE_FAILED")

              {:halt_delivery, state}
          end

        # SHIM-COURT: encode-failure arm halts — no delivery registration, no
        # credit bump, no re-dequeue on this link.
        case delivery_result do
          {:halt_delivery, halted_state} ->
            halted_state

          {state, delivery_id} ->
            state = %{
              state
              | # SHIM-COURT: entries carry their AMQP session channel so a
                # session :end can retire them; otherwise a re-begin restarts
                # next_out at 0 and a disposition can settle a stale delivery.
                outbound_deliveries:
                  Map.put(state.outbound_deliveries, delivery_id, %{
                    queue: msg.queue,
                    seq: msg.seq,
                    lock_token: lock.lock_token,
                    channel: link.channel
                  }),
                # KD-COVERS: KD-134 — remember the delivering link so a
                # re-availed (expired/released) lock prefers a DIFFERENT
                # credited requester over the idle first holder.
                redelivery_holders:
                  Map.update(
                    Map.get(state, :redelivery_holders) || %{},
                    {msg.queue, msg.seq},
                    MapSet.new([{link.channel, link.handle}]),
                    &MapSet.put(&1, {link.channel, link.handle})
                  )
            }

            state = bump_credit(state, link.channel, link.handle, -1)

            if state.links[{link.channel, link.handle}][:credit] > 0 do
              deliver_to_link(state, Map.get(state.links, {link.channel, link.handle}))
            else
              state
            end
        end
  end

  # KD-COVERS: KD-134 — requester-preference predicate: the dequeued
  # message is a REDelivery this link already holds unsettled AND a credited
  # non-holder link exists on the same queue + session filter. Fall back to
  # any credited link when this holder is the only credited receiver (the
  # fallback half of the law: single-receiver redelivery is unaffected).
  defp kd134_yield_to_requester?(state, link, msg) do
    holders = Map.get(state, :redelivery_holders) || %{}
    key = {link.channel, link.handle}

    case Map.get(holders, {msg.queue, msg.seq}) do
      nil ->
        false

      seen ->
        MapSet.member?(seen, key) and
          Enum.any?(state.links, fn {_k, l} ->
            l.role == :sender and l[:kind] == :queue and l.address == link.address and
              l[:session_id] == link.session_id and
              Map.get(l, :credit, 0) > 0 and {l.channel, l.handle} != key and
              not MapSet.member?(seen, {l.channel, l.handle})
          end)
    end
  end

  defp delivery_sections(msg) do
    delivery_sections_build(msg)
  end

  defp delivery_sections_build(msg) do
    sections =
      DeliveryEncoder.build_sections(
        sequence_number: msg.seq,
        locked_until: msg[:locked_until],
        enqueued_time: msg[:enqueued],
        session_id: msg[:session_id],
        delivery_count: msg.delivery_count,
        message_id: msg[:message_id],
        app_props: msg[:app_props] || %{}
      )

    base =
      [
        {:header, sections[:header]},
        {:message_annotations, sections[:message_annotations]},
        {:properties, sections[:properties]},
        {:application_properties, sections[:application_properties]}
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    base ++ [stored_body_section(msg.body)]
  end

  # The stored body is a tagged section {:body_data, v} / {:body_amqp_value, v}
  # (as-sent preservation, this change); fall back to a body_data wrap for
  # legacy rows and the EventHubs store path (raw binary bodies).
  defp stored_body_section({kind, value}) when kind in [:body_data, :body_amqp_value],
    do: {kind, value}

  defp stored_body_section(value), do: {:body_data, value}

  # First body section of the enqueued payload, tagged with its section kind.
  defp extract_body_section(payload) when is_binary(payload) do
    case FrameCodec.decode_message(payload) do
      {:ok, sections} ->
        Enum.find(sections, fn
          {kind, _} when kind in [:body_data, :body_amqp_value] -> true
          _ -> false
        end)
        |> case do
          {kind, value} when kind in [:body_data, :body_amqp_value] -> {kind, value}
          _ -> {:body_data, payload}
        end

      _other ->
        {:body_data, payload}
    end
  end

  defp extract_body_section(_), do: {:body_data, <<>>}

  # --- disposition settlement -------------------------------------------------------

  @disposition_range_cap 10_000

  defp handle_disposition(perf, channel, state) do
    first = perf[:first]
    last = perf[:last] || first
    action = delivery_action(perf[:state])

    if is_integer(first) and is_integer(last) and last >= first do
      # range-bomb clamp (R3 red-team finding): a disposition spanning
      # first=1..last=100_000_000 must not build a huge reduce range; real
      # settlement windows are bounded by the session window.
      last = min(last, first + @disposition_range_cap)

      {state, matched_any, lock_lost_ids} =
        Enum.reduce(first..last, {state, false, []}, fn delivery_id, {st, matched, lost} ->
          case Map.get(st.outbound_deliveries, delivery_id) do
            nil ->
              {st, matched, lost}

            dlv ->
              # R196: the delivery's lock token rides the settle as a
              # compare-and-settle against the store's CURRENT token — a
              # stale/zombie disposition refuses typed :lock_lost and the
              # message is left untouched for its new owner.
              case settle(action, dlv, perf[:state]) do
                :ok ->
                  {st
                   |> Map.put(:outbound_deliveries, Map.delete(st.outbound_deliveries, delivery_id))
                   |> Map.put(
                     :redelivery_holders,
                     Map.delete(Map.get(st, :redelivery_holders) || %{}, {dlv.queue, dlv.seq})
                   ), true, lost}

                :lock_lost ->
                  {st, matched, [delivery_id | lost]}
              end
          end
        end)

      # R196: a refused disposition must not be echoed as accepted (the client
      # would believe a settle happened that didn't). Answer the refused ids
      # with a 410-class rejected disposition carrying
      # com.microsoft:message-lock-lost — the wire twin of management paths'
      # 410 MESSAGE_LOCK_LOST.
      Enum.each(lock_lost_ids, fn delivery_id ->
        send_frame(state, channel, {
          :disposition,
          %{
            role: false,
            first: delivery_id,
            last: delivery_id,
            settled: true,
            state:
              {:rejected,
               %{
                 condition: "com.microsoft:message-lock-lost",
                 description: "The lock token is no longer valid; the message was not settled"
               }}
          }
        })
      end)

      # Receiver-initiated settlement (SDK peekLock receivers settle with
      # settled=false and rcv-settle-mode=first): the sender endpoint MUST
      # echo the terminal disposition or the client's complete/abandon
      # hangs forever ("Operation to settle the message has timed out").
      # If the client already settled on the wire (settled=true), no echo.
      if matched_any and lock_lost_ids == [] and not perf[:settled] do
        # pyamqp dialect (S-1, disclosed in s1-amqp-shims receipt): pyamqp
        # reads the echo's terminal outcome state, so echo the client's own
        # state back — a bare settled-only echo reads as outcome None and
        # every complete/abandon fails ("Expected 'accepted' but the
        # reported outcome was: None").
        # decoded :modified carries the positional fields LIST; the encoder
        # wants the map form. Rebuild the wire-described state instead of
        # round-tripping the internal shape.
        # KD-77 residual (2026-10-16): decoded :rejected ALSO carries the
        # positional LIST; re-encoding it verbatim put the whole list in the
        # error-condition slot, pyamqp decoded condition as a DescribedList
        # and crashed (AttributeError 'DescribedList' has no 'decode') ->
        # RuntimeError -> mgmt-link fallback -> spurious 410 against a
        # message the receiver-link dead-letter had ALREADY settled.
        # A successful dead-letter echoes rejected with NO error (real
        # Service Bus: check_disposition_outcome treats error-bearing
        # rejected as failure). # KD-COVERS: KD-77
        echo_state =
          case perf[:state] do
            {:modified, fields} when is_list(fields) ->
              {:modified,
               %{
                 delivery_failed: Enum.at(fields, 0),
                 undeliverable_here: Enum.at(fields, 1),
                 annotations: Enum.at(fields, 2)
               }}

            {:rejected, fields} when is_list(fields) ->
              {:rejected, %{condition: nil, description: nil, info: nil}}

            other ->
              other
          end

        send_frame(state, channel, {
          :disposition,
          %{role: false, first: first, last: last, settled: true, state: echo_state}
        })
      end

      state
    else
      state
    end
  end

  defp delivery_action(:accepted), do: :complete
  defp delivery_action(:released), do: :release
  defp delivery_action({:modified, body}), do: modified_action(body)
  defp delivery_action({:rejected, _error}), do: :deadletter
  defp delivery_action(_), do: :release

  defp modified_action(body) when is_list(body) do
    if Enum.at(body, 1) == true, do: :defer, else: :release
  end

  defp modified_action(%{} = m) do
    if m[:undeliverable_here] == true or m["undeliverable-here"] == true,
      do: :defer,
      else: :release
  end

  defp modified_action(_), do: :release

  # AMQP map keys may decode as raw binaries or {:symbol, bin} tuples; look
  # up both spellings without minting atoms from wire input.
  defp key_bin(info, name, alt) do
    info[name] || info[alt] || info[{:symbol, name}] || info[{:symbol, alt}]
  end

  # R196: every settle rides the disposition's captured delivery token
  # (outbound_deliveries) as a server-side compare-and-settle
  # (QueueStore settle_token_ok?/2). A stale token (lock expired+re-claimed,
  # swept, or released) refuses typed :lock_lost — the caller answers the
  # client 410-class and the message is untouched. The prior client-side
  # LockManager.expired? gate is subsumed: the CAS checks the row's CURRENT
  # stored token, and an expired lock whose token was already swept deletes
  # the row → token mismatch → :lock_lost.
  # KD-77 residual fix (2026-10-16): receiver-link dead-letter carries its
  # reason/description in the rejected outcome's error info map
  # (com.microsoft:dead-letter-reason / -error-description); dropping them
  # made every DLQ message surface dead_letter_reason "rejected"
  # (test_dead_letter_with_properties, unblocked by the r210 fixes).
  defp settle(:deadletter, dlv, {:rejected, fields}) when is_list(fields) do
    {reason, desc} =
      case Enum.at(fields, 0) do
        # error = described(0x1d) [condition, description, info-map]
        {:described, _desc, err_fields} when is_list(err_fields) ->
          case Enum.at(err_fields, 2) do
            info when is_map(info) ->
              # info-map keys arrive as raw binaries or {:symbol, bin} —
              # never mint atoms from wire input (safe_atom law). Python
              # pyamqp dialect: "DeadLetterReason"/"DeadLetterErrorDescription"
              # (constants.py:94-95); also honor com.microsoft-prefixed forms.
              kr = key_bin(info, "DeadLetterReason", "com.microsoft:dead-letter-reason")

              kd =
                key_bin(
                  info,
                  "DeadLetterErrorDescription",
                  "com.microsoft:dead-letter-error-description"
                )

              {kr || "rejected", kd}

            _ ->
              {"rejected", nil}
          end

        _ ->
          {"rejected", nil}
      end

    case QueueStore.deadletter(dlv.queue, dlv.seq, reason, desc, lock_token: dlv.lock_token) do
      {:ok, _dlq_seq} -> :ok
      {:error, :lock_lost} -> :lock_lost
      {:error, _other} -> :ok
    end
  end

  defp settle(:complete, dlv, _state) do
    case QueueStore.complete(dlv.queue, dlv.seq, lock_token: dlv.lock_token) do
      :ok -> :ok
      {:error, :lock_lost} -> :lock_lost
    end
  end

  defp settle(:release, dlv, _state) do
    case QueueStore.release(dlv.queue, dlv.seq, lock_token: dlv.lock_token) do
      :ok -> :ok
      {:error, :lock_lost} -> :lock_lost
      # R64/R128 conditions are store-level, not token conditions: the settle
      # happened as far as token ownership is concerned.
      {:error, _capacity} -> :ok
    end
  end

  defp settle(:defer, dlv, _state), do: QueueStore.defer(dlv.queue, dlv.seq, [])

  defp settle(:deadletter, dlv, _state) do
    case QueueStore.deadletter(dlv.queue, dlv.seq, "rejected", nil, lock_token: dlv.lock_token) do
      {:ok, _dlq_seq} -> :ok
      {:error, :lock_lost} -> :lock_lost
      {:error, _other} -> :ok
    end
  end

  # --- send helpers -------------------------------------------------------------------

  # Outbound frame-size gate (AMQP §2.3.1): never write a frame larger than
  # the peer's advertised max_frame_size (clamped to our local decode cap, so
  # a peer could never talk us into an oversized write either). Previously the
  # outbound path had no cap at all (lens-4 cycle-3 analysis).
  defp clamp_peer_frame_size(nil), do: nil

  defp clamp_peer_frame_size(n) when is_integer(n) and n > 0,
    do: min(n, FrameCodec.max_frame_size())

  defp send_frame(state, channel, {name, fields}) do
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

  # Outgoing transfers MUST use a per-session (per-channel) delivery-id
  # sequence: rhea validates each session's incoming transfer ids as a strict
  # run (Incoming.on_transfer: "frame sequence error: expected N, got M") and
  # tears the connection down on the first gap. A global counter produced gaps
  # whenever more than one session sent (census wires 2..8: the $cbs reply used
  # the global id while the client session expected the per-session successor).
  defp send_message(state, link, fields, sections) do
    sess = get_session(state, link.channel)
    delivery_id = sess.next_out
    transfer_fields = Map.put(fields, :delivery_id, delivery_id)
    cap = state[:peer_max_frame_size]

    frames =
      case body_chunks(sections, cap) do
        nil ->
          [
            FrameCodec.encode_frame(:amqp, link.channel, {
              :transfer,
              transfer_fields,
              {:sections, sections}
            })
          ]

        chunks ->
          # AMQP §2.3.1: a transfer whose frame would exceed the peer's
          # body_data payloads can be chunked losslessly (a message body is the
          # concatenation of body_data sections); leading non-body sections ride
          # the first frame only.
          {pre, [{:body_data, _}]} = split_body_sections(sections)
          more = Map.get(transfer_fields, :more, false)

          [first | middle_last] = chunks
          {middle, last} = Enum.split(middle_last, -1)

          first_frame =
            FrameCodec.encode_frame(:amqp, link.channel, {
              :transfer,
              Map.put(transfer_fields, :more, true),
              {:sections, pre ++ [first]}
            })

          middle_frames =
            for chunk <- middle do
              FrameCodec.encode_frame(:amqp, link.channel, {
                :transfer,
                %{handle: transfer_fields.handle, delivery_id: delivery_id, more: true},
                {:sections, [chunk]}
              })

              # AMQP §2.3.1: continuation frames carry only the body chunk;
              # more=true until the last frame, which carries the original
              # transfer's own more flag.
            end

          [last_frame] =
            for chunk <- last do
              FrameCodec.encode_frame(:amqp, link.channel, {
                :transfer,
                %{handle: transfer_fields.handle, delivery_id: delivery_id, more: more},
                {:sections, [chunk]}
              })
            end

          [first_frame | middle_frames] ++ [last_frame]
      end

    Enum.each(frames, &:gen_tcp.send(state.sock, &1))
    {put_session(state, link.channel, %{sess | next_out: delivery_id + 1}), delivery_id}
  end

  # Chunks the message body when the whole transfer frame would exceed the
  # peer's advertised max_frame_size. Returns nil when no split is needed or
  # possible (no negotiated cap, non-binary body — body_amqp_value sections
  # cannot be chunked losslessly so they are sent whole, and the peer cap is
  # ≥512 per spec while our local cap is 1 MiB).
  defp body_chunks(_sections, nil), do: nil

  defp body_chunks(sections, cap) do
    {_pre, body} = split_body_sections(sections)

    case body do
      [{:body_data, bin}] when is_binary(bin) ->
        total = 8 + IO.iodata_length(FrameCodec.encode_message(sections)) + 256
        chunk_size = max(cap - 1024, 64)

        if total <= cap do
          nil
        else
          chunk_binary(bin, chunk_size, [])
        end

      _ ->
        nil
    end
  end

  defp chunk_binary(bin, size, acc) when byte_size(bin) > size do
    <<chunk::binary-size(^size), rest::binary>> = bin
    chunk_binary(rest, size, [{:body_data, chunk} | acc])
  end

  defp chunk_binary(bin, _size, acc), do: Enum.reverse([{:body_data, bin} | acc])

  defp split_body_sections(sections) do
    Enum.split_while(sections, fn
      {k, _} when k in [:body_data, :body_amqp_value] -> false
      _ -> true
    end)
  end

  defp close_with_error(state, condition, description) do
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

  defp error_close(state, condition, description) do
    close_with_error(state, condition, description)
    %{state | halted: true}
  end

  # Per-session (per-channel) transfer-id state. rhea validates each session's
  # incoming transfer ids as a strict run; ids from one global counter produce
  # gaps on any multi-session connection and the client tears the connection
  # down ("frame sequence error").
  defp get_session(state, channel),
    do: Map.get(state.sessions || %{}, channel, %{next_out: 0, next_in: 0})

  defp put_session(state, channel, sess),
    do: %{state | sessions: Map.put(state.sessions || %{}, channel, sess)}

  # Credit is scoped per {channel, handle}: handle values collide across
  # sessions (every rhea session starts at handle 0), so a handle-only bump
  # granted a NEW session's flow credit to the PREVIOUS session's same-handle
  # link — that link then "stole" the delivery on the next flow (the transfer
  # went to the old, already-drained receiver and the message vanished;
  # census stale-handle probe).
  defp add_credit(state, credit, ch) do
    update_links(state, fn
      {c, _h}, link ->
        if (ch == nil or c == ch) and link.kind == :queue and link.role == :sender,
          do: %{link | credit: link.credit + credit},
          else: link
    end)
  end

  defp bump_credit(state, ch, handle, delta) do
    state =
      update_links(state, fn
        {c, h}, link when h == handle and (ch == nil or c == ch) ->
          %{link | credit: max(link.credit + delta, 0)}

        _key, link ->
          link
      end)

    # T-12 (a) chaos hook: bump_credit is called ONLY from the three delivery
    # paths (queue claim + both EH paths), so the delivery decrement is the
    # one counting point for every link kind.
    chaos_after_delivery(state, ch, handle, delta)
  end

  # T-12 (a) :sb_chaos_detach_after / :eh_chaos_detach_after — per-link
  # delivery count; on the Nth delivery, requeue the SAME typed detach
  # message the {:eh_epoch_evict, ...} cross-connection eviction handler
  # consumes (retryable amqp:link:detach-forced; the connection stays up so
  # the client relink is clean) and zero the link credit so the same-frame
  # delivery recursion cannot outrun the detach. Flags off = passthrough
  # (no counter writes, no state change).
  defp chaos_after_delivery(state, ch, handle, delta) when delta < 0 do
    case Map.get(state.links, {ch, handle}) do
      %{} = link ->
        ns = if link[:kind] == :eventhubs, do: :eh, else: :sb
        count = Map.get(link, :chaos_deliveries, 0) + 1

        if Smalt.Messaging.Chaos.should_detach?(count, ns) do
          Smalt.Messaging.Chaos.emit(:link_detach, %{deliveries: count}, %{
            namespace: ns,
            channel: ch,
            handle: handle,
            address: link[:address]
          })

          send(self(), {:eh_epoch_evict, ch, handle, Smalt.Messaging.Chaos.detach_error(count)})
          put_link(state, %{link | credit: 0})
        else
          if Smalt.Messaging.Chaos.detach_armed?(ns) do
            put_link(state, Map.put(link, :chaos_deliveries, count))
          else
            state
          end
        end

      _ ->
        state
    end
  end

  defp chaos_after_delivery(state, _ch, _handle, _delta), do: state

  # Absolute credit assignment for inbound :flow on a specific handle
  # (SHIM-COURT flip target: BEFORE = additive bump, AFTER = absolute set).
  defp set_credit(state, ch, handle, credit) do
    update_links(state, fn
      {c, h}, link when h == handle and (ch == nil or c == ch) -> %{link | credit: credit}
      _key, link -> link
    end)
  end

  defp update_links(state, fun) do
    %{state | links: Map.new(state.links, fn {key, l} -> {key, fun.(key, l)} end)}
  end

  defp put_link(state, link),
    do: %{state | links: Map.put(state.links, {link.channel, link.handle}, link)}

  # Links are keyed {channel, handle}: handle values collide across sessions
  # (the SDK's $cbs sender and a queue sender on another session both use
  # handle 0), and per-handle keys made one link overwrite the other.
  defp link_by_handle(state, channel, handle) do
    state.links[{channel, handle}] || state.links[{state.session[:channel] || channel, handle}]
  end

  defp address_of(nil), do: nil
  defp address_of(%{address: a}), do: address_of(a)
  defp address_of(bin) when is_binary(bin), do: bin
  defp address_of({:symbol, s}) when is_binary(s), do: s

  defp address_of({:described, _d, fields}) when is_list(fields),
    do: address_of(Enum.at(fields, 0))

  defp address_of(_), do: nil

  # Repair lane R96: strip the "scheme://host[:port]/" prefix off an attach
  # address, leaving the bare entity name. Only fires on amqp/amqps/sb scheme
  # forms; bare names, "$cbs"/"$management" and EH path forms pass through.
  defp bare_entity(address) when is_binary(address) do
    case String.split(address, "://", parts: 2) do
      [scheme, rest] when scheme in ["amqp", "amqps", "sb"] ->
        case String.split(rest, "/", parts: 2) do
          [_host, entity] when is_binary(entity) and entity != "" ->
            # R129 exploit 1 (W5-17): "amqps://h:5671/q/" previously fell
            # through the entity != "" guard and kept the FULL URI as the
            # store key — a distinct queue namespace that bypassed the
            # requiresSession gate (enqueue to "q/" succeeded without a
            # session while "q" required one). Strip trailing slashes so
            # "q/" normalizes to "q". Empty-after-strip ("amqps://h/")
            # keeps the original guard: the address passes through
            # unchanged, still failing closed against the session gate.
            # Percent-decoding is deliberately NOT done (parked): decode
            # would alias distinct encodings onto one entity; add it only
            # with a real-SDK census receipt pinning the encoding.
            case String.trim_trailing(entity, "/") do
              "" -> address
              bare -> bare
            end

          _ ->
            address
        end

      _ ->
        # R129 exploit 1: BARE entity names take the same gate — "q/" is a
        # shadow namespace of "q" and used to slip past both the requiresSession
        # gate and the R96 scheme-form stripping (no "://" -> pass through).
        # Trim trailing slashes so "q/" normalizes to "q"; empty-after-strip
        # ("/") keeps the address unchanged, still failing closed.
        case String.trim_trailing(address, "/") do
          "" -> address
          bare -> bare
        end
    end
  end

  defp bare_entity(other), do: other

  defp plain({:symbol, s}) when is_binary(s), do: s
  defp plain(s) when is_binary(s), do: s
  defp plain(nil), do: nil
  defp plain(other), do: other

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {{:symbol, k}, v} when is_binary(k) -> {k, v}
      {k, v} when is_binary(k) -> {k, v}
      kv -> kv
    end)
  end

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {k, v}
      {{:symbol, k}, v} when is_binary(k) -> {k, v}
      {k, v} -> {to_string(k), v}
    end)
  end

  defp authorized?(audience) do
    ensure_cbs_router()

    cond do
      not cbs_running?() or :ets.info(:smalt_sb_tokens) == :undefined ->
        true

      is_binary(audience) ->
        endpoint = Smalt.Amqp.SasVerifier.endpoint()

        # put-token claims are keyed by the full "sb://host:port/entity"
        # audience; the attach address is the bare entity name. pyamqp
        # dialect (S-1, disclosed in s1-amqp-shims receipt): the Python SDK
        # attaches queue links with an `amqps://` scheme while its own CBS
        # token is minted for `sb://` — try the sb-normalized form too
        # instead of refusing the entity on a scheme spelling.
        normalized =
          case String.split(audience, "://", parts: 2) do
            ["amqps", rest] -> "sb://" <> rest
            _ -> audience
          end

        CbsRouter.authorized?(CbsRouter, self(), audience) or
          CbsRouter.authorized?(CbsRouter, self(), endpoint <> "/" <> audience) or
          CbsRouter.authorized?(CbsRouter, self(), normalized)

      true ->
        true
    end
  end
end
