defmodule Smalt.Amqp.Connection.Handshake do
  @moduledoc """
  Connection protocol phases up to `:amqp_frames`: protocol-header peel,
  SASL (ANONYMOUS), and `open` negotiation — extracted verbatim from
  `Smalt.Amqp.Connection` (T08, v26.10.29).

  BYTE-PINION SURFACE — do not "clean up" any of the following; they are
  real-SDK-census-pinned (smalt CLAUDE.md):

  - SASL ANONYMOUS only; the advertised mechanism set on the wire stays
    exactly `[ANONYMOUS]` even when a module attribute or profile config
    excludes it.
  - `sasl-outcome` descriptor 0x44, code 0 vs 1 semantics.
  - attach top-level fields `<= 14` with locale fields omitted
    (source=8 / target=7 composite arity tripwires).
  - .NET-GUID lock-token byte reordering.
  - EH fixed partitions `["0", "1"]`.
  """

  alias Smalt.Amqp.FrameCodec

  @max_frame_size 1_048_576
  @protocol_header "AMQP\x00\x01\x00\x00"
  @sasl_protocol_header "AMQP\x03\x01\x00\x00"
  @recv_timeout 300_000
  @container_id "smalt-local"
  @sasl_anonymous "ANONYMOUS"

  # ===========================================================================
  # Protocol-header peel (next_input header phase)
  # ===========================================================================

  # Returns {:ok, state} after a header was peeled (the caller re-dispatches
  # on the new phase), {:closed, state}, or {:error, reason, state}.
  def handle_header(%{phase: phase, buffer: buf} = state)
      when phase in [:sasl_header, :amqp_header] do
    if byte_size(buf) >= 8 do
      <<hdr::binary-size(8), rest::binary>> = buf

      cond do
        # SASL-layer negotiation (AMQP spec header id 0x03)
        phase == :sasl_header and hdr == @sasl_protocol_header ->
          :gen_tcp.send(state.sock, @sasl_protocol_header)

          Smalt.Amqp.Connection.send_frame(
            state,
            0,
            {:sasl_mechanisms, %{server_mechanisms: [{:symbol, @sasl_anonymous}]}}
          )

          {:ok, %{state | buffer: rest, phase: :sasl_frames}}

        # plain AMQP header up front: client skips SASL entirely
        phase == :sasl_header and hdr == @protocol_header ->
          :gen_tcp.send(state.sock, @protocol_header)
          {:ok, %{state | buffer: rest, phase: :amqp_frames}}

        # AMQP-layer header after SASL outcome
        hdr == @protocol_header ->
          :gen_tcp.send(state.sock, @protocol_header)
          {:ok, %{state | buffer: rest, phase: :amqp_frames}}

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

  # KD-COVERS: KD-69 — short-recv mailbox-servicing pump wait. The recv-slice
  # machinery stays with the crash-only connection root; only the phase
  # routing lives here.
  defp need_more(state, want), do: Smalt.Amqp.Connection.pump_wait(state, want)

  # ===========================================================================
  # SASL
  # ===========================================================================

  def handle_sasl(%{performative: :sasl_init} = perf, state) do
    mech = mech_name(perf.mechanism)

    cond do
      mech == @sasl_anonymous and configured_sasl_admits_anonymous?() ->
        Smalt.Amqp.Connection.send_frame(state, 0, {:sasl_outcome, %{code: 0}})
        %{state | phase: :amqp_header}

      mech == @sasl_anonymous ->
        # AZB-07 :amqp profile read site: a configured sasl_mechanisms list
        # that excludes :anonymous types the refusal. The advertised set on
        # the wire stays exactly [ANONYMOUS] (wire-compat pinion, verbatim).
        Smalt.Amqp.Connection.send_frame(state, 0, {:sasl_outcome, %{code: 1}})
        Smalt.Amqp.Connection.error_close(state, "amqp:unauthorized-access", "SASL :anonymous excluded by profile")

      true ->
        Smalt.Amqp.Connection.send_frame(state, 0, {:sasl_outcome, %{code: 1}})
        Smalt.Amqp.Connection.error_close(state, "amqp:unauthorized-access", "unsupported SASL mechanism")
    end
  end

  def handle_sasl(_perf, state) do
    Smalt.Amqp.Connection.error_close(state, "amqp:internal-error", "unexpected SASL frame")
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

  # ===========================================================================
  # open negotiation
  # ===========================================================================

  def handle_open(perf, state) do
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

    Smalt.Amqp.Connection.send_frame(state, 0, {
      :open,
      %{
        container_id: @container_id,
        max_frame_size: configured_max_frame_size() || @max_frame_size,
        channel_max: 65_535,
        idle_time_out: idle
      }
    })

    state =
      Map.put(state, :container_id, Smalt.Amqp.Connection.plain(perf.container_id))
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

  # AZB-07 (:amqp profile read site, one-source via Smalt.Config.amqp/0): when
  # the integration-plane profile sets :max_frame_size, a frame whose declared
  # size exceeds the configured cap closes with the typed
  # amqp:frame-size-too-small condition — never a crash. Unset = the
  # frame_codec hard cap governs (default boot byte-identical).
  def configured_max_frame_size do
    case Smalt.Config.amqp()[:max_frame_size] do
      n when is_integer(n) and n > 0 -> min(n, FrameCodec.max_frame_size())
      _ -> nil
    end
  end

  # Outbound frame-size gate (AMQP §2.3.1): never write a frame larger than
  # the peer's advertised max_frame_size (clamped to our local decode cap, so
  # a peer could never talk us into an oversized write either). Previously the
  # outbound path had no cap at all (lens-4 cycle-3 analysis).
  defp clamp_peer_frame_size(nil), do: nil

  defp clamp_peer_frame_size(n) when is_integer(n) and n > 0,
    do: min(n, FrameCodec.max_frame_size())
end
