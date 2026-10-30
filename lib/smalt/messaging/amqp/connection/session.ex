defmodule Smalt.Amqp.Connection.Session do
  @moduledoc """
  AMQP session-endpoint state machine — begin / flow / end / close and the
  per-channel session map — extracted verbatim from `Smalt.Amqp.Connection`
  (T08, v26.10.29). The connection root stays the crash-only actor; these
  functions run inside it and route state back through the plain maps.
  """

  # SHIM-COURT-eligible clamp: one inbound :flow must not be able to grant
  # unbounded link credit (AMQP §2.7.4 link_credit is a peer-declared cap).
  @max_link_credit 10_000

  alias Smalt.Amqp.Connection.{Delivery, Link}

  # ===========================================================================
  # begin
  # ===========================================================================

  def handle_begin(perf, ch, state) do
    # Channel validation (R3 red-team finding): begin on an un-opened
    # connection is rejected with a session end error instead of being
    # silently accepted.
    if state[:conn_opened] != true do
      Smalt.Amqp.Connection.send_frame(state, ch, {
        :end,
        %{error: %{condition: "amqp:not-allowed", description: "SESSION_BEFORE_OPEN"}}
      })

      %{state | halted: true}
    else
      do_begin(perf, ch, state)
    end
  end

  defp do_begin(perf, ch, state) do
    sess = get_session(state, ch)
    next_out = sess.next_out

    Smalt.Amqp.Connection.send_frame(state, ch, {
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
  # the session layer is shared, so Chaos.session_close_bound/0 returns the
  # shortest armed bound). Arms a deterministic close timer keyed by a
  # make_ref token so a stale timer can never close a NEWER session re-begun
  # on the same channel. Off (:infinity) = no timer, zero interference.
  defp chaos_arm_session_timeout(state, ch) do
    case Smalt.Messaging.Chaos.session_close_bound() do
      ms when is_integer(ms) and ms > 0 ->
        ref = make_ref()
        Process.send_after(self(), {:sb_chaos_session_timeout, ch, ref}, ms)
        put_session(state, ch, Map.put(get_session(state, ch), :chaos_ref, ref))

      _ ->
        state
    end
  end

  # ===========================================================================
  # flow
  # ===========================================================================

  # KD-COVERS: KD-133 — this handler treats flow fields as a DECODED MAP
  # (order-independent), and FrameCodec's flow field list is AMQP-spec-ordered
  # on emit; spec-ordered client flows witnessed granting credit
  # (verification/ts/fix4-raw-wire.exs + fix4.probe.cjs L3, receipt
  # docs/jira/v26.10.20/receipts/fix4-amqp-witness.md).
  def handle_flow(perf, ch, state) do
    # AMQP 1.0 §2.7.4: an inbound :flow performative carries an ABSOLUTE
    # link-credit snapshot, not a delta. rhea (link.js on_flow) computes
    # `credit = flow.delivery_count + flow.link_credit - this.delivery_count`;
    # this link state does not track a sent delivery counter, so the
    # delivery_count terms cancel to 0 and the granted credit is the flow's
    # link_credit value directly (see Link.bump_credit/4 — that helper stays
    # for our OWN outbound decrements, which remain relative by spec).
    # Clamped so a single flow can't request 2^62.
    credit = (perf.link_credit && min(perf.link_credit, @max_link_credit)) || 0

    if chaos_starved?(state, ch, perf.handle, credit) do
      # T-12 (b): the credit grant is WITHHELD while the starve flag is
      # armed — deliveries stall until the flag clears on a re-boot. Credit
      # already outstanding still drains (the stall is on NEW grants).
      Delivery.deliver_available(state)
    else
      state =
        case perf.handle do
          nil -> Link.add_credit(state, credit, ch)
          handle -> Link.set_credit(state, ch, handle, credit)
        end

      Delivery.deliver_available(state)
    end
  end

  # T-12 (b) :sb_chaos_starve_credits / :eh_chaos_starve_credits — namespace
  # resolved from the targeted link's kind (a session-level flow, handle
  # nil, only ever grants queue links -> :sb). Emits typed telemetry per
  # withheld grant. Flags off = the grant proceeds byte-identically.
  # Placement note (L9): lives AFTER handle_flow/3 in the original file so
  # the clause grouping discipline stays intact.
  defp chaos_starved?(state, ch, handle, credit) do
    ns =
      case handle && Link.link_by_handle(state, ch, handle) do
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

  # ===========================================================================
  # end / close
  # ===========================================================================

  def handle_end(_perf, ch, state) do
    # Session end is NOT a connection close (census wire finding): closing the
    # TCP socket here killed the SDK's whole connection after its first send
    # (core-amqp closes the session after a sender close) and every later
    # probe starved silently. Ack the end, drop this session's state, keep the
    # connection alive.
    Smalt.Amqp.Connection.send_frame(state, ch, {:end, %{error: nil}})

    # Drop only the ended channel's links; other sessions on the same
    # connection keep theirs (the SDK keeps the $cbs session open while
    # closing the send session).
    remaining = Map.reject(state.links, fn {_h, l} -> l.channel == ch end)

    # GAP-A2-02: release epoch registrations held by this session's links.
    state.links
    |> Map.filter(fn {_h, l} -> l.channel == ch end)
    |> Enum.each(&Link.eh_epoch_release/1)

    # SHIM-COURT: retire this session's in-flight outbound deliveries so a
    # re-begin (next_out restarts at 0) cannot collide delivery-ids and let
    # the disposition handler settle a stale message.
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

  def handle_close(_perf, ch, state) do
    Smalt.Amqp.Connection.send_frame(state, ch, {:close, %{error: nil}})
    %{state | halted: true}
  end

  # ===========================================================================
  # Session map helpers
  # ===========================================================================

  # Per-session (per-channel) transfer-id state. rhea validates each session's
  # incoming transfer ids as a strict run; ids from one global counter produce
  # gaps on any multi-session connection and the client tears the connection
  # down ("frame sequence error").
  def get_session(state, channel),
    do: Map.get(state.sessions || %{}, channel, %{next_out: 0, next_in: 0})

  def put_session(state, channel, sess),
    do: %{state | sessions: Map.put(state.sessions || %{}, channel, sess)}

  # ===========================================================================
  # outbound flow frame
  # ===========================================================================

  def send_flow(state, channel, extra) do
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

    Smalt.Amqp.Connection.send_frame(state, channel, {:flow, fields})
  end
end
