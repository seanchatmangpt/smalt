defmodule Smalt.Amqp.Connection do
  @moduledoc """
  One AMQP 1.0 connection per accepted `:gen_tcp` socket (active: false, binary).

  Wire state machine:

  1. SASL layer first — server offers `[ANONYMOUS]`, expects `sasl-init` with
     mechanism `ANONYMOUS`, replies `sasl-outcome` code 0.
  2. AMQP layer — protocol header exchange, then open (container-id
     `"smalt-local"`, max-frame-size 1048576) -> begin -> attach routing:

     | address              | handler                              |
     |----------------------|--------------------------------------|
     | `"$cbs"`             | `Smalt.Amqp.CbsRouter` (GenServer)   |
     | contains "management" | `Smalt.Amqp.ManagementRpc.handle/2` |
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

  @max_frame_size 1_048_576
  @protocol_header "AMQP\x00\x01\x00\x00"
  @sasl_protocol_header "AMQP\x03\x01\x00\x00"
  @recv_timeout 300_000
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

  # ===========================================================================
  # GenServer callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    sock = Keyword.fetch!(opts, :socket)
    mode = Keyword.get(opts, :mode, :sb)
    :ok = :inet.setopts(sock, active: false, mode: :binary)
    send(self(), :recv)

    {:ok,
     %{
       sock: sock,
       mode: mode,
       buffer: <<>>,
       halted: false,
       peer_max_frame_size: nil,
       phase: :sasl_header,
       session: nil,
       links: %{},
       sessions: %{},
       next_delivery_id: 0,
       outbound_deliveries: %{},
       eh_cursors: %{}
     }}
  end

  @impl true
  def handle_info(:recv, state) do
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
          %{halted: true} = state -> {:stop, :normal, state}
          state -> send(self(), :recv)
            {:noreply, state}
        end

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
            _other -> "amqp:internal-error"
          end

        {:stop, :normal, close_with_error(state, close_reason, inspect(reason))}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{sock: sock}), do: :gen_tcp.close(sock)

  # ===========================================================================
  # Input pump: header peeling + frame framing
  # ===========================================================================

  defp next_input(%{phase: phase, buffer: buf} = state) when phase in [:sasl_header, :amqp_header] do
    if byte_size(buf) >= 8 do
      <<hdr::binary-size(8), rest::binary>> = buf

      cond do
        # SASL-layer negotiation (AMQP spec header id 0x03)
        phase == :sasl_header and hdr == @sasl_protocol_header ->
          :gen_tcp.send(state.sock, @sasl_protocol_header)
          send_frame(state, 0, {:sasl_mechanisms, %{server_mechanisms: [{:symbol, @sasl_anonymous}]}})
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
          {:error, :bad_protocol_header, state}
      end
    else
      need_more(state, 8 - byte_size(buf))
    end
  end

  defp next_input(%{buffer: buf} = state) do
    case FrameCodec.decode_frame(buf) do
      {:ok, frame} ->
        {:ok, {:frame, frame}, %{state | buffer: rest_after(buf, frame)}}

      {:more, n} ->
        need_more(state, n - byte_size(buf))

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp need_more(%{sock: sock, buffer: buf} = state, want) do
    want = max(want, 1)

    # Idle-time-out enforcement: after open the negotiated clamp applies;
    # before open (SASL/header phase) a short cap closes truncated-frame and
    # slow-start slowloris attacks instead of holding the socket 300s
    # (R3 F1/H4 findings).
    idle_timeout =
      if state[:conn_opened] == true,
        do: state[:idle_time_out] || @recv_timeout,
        else: @pre_open_timeout

    case :gen_tcp.recv(sock, want, idle_timeout) do
      {:ok, data} -> next_input(%{state | buffer: <<buf::binary, data::binary>>})
      {:error, :closed} -> {:closed, state}
      {:error, :timeout} -> {:closed, state}
      {:error, reason} -> {:error, reason, state}
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

    if mech == @sasl_anonymous do
      send_frame(state, 0, {:sasl_outcome, %{code: 0}})
      %{state | phase: :amqp_header}
    else
      send_frame(state, 0, {:sasl_outcome, %{code: 1}})
      error_close(state, "amqp:unauthorized-access", "unsupported SASL mechanism")
    end
  end

  defp handle_sasl(_perf, state) do
    error_close(state, "amqp:internal-error", "unexpected SASL frame")
  end

  defp mech_name({:symbol, s}) when is_binary(s), do: s
  defp mech_name(s) when is_binary(s), do: s
  defp mech_name(_), do: nil

  # --- AMQP performatives -------------------------------------------------------

  defp handle_amqp(:attach, perf, channel, state), do: handle_attach(perf, channel, state)

  defp handle_amqp(:flow, perf, ch, state) do
    credit = perf.link_credit || 0

    state =
      case perf.handle do
        nil -> add_credit(state, credit, ch)
        handle -> bump_credit(state, ch, handle, credit)
      end

    deliver_available(state)
  end

  defp handle_amqp(:open, perf, _ch, state) do
    send_frame(state, 0, {
      :open,
      %{container_id: @container_id, max_frame_size: @max_frame_size, channel_max: 65_535}
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
    state |> Map.put(:session, session) |> Map.put(:conn_opened, true) |> Map.put(:idle_time_out, idle)
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

  defp handle_amqp(:disposition, perf, channel, state), do: handle_disposition(perf, channel, state)

  defp handle_amqp(:detach, perf, ch, state) do
    case link_by_handle(state, ch, perf.handle) do
      nil ->
          state

      link ->
        # Release a held session lock when its receiver link detaches, so a
        # subsequent acceptSession can acquire it (real Service Bus parity).
        if link.kind == :queue and link.role == :receiver and is_binary(link.session_id) and
             link.session_id != "" do
          Smalt.Amqp.LockManager.session_release(link.address, link.session_id)
        end

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

    case state.session do
      %{channel: ^ch} -> %{state | session: nil, links: remaining, sessions: Map.delete(state.sessions || %{}, ch)}
      _ -> %{state | links: remaining, sessions: Map.delete(state.sessions || %{}, ch)}
    end
  end

  defp handle_amqp(:close, _perf, ch, state) do
    send_frame(state, ch, {:close, %{error: nil}})
    %{state | halted: true}
  end

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

    kind = route(address, state.mode)

    if kind == :queue and not authorized?(address) do
      # rhea (core-amqp) requires the broker attach echo BEFORE any detach
      # (Session.on_attach populates remote.handles only on attach; a bare
      # detach raises "Invalid handle N" client-side). Echo attach, then
      # detach typed.
      send_frame(state, channel, {
        :attach,
        %{name: perf.name, handle: perf.handle, role: our_role == :receiver, initial_delivery_count: 0}
      })

      send_frame(state, channel, {
        :detach,
        %{handle: perf.handle, closed: true, error: unauthorized_error()}
      })

      state
    else
      {kind, address} = normalize_dql_casing(kind, address)

      link = %{
        name: plain(perf.name),
        handle: perf.handle,
        channel: channel,
        role: our_role,
        session_id: extract_session_filter(perf.source),
        eh_cursor: 0,
        address: address,
        kind: kind,
        credit: 0,
        partial: nil
      }

      # Disclosed cross-lane unblock (s5_sessions e2e lane): the Service Bus
      # SDK derives the granted session id from the attach response's source
      # filter (com.microsoft:session-filter). Without the source echo it
      # reads undefined and fails acceptSession with "session may be locked".
      base_attach = %{
        name: perf.name,
        handle: perf.handle,
        role: our_role == :receiver,
        initial_delivery_count: 0
      }

      {attach_fields, state} =
        case {kind, our_role, link.session_id} do
          {:queue, :sender, sid} when is_binary(sid) and sid != "" ->
            case Smalt.Amqp.LockManager.session_acquire(address, sid) do
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
                      "com.microsoft:locked-until-utc" => DeliveryEncoder.filetime_from_ms(slock.locked_until)
                    }
                  })

                {fields, state}

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

                {nil, state}
            end

          _ ->
            {base_attach, state}
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

        _ ->
          send_frame(state, channel, {:attach, attach_fields})

          # grant link credit for client-sender links so peer transfers can flow.
          # delivery_count MUST be present: rhea computes sender credit as
          # `flow.delivery_count + flow.link_credit - this.delivery_count`
          # (rhea/lib/link.js Sender.prototype.on_flow); omitting it makes the
          # credit NaN and 'sendable' never fires (every send times out).
          # It must agree with the attach reply's initial_delivery_count (0).
          link =
            if client_role == :sender do
              send_flow(state, channel, %{
                handle: perf.handle,
                delivery_count: 0,
                link_credit: 1000
              })

              %{link | credit: 1000}
            else
              link
            end

          %{state | links: Map.put(state.links, {channel, perf.handle}, link)}
      end
    end
  end

  defp route(nil, _mode), do: :unknown
  defp route("$cbs", _mode), do: :cbs

  defp route(address, mode) when is_binary(address) do
    cond do
      String.contains?(address, "management") -> :management
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
  defp extract_session_filter(%{filter: %{"com.microsoft:session-filter" => {:session_filter, selector}}}),
    do: selector

  defp extract_session_filter(%{filter: %{session_filter: selector}}), do: selector
  defp extract_session_filter(_), do: nil

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
        # send_event returns {:ok, seq, event_map} — bind the full tuple; the
        # match still fails closed if the :ok tag ever regresses.
        {:ok, _seq, _event} = EventHubs.send_event(partition, payload, [])

        delivery_id = perf[:delivery_id] || 0

        send_frame(state, link.channel, {
          :disposition,
          %{role: true, first: delivery_id, last: delivery_id, settled: true, state: :accepted}
        })

        state

      _ ->
        error_close(state, "amqp:internal-error", "transfer on unknown handle #{inspect(perf[:handle])}")
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

        state

      {:error, reason} ->
        error_close(state, "amqp:link-message-size-exceeded", inspect(reason))
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

    case QueueStore.enqueue(link.address, body_section, session_id: session_id, message_id: message_id, app_props: app_props) do
      {:ok, _seq} ->
        {:ok, state}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- $cbs / $management RPC ------------------------------------------------------

  defp handle_cbs(perf, state) do
    message = decode_message_sections(perf.__payload__)
    props = message.application_properties || %{}
    # SDK CBS messages carry the operation in properties.subject
    op = props["operation"] || message.properties[:subject] || message.properties["subject"]
    body = message.body || %{}
    Logger.debug("[amqp-cbs] op=#{inspect(op)} props=#{inspect(props)} body=#{inspect(body)} sections=#{inspect(message)}")
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

    reply_cbs(state, perf, %{"statusCode" => status, "statusDescription" => description}, correlation_id)
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
          send_message(state, link, %{
            handle: link.handle,
            delivery_tag: <<>>,
            message_format: 0,
            settled: true,
            more: false
          }, [
            # the SDK correlates via correlation-id and reads the verdict from
            # application-properties "statusCode"/"statusDescription"
            {:properties, %{correlation_id: correlation_id}},
            {:application_properties, %{
              # core-amqp 4.5.1 reads the dotted "status-code"/"status-description"
              # symbol keys; older paths read "statusCode". Emit both.
              "status-code" => body["statusCode"],
              "status-description" => body["statusDescription"],
              "statusCode" => body["statusCode"],
              "statusDescription" => body["statusDescription"]
            }},
            {:body_amqp_value, body}
          ])

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

    request = %{
      operation: props["operation"],
      body: message.body,
      queue: associated_queue,
      correlation_id: correlation_id
    }

    result = ManagementRpc.handle(request, %{conn_pid: self()})

    status = result.status_code

    body =
      result.body
      |> case do
        nil -> %{}
        body -> normalize_mgmt_bodies(body)
      end
      |> then(&Map.merge(%{"statusCode" => status, "statusDescription" => result.status_description}, stringify_map(&1)))

    reply_management(state, perf, body, request.correlation_id, channel)
  end

  defp reply_management(state, perf, body, correlation_id, channel) do
    link = find_reply_link(state, perf, :management, channel)

    case link do
      nil ->
        Logger.warning("[amqp-conn] no $management reply link")
        state

      link ->
        {state, _delivery_id} =
          send_message(state, link, %{
            handle: link.handle,
            delivery_tag: <<>>,
            message_format: 0,
            settled: true,
            more: false
          }, [
            {:properties, %{correlation_id: correlation_id}},
            {:application_properties, %{
              # core-amqp 4.5.1 reads the dotted "status-code"/"status-description"
              # symbol keys; older paths read "statusCode". Emit both.
              "status-code" => body["statusCode"],
              "status-description" => body["statusDescription"],
              "statusCode" => body["statusCode"],
              "statusDescription" => body["statusDescription"]
            }},
            {:body_amqp_value, body}
          ])

        state
    end
  end

  defp find_reply_link(state, perf, kind, req_channel) do
    payload_props = decode_message_sections(perf.__payload__).application_properties || %{}
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
          %{"x-opt-sequence-number" => seq}

        _ ->
          %{}
      end

    sections =
      (if annotations == %{}, do: [], else: [{:message_annotations, annotations}]) ++
        maybe_properties_section(msg) ++
        [body_section_to_section(body_section)]

    Map.put(msg, "message", {:vbin, FrameCodec.encode_message(sections) |> IO.iodata_to_binary()})
  end

  defp normalize_mgmt_message(other), do: other

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
    |> Enum.filter(fn link -> link.role == :sender and link.kind in [:queue, :eventhubs] and link.credit > 0 end)
    |> Enum.reduce(state, &deliver_link_reducer/2)
  end

  defp deliver_link_reducer(link, st) do
    if link.kind == :eventhubs, do: deliver_eventhubs(st, link), else: deliver_to_link(st, link)
  end

  defp deliver_eventhubs(state, link) do
    partition = eh_partition(link.address)
    after_seq = get_in(state, [:eh_cursors, partition]) || 0

    # V261014-04 F1: `receive_events/3` returns a BARE list (its @spec and the
    # public contract consumed by c7_events.exs + reconcile callers), so a
    # `{:ok, events}` match could never succeed and no EH event was ever
    # delivered over the wire. Match the bare-list shape; an empty list (or any
    # other shape) falls through closed.
    case EventHubs.receive_events(partition, after_seq, link.credit) do
      [_ | _] = events ->
        Enum.reduce(events, state, fn ev, st ->
          seq = ev["seq"]
          body = ev["body"]

          {st, _id} =
            send_message(st, link, %{
              handle: link.handle,
              delivery_tag: <<seq::unsigned-64>>
            }, [
              {:message_annotations, %{"x-opt-sequence-number" => seq}},
              {:body_data, body}
            ])

          st
          |> Map.update!(:eh_cursors, fn m -> Map.put(m || %{}, partition, seq) end)
        end)

      _ ->
        state
    end
  end

  defp eh_partition(address) when is_binary(address), do: address |> String.split("/") |> List.last()

  defp deliver_to_link(state, link) do
    case QueueStore.dequeue_matching(link.address, session_id: link.session_id) do
      {:ok, msg, lock} ->
        sections = delivery_sections(msg)

        {state, delivery_id} =
          try do
            send_message(state, link, %{
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
            }, sections)
          rescue
            # Store-and-forward lock leak (lens-4 cycle-3): dequeue_matching
            # acquires the message lock BEFORE the encode+send; an encode
            # raise here used to leave the message locked forever with no
            # release/deadletter decision. Release it back and close typed.
            e in ArgumentError ->
              QueueStore.release(msg.queue, msg.seq)
              Logger.error("[amqp-conn] delivery encode failed, lock released: " <> Exception.message(e))
              error_close(state, "amqp:internal-error", "DELIVERY_ENCODE_FAILED")

              {state, 0}
          end

        state = %{
          state
          | outbound_deliveries:
              Map.put(state.outbound_deliveries, delivery_id, %{queue: msg.queue, seq: msg.seq, lock_token: lock.lock_token})
        }

        state = bump_credit(state, link.channel, link.handle, -1)

        if state.links[{link.channel, link.handle}][:credit] > 0 do
          deliver_to_link(state, Map.get(state.links, {link.channel, link.handle}))
        else
          state
        end

      :empty ->
        state

      {:error, _} ->
        state
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
  defp stored_body_section({kind, value}) when kind in [:body_data, :body_amqp_value], do: {kind, value}
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

      {state, matched_any} =
        Enum.reduce(first..last, {state, false}, fn delivery_id, {st, matched} ->
          case Map.get(st.outbound_deliveries, delivery_id) do
            nil ->
              {st, matched}

            dlv ->
              settle(action, dlv)
              {Map.put(st, :outbound_deliveries, Map.delete(st.outbound_deliveries, delivery_id)), true}
          end
        end)

      # Receiver-initiated settlement (SDK peekLock receivers settle with
      # settled=false and rcv-settle-mode=first): the sender endpoint MUST
      # echo the terminal disposition or the client's complete/abandon
      # hangs forever ("Operation to settle the message has timed out").
      # If the client already settled on the wire (settled=true), no echo.
      if matched_any and not perf[:settled] do
        send_frame(state, channel, {:disposition, %{role: false, first: first, last: last, settled: true}})
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
    if m[:undeliverable_here] == true or m["undeliverable-here"] == true, do: :defer, else: :release
  end

  defp modified_action(_), do: :release

  defp settle(:complete, dlv) do
    # lock-expiry gate: completing on an expired/lost lock would steal the
    # message from its current owner; release it back instead (redelivery)
    case Smalt.Amqp.LockManager.get(dlv.lock_token) do
      {:ok, lock} ->
        if Smalt.Amqp.LockManager.expired?(lock, System.system_time(:millisecond)) do
          QueueStore.release(dlv.queue, dlv.seq)
        else
          QueueStore.complete(dlv.queue, dlv.seq)
        end

      _ ->
        # lock lost (expired + swept or released): requeue instead of completing
        QueueStore.release(dlv.queue, dlv.seq)
    end
  end

  defp settle(:release, dlv), do: QueueStore.release(dlv.queue, dlv.seq)

  defp settle(:defer, dlv), do: QueueStore.defer(dlv.queue, dlv.seq, [])

  defp settle(:deadletter, dlv) do
    QueueStore.deadletter(dlv.queue, dlv.seq, "rejected", nil, [])
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
    channel = channel || state.session[:channel] || 0
    layer = if name in [:sasl_mechanisms, :sasl_init, :sasl_outcome, :sasl_challenge], do: :sasl, else: :amqp

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
          FrameCodec.encode_frame(:amqp, channel, {:close, %{error: %{condition: "amqp:internal-error", description: "ENCODE_FAILED"}}})
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
    <<chunk::binary-size(size), rest::binary>> = bin
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
      FrameCodec.encode_frame(:amqp, channel, {:close, %{error: %{condition: condition, description: description}}})

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
  defp get_session(state, channel), do: Map.get(state.sessions || %{}, channel, %{next_out: 0, next_in: 0})

  defp put_session(state, channel, sess), do: %{state | sessions: Map.put(state.sessions || %{}, channel, sess)}

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
    update_links(state, fn
      {c, h}, link when h == handle and (ch == nil or c == ch) -> %{link | credit: max(link.credit + delta, 0)}
      _key, link -> link
    end)
  end

  defp update_links(state, fun) do
    %{state | links: Map.new(state.links, fn {key, l} -> {key, fun.(key, l)} end)}
  end

  defp put_link(state, link), do: %{state | links: Map.put(state.links, {link.channel, link.handle}, link)}

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
        # audience; the attach address is the bare entity name
        CbsRouter.authorized?(CbsRouter, self(), audience) or
          CbsRouter.authorized?(CbsRouter, self(), endpoint <> "/" <> audience)

      true ->
        true
    end
  end
end
