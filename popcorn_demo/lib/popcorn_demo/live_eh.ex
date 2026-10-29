defmodule PopcornDemo.LiveEh do
  @moduledoc """
  WASM-BEAM Event Hubs enterprise leg (lane W2-7, hardened W13-R): publish ONE
  uniquely-tagged event to a fixed EH partition (wire pinion partitions
  `["0","1"]`), then receive the same bytes back on a partition-scoped receiver
  link whose SELECTOR FLOOR is the partition's PRE-PUBLISH last-enqueued
  sequence — so the receive leg scans O(new events), not O(backlog). Over the
  real AMQP 1.0 wire (127.0.0.1:5673, SASL ANONYMOUS, sasl-outcome 0x44).
  Chicago school — the only collaborators are the live smalt substrate and the
  wire; no mocks. Skips loudly only when the EH plane is not listening.

  Selector-floor hardening (W13-R, closes the W5-A diagnosis): the receiver no
  longer replays the partition from seq 0. The receiver attaches BEFORE the
  publish with the broker-native eventPosition
  `amqp.annotation.x-opt-offset > '@latest'` (partitionReceiver.js:357-360;
  resolved broker-side at attach time via `Smalt.Messaging.EventHubs.
  last_enqueued/1` — the PRE-PUBLISH last-enqueued seq), and link credit is
  granted only AFTER the publish. The floor therefore snapshots the partition
  tail exactly once, before this run's event exists, and the roundtrip stays
  byte-exact while scanning only this run's event.

  Note on the alternative capture: the `$management` READ
  `com.microsoft:partition` RPC (management_rpc.ex:971) reads
  `:smalt_eh_partitions` with the bare partition id ("0") while the table is
  keyed "ns/hub/partition" (event_hubs.ex:15, store_tables.ex:409) — the RPC
  always reports last_enqueued_sequence_number = 0 (witnessed 2026-10-20: the
  RPC returned 0 against a 30+-event partition; a selector `>= 'L+1'` built
  from it degenerated to a full replay). That is a
  `Smalt.Amqp.ManagementRpc` key-mismatch defect, outside this lane's file
  ownership — registered here for the coordinator, not fixed here.

  EH is AMQP-only (no HTTP/REST face in lib/smalt — the 5673 plane is the
  `Smalt.Amqp` listener with `Smalt.Messaging.EventHubs` storage behind it),
  so this leg carries its own minimal AMQP 1.0 client codec built on
  `:gen_tcp` (popcorn_demo has no dep on smalt; inets httpc is broken under
  this mix env — see `PopcornDemo.LiveBlob`'s moduledoc). The wire shapes it
  emits mirror what `Smalt.Amqp.FrameCodec` encodes against the same broker:
  `/eventhubs/{hub}/partitions/{n}` attach addresses (the `:eventhubs` link
  classification rides the `/eventhubs/` substring in
  `Smalt.Amqp.Connection`), sender+receiver on the SAME partition, unsettled
  transfer settled by a broker `accepted` disposition, receiver flow credit
  then delivery transfers whose `body_data` vbin is the event bytes.

  Receipt contract (house pattern, same as `PopcornDemo.LiveQueue`) — the
  selector floor does NOT change the surface:

  - `{:ok, "eh=OK(<hub>/<partition>:<token>-roundtrip-<n>-events-scanned)"}`
  - `{:skip, "eh=SKIP(<loud reason>)"}`
  - `{:error, "eh=FAIL(<step>:<reason>)"}`
  """

  @eh_port 5673
  @hub "popcorn-eh"
  @part "0"
  @address "/eventhubs/#{@hub}/partitions/#{@part}"
  @selector_key "apache.org:selector-filter:string"
  @latest_floor "amqp.annotation.x-opt-offset > '@latest'"
  @sasl_header "AMQP\x03\x01\x00\x00"
  @amqp_header "AMQP\x00\x01\x00\x00"

  @spec run() :: {:ok, String.t()} | {:skip, String.t()} | {:error, String.t()}
  def run do
    token = "w27-evt-" <> Integer.to_string(System.system_time(:millisecond))

    with {:ok, st} <- connect(),
         {:ok, st} <- sasl(st),
         {:ok, st} <- open_session(st),
         {:ok, st} <- arm_receiver(st),
         {:ok, st} <- publish(st, token),
         {:ok, scanned, st} <- credit_and_drain(st, token) do
      :gen_tcp.close(st.sock)
      {:ok, "eh=OK(#{@hub}/#{@part}:#{token}-roundtrip-#{scanned}-events-scanned)"}
    else
      {:skip, reason} -> {:skip, "eh=SKIP(#{reason})"}
      {:error, {step, reason}} -> {:error, "eh=FAIL(#{step}:#{fmt(reason)})"}
    end
  end

  @doc """
  Publishes `n` filler events to the pinned partition over a fresh real-wire
  connection (no receive leg). Chicago test seed: lets a test build a REAL
  backlog in the EventHubs store, then prove `run/0`'s selector floor scans
  O(new events), not O(backlog).
  """
  @spec publish_events(pos_integer()) ::
          {:ok, non_neg_integer()} | {:skip, String.t()} | {:error, String.t()}
  def publish_events(n) when is_integer(n) and n > 0 do
    with {:ok, st} <- connect(),
         {:ok, st} <- sasl(st),
         {:ok, st} <- open_session(st) do
      range = 1..n

      # sequential publishes, each awaiting its accepted disposition;
      # short-circuits on the first wire error
      result =
        Enum.reduce_while(range, {:ok, st}, fn _, {:ok, st} ->
          token = "w27-fill-" <> Integer.to_string(System.system_time(:millisecond)) <> "-#{n}"

          case publish(st, token) do
            {:ok, st} -> {:cont, {:ok, st}}
            {:error, _} = err -> {:halt, err}
          end
        end)

      :gen_tcp.close(st.sock)

      case result do
        {:ok, _} -> {:ok, n}
        {:error, {step, reason}} -> {:error, "eh=FAIL(#{step}:#{fmt(reason)})"}
      end
    else
      {:skip, reason} -> {:skip, "eh=SKIP(#{reason})"}
      {:error, {step, reason}} -> {:error, "eh=FAIL(#{step}:#{fmt(reason)})"}
    end
  end

  defp fmt(r) when is_binary(r), do: r
  defp fmt(r), do: inspect(r)

  # -- connection + SASL ANONYMOUS ------------------------------------------

  defp connect do
    case :gen_tcp.connect(~c"127.0.0.1", @eh_port, [:binary, packet: :raw, active: false], 3_000) do
      {:ok, sock} ->
        {:ok, %{sock: sock, buf: <<>>, did: 0}}

      {:error, reason} ->
        {:skip, "eh-plane-down(5673-connect-#{fmt(reason)}); run 9>&- just substrate-up"}
    end
  end

  defp sasl(st) do
    with :ok <- raw_send(st, @sasl_header),
         {:ok, _mechs, st} <- expect_desc(st, 0x40, 3_000),
         :ok <- raw_send(st, frame(0x01, 0, described(0x41, [str8("ANONYMOUS")]))) do
      case expect_desc(st, 0x44, 3_000) do
        # outcome code 0 arrives as any uint-zero encoding (ubyte 0x50 0,
        # smalluint 0x52 0, or the uint0 fast constructor 0x43)
        {:ok, <<0x50, 0, _::binary>>, st} -> {:ok, st}
        {:ok, <<0x52, 0, _::binary>>, st} -> {:ok, st}
        {:ok, <<0x43, _::binary>>, st} -> {:ok, st}

        {:ok, code_bytes, _st} ->
          take = min(4, byte_size(code_bytes))
          {:error, {"sasl-outcome", {:code_not_zero, binary_part(code_bytes, 0, take)}}}

        {:error, _} = err ->
          err
      end
    end
  end

  # -- open / begin / sender attach ------------------------------------------

  defp open_session(st) do
    with :ok <- raw_send(st, @amqp_header),
         :ok <-
           raw_send(
             st,
             frame(0x00, 0, described(0x10, [str8("popcorn-eh-client"), nil, uint(65_536)]))
           ),
         {:ok, _open, st} <- expect_desc(st, 0x10, 3_000),
         :ok <-
           raw_send(
             st,
             frame(0x00, 0, described(0x11, [nil, uint(0), uint(1000), uint(1000)]))
           ),
         {:ok, _begin, st} <- expect_desc(st, 0x11, 3_000) do
      # sender link -> the pinned partition (target composite, 7 fields)
      target = composite(0x29, [str8(@address), nil, nil, nil, nil, nil, nil])

      # attach composite: name, handle, 0=sender, snd-settle-mode,
      # rcv-settle-mode, source, target, unsettled, incomplete-unsettled,
      # initial-delivery-count
      attach =
        described(0x12, [
          str8("popcorn-eh-sender"),
          uint(0),
          bool(false),
          ubyte(1),
          nil,
          nil,
          target,
          nil,
          nil,
          uint(0)
        ])

      with :ok <- raw_send(st, frame(0x00, 0, attach)),
           {:ok, _echo, st} <- expect_desc(st, 0x12, 3_000) do
        {:ok, st}
      end
    end
  end

  # -- receiver with a PRE-PUBLISH selector floor ------------------------------
  # attach (handle 1) BEFORE the publish, with the broker-native eventPosition
  # `x-opt-offset > '@latest'`: the broker resolves the floor to the partition's
  # last-enqueued seq at attach time (connection.ex eh_parse_event_position,
  # "@latest" clause -> EventHubs.last_enqueued/1). No flow credit yet — the
  # broker holds deliveries until credit, so the floor is a true pre-publish
  # snapshot even if other producers race this connection.

  defp arm_receiver(st) do
    filter = {:dsym, @selector_key, str8(@latest_floor)}

    # source composite, 8 fields (address first, filter is field 8)
    source = composite(0x28, [str8(@address), nil, nil, nil, nil, nil, nil, filter])

    attach =
      described(0x12, [
        str8("popcorn-eh-receiver"),
        uint(1),
        bool(true),
        nil,
        nil,
        source,
        nil,
        nil,
        nil,
        uint(0)
      ])

    with :ok <- raw_send(st, frame(0x00, 0, attach)),
         {:ok, _echo, st} <- expect_desc(st, 0x12, 3_000) do
      {:ok, st}
    end
  end

  # -- publish / credit / drain ------------------------------------------------

  defp publish(st, token) do
    did = st.did

    xfer =
      described(0x14, [
        uint(0),
        uint(did),
        vbin8(:binary.copy(<<0>>, 16)),
        uint(0),
        bool(false)
      ])

    # data section: descriptor 0x75, vbin8 body
    body = [<<0x00, 0x53, 0x75>>, <<0xA0, byte_size(token), token::binary>>]

    with :ok <- raw_send(st, frame_with_payload(0x00, 0, xfer, body)) do
      case expect_desc(st, 0x15, 5_000) do
        {:ok, list_bytes, st} ->
          if accepted?(list_bytes) do
            {:ok, %{st | did: did + 1}}
          else
            take = min(8, byte_size(list_bytes))
            {:error, {"disposition", {:not_accepted, binary_part(list_bytes, 0, take)}}}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  # Grant flow credit on the receiver (handle 1) ONLY after the publish's
  # accepted disposition — the floor is already fixed at attach, so the drain
  # sees exactly the events enqueued after attach.
  defp credit_and_drain(st, token) do
    with :ok <-
           raw_send(
             st,
             frame(
               0x00,
               0,
               described(0x13, [
                 uint(1),
                 uint(1000),
                 uint(1),
                 uint(1000),
                 uint(1),
                 nil,
                 uint(20_000)
               ])
             )
           ) do
      drain(st, token, 0, 500)
    end
  end

  defp drain(_st, _token, _scanned, 0) do
    {:error, {"receive", :exhausted_budget_without_token}}
  end

  defp drain(st, token, scanned, budget) do
    case next_frame(st, 3_000) do
      {:ok, {:amqp, 0x14, _list, payload}, st} ->
        case body_data(payload) do
          ^token ->
            {:ok, scanned + 1, st}

          _other ->
            drain(st, token, scanned + 1, budget - 1)
        end

      {:ok, {:amqp, _other_desc, _list, _payload}, st} ->
        drain(st, token, scanned, budget - 1)

      {:error, _} = err ->
        err
    end
  end

  # -- minimal AMQP 1.0 codec (encode) ---------------------------------------
  # Hand-rolled against the AMQP 1.0 composite type system; only the
  # constructors this leg emits/needs are implemented. Every emitted byte is
  # real wire over :gen_tcp. Composite form: 0x00 0x53 <ulong8-desc> <list>.

  defp bool(true), do: {:bool, true}
  defp bool(false), do: {:bool, false}
  defp ubyte(v), do: {:ubyte, v}
  defp uint(v), do: {:uint, v}
  defp str8(s), do: {:str8, s}
  defp vbin8(b), do: {:vbin8, b}
  defp composite(desc, elems), do: {:composite, desc, elems}

  # described with a SYMBOL descriptor and a BARE single-component value
  # (selector filters are symbol-keyed described types whose value is the
  # clause string — NOT a composite list; the list-wrapped form detached with
  # SELECTOR_UNSUPPORTED, witnessed 2026-10-20)
  defp enc_elem({:dsym, sym, value}) do
    [<<0x00, 0xA3, byte_size(sym), sym::binary>>, enc_elem(value)]
  end

  defp described(desc, elems), do: [<<0x00, 0x53, desc>>, encode_list(elems)]

  defp encode_list(elems) do
    body =
      elems
      |> Enum.map(&enc_elem/1)
      # AMQP lists may omit trailing null fields (spec §1.4.3)
      |> Enum.reverse()
      |> Enum.drop_while(&(&1 == <<0x40>>))
      |> Enum.reverse()

    n = length(body)
    payload = IO.iodata_length(body)
    # list8 size INCLUDES the count octet (spec §1.6.12; mirrors
    # PrimitiveCodec encode: body_len + 1)
    [<<0xC0, payload + 1, n>>, body]
  end

  defp enc_elem(nil), do: <<0x40>>
  defp enc_elem(true), do: <<0x56, 1>>
  defp enc_elem(false), do: <<0x56, 0>>
  defp enc_elem({:composite, desc, elems}), do: [<<0x00, 0x53, desc>>, encode_list(elems)]
  defp enc_elem({:ubyte, v}), do: <<0x50, v>>
  defp enc_elem({:bool, v}), do: <<0x56, if(v, do: 1, else: 0)>>

  defp enc_elem({:vbin8, b}) when byte_size(b) < 256, do: <<0xA0, byte_size(b), b::binary>>
  defp enc_elem({:str8, s}) when byte_size(s) < 256, do: <<0xA1, byte_size(s), s::binary>>

  # smalluint (0x52) below 256; uint (0x70) above
  defp enc_elem({:uint, v}) when is_integer(v) and v >= 0 and v < 256, do: <<0x52, v>>

  defp enc_elem({:uint, v}) when is_integer(v) and v >= 256 and v <= 0xFFFFFFFF,
    do: <<0x70, v::32>>

  defp frame(type, channel, body) do
    body_bytes = IO.iodata_length(body)
    [<<(8 + body_bytes)::32, 2::8, type::8, channel::16>>, body]
  end

  defp frame_with_payload(type, channel, body, payload) do
    body_bytes = IO.iodata_length([body, payload])
    [<<(8 + body_bytes)::32, 2::8, type::8, channel::16>>, body, payload]
  end

  # -- minimal AMQP 1.0 codec (decode) ---------------------------------------
  # Shallow on purpose: returns {type, descriptor, performative-list bytes,
  # transfer-payload}. sasl-outcome and disposition codes are scanned
  # positionally from the list bytes.

  defp accepted?(bytes) do
    :binary.match(bytes, <<0x00, 0x53, 0x24>>) != :nomatch
  end

  # The broker prefixes the body_data section with delivery/message
  # annotations, so scan for the data-section marker anywhere in the payload
  # (mirrors Smalt.Amqp.Connection.eh_body_section_scan/1).
  defp body_data(payload) do
    case :binary.match(payload, <<0x00, 0x53, 0x75>>) do
      {pos, _} ->
        rest = binary_part(payload, pos, byte_size(payload) - pos)

        case rest do
          <<0x00, 0x53, 0x75, 0xA0, len, data::binary-size(len), _::binary>> -> data
          <<0x00, 0x53, 0x75, 0xB0, len::32, data::binary-size(len), _::binary>> -> data
          _ -> :no_body_data
        end

      :nomatch ->
        :no_body_data
    end
  end

  # -- raw socket plumbing ----------------------------------------------------

  defp raw_send(st, iodata) do
    with(:ok <- :gen_tcp.send(st.sock, iodata), do: :ok)
  end

  # Waits for the next frame with the given composite descriptor, transparently
  # consuming intermediate frames (open/begin/attach echoes ride different
  # descriptors; flow frames may interleave). Bounded by the recv timeout each
  # call, plus a frame budget so a chatty broker can't spin forever.
  defp expect_desc(st, desc, timeout, budget \\ 20)

  defp expect_desc(_st, _desc, _timeout, 0), do: {:error, {:expect, :budget_exhausted}}

  defp expect_desc(st, desc, timeout, budget) do
    case next_frame(st, timeout) do
      {:ok, {t, d, list_bytes, _payload}, st} when t in [:amqp, :sasl] and d == desc ->
        {:ok, list_bytes, st}

      {:ok, {t, _d, _l, _p}, st} when t in [:amqp, :sasl] ->
        expect_desc(st, desc, timeout, budget - 1)

      {:error, _} = err ->
        err
    end
  end

  defp next_frame(st, timeout) do
    case decode_buf(st.buf) do
      {:ok, frame, rest} ->
        {:ok, frame, %{st | buf: rest}}

      :more ->
        case :gen_tcp.recv(st.sock, 0, timeout) do
          {:ok, more} ->
            next_frame(%{st | buf: st.buf <> more}, timeout)
          {:error, reason} -> {:error, {"recv", reason}}
        end

      {:error, reason} ->
        {:error, {"decode", reason}}
    end
  end

  # Buffer -> {:ok, {frame_type, desc, list_bytes, payload}, rest} | :more | error.
  # Skips 8-byte AMQP protocol headers (they are not frames).
  defp decode_buf(<<"AMQP", _::binary>> = buf) when byte_size(buf) < 8, do: :more

  defp decode_buf(<<"AMQP", _::binary-size(4), rest::binary>>) do
    case rest do
      <<>> -> :more
      _ -> decode_buf(rest)
    end
  end

  defp decode_buf(buf) when byte_size(buf) < 8, do: :more

  defp decode_buf(<<size::32, 2::8, type::8, _chan::16, body::binary>> = buf) do
    if byte_size(buf) < size do
      :more
    else
      body_len = size - 8
      <<frame_body::binary-size(body_len), rest::binary>> = body
      decode_frame_body(type, frame_body, rest)
    end
  end

  defp decode_buf(<<_size::32, _doff::8, _type::8, _chan::16, _::binary>>) do
    {:error, :bad_frame_type}
  end

  defp decode_frame_body(0, body, rest), do: decode_frame_body(:amqp, body, rest)
  defp decode_frame_body(1, body, rest), do: decode_frame_body(:sasl, body, rest)

  defp decode_frame_body(type, <<0x00, 0x53, desc, list::binary>>, rest)
       when type in [:amqp, :sasl] do
    {list_bytes, payload} = split_list(list)
    {:ok, {type, desc, list_bytes, payload}, rest}
  end

  defp decode_frame_body(_type, _body, _rest), do: {:error, :bad_frame_body}

  # size INCLUDES the count field (mirrors PrimitiveCodec: encode emits
  # body_len + 1 for list8), so element bytes = size - count_field_width.
  defp split_list(<<0xC0, size, _count, list::binary>>) when size >= 1 do
    <<list_bytes::binary-size(size - 1), payload::binary>> = list
    {list_bytes, payload}
  end

  defp split_list(<<0xD0, size::32, _count::32, list::binary>>) when size >= 4 do
    <<list_bytes::binary-size(size - 4), payload::binary>> = list
    {list_bytes, payload}
  end

  defp split_list(_), do: {<<>>, <<>>}
end
