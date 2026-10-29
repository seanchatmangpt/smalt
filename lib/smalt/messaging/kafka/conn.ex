defmodule Smalt.Messaging.Kafka.Conn do
  @moduledoc """
  AZ-1 — one Kafka wire connection (per-connection GenServer over a raw
  gen_tcp socket, active:false blocking recv loop inside handle_continue —
  the connection process owns the socket for its lifetime, same shape as
  the AMQP connections under `Smalt.Amqp.Connection`).

  Dispatch (served matrix in `Smalt.Messaging.Kafka.Wire.version_matrix/0`):

  - ApiVersions (18) v0 — advertise the served matrix
  - Metadata (3) v0/v1 — single broker (node 0, loopback, the listener port),
    every known topic with the configured partition count
  - Produce (0) v0..v2 — verify batch CRC/magic (fail-closed) → sieve
    (`Smalt.Sync.Guard.run_guard/2`) → `Smalt.Messaging.Kafka.Log.produce/3`
  - ListOffsets (2) v0/v1 — earliest (0) / latest (high watermark)
  - Fetch (1) v0 — byte-exact batch re-serve (sealed + active frames)

  Crash-only law: a malformed request header, an unknown api_key, an
  api_version outside the advertised range, or a bad batch CRC/magic kills
  the connection (typed log + `[:smalt, :kafka, :conn_killed]` telemetry,
  socket closed) — never a best-effort parse. Named falsifier: Produce v9
  (the first flexible Produce version) must be disconnected, not parsed.

  Typed UNSUPPORTED scope (crash-only face, named in the receipt):
  transactions, log compaction, ACLs, consumer groups, flexible/compact
  encodings.
  """

  use GenServer
  require Logger

  alias Smalt.Messaging.Kafka.{Log, Records, Wire}

  @recv_timeout_ms 60_000
  @max_request_bytes 8 * 1024 * 1024

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  # -- GenServer -----------------------------------------------------------------

  @impl true
  def init(opts) do
    Process.set_label(%{service: :kafka, role: :conn})
    sock = Keyword.fetch!(opts, :socket)
    port = Keyword.fetch!(opts, :advertised_port)
    :inet.setopts(sock, buffer: 65_536)
    {:ok, %{sock: sock, port: port, buf: <<>>}, {:continue, :recv}}
  end

  @impl true
  def handle_continue(:recv, state) do
    recv_loop(state)
    {:stop, :normal, state}
  end

  # -- transport loop ------------------------------------------------------------

  defp recv_loop(%{sock: sock} = state) do
    case :gen_tcp.recv(sock, 0, @recv_timeout_ms) do
      {:ok, data} ->
        case consume(<<state.buf::binary, data::binary>>, state) do
          :closed -> :ok
          s -> recv_loop(s)
        end

      {:error, _reason} ->
        # peer closed / timeout / transport error: clean end of connection
        :gen_tcp.close(sock)
        :ok
    end
  end

  # Pull complete size-prefixed requests out of the stream buffer.
  defp consume(buf, state) do
    case buf do
      <<size::unsigned-integer-size(32), rest::binary>> when size <= @max_request_bytes ->
        if byte_size(rest) >= size do
          <<req::binary-size(^size)-unit(8), tail::binary>> = rest

          case dispatch(req, state) do
            :closed -> :closed
            state -> consume(tail, state)
          end
        else
          %{state | buf: buf}
        end

      <<size::unsigned-integer-size(32), _::binary>> ->
        kill(state, {:oversized_request, size})

      _ ->
        %{state | buf: buf}
    end
  end

  defp kill(state, reason) do
    Logger.error("[kafka] CRASH-ONLY kill: #{inspect(reason)}; connection closed")

    :telemetry.execute([:smalt, :kafka, :conn_killed], %{count: 1}, %{
      reason: reason,
      peer: peer(state)
    })

    _ = :gen_tcp.close(state.sock)
    :closed
  end

  defp peer(%{sock: sock}) do
    case :inet.peername(sock) do
      {:ok, addr} -> inspect(addr)
      _ -> "unknown"
    end
  end

  # -- dispatch ------------------------------------------------------------------

  # classic request header: api_key i16 | api_version i16 | correlation_id u32
  # | client_id string. Flexible v2 headers drop client_id — never served.
  defp dispatch(
         <<key::integer-size(16), ver::integer-size(16), corr::unsigned-integer-size(32),
           cid_len::unsigned-integer-size(16), _cid::binary-size(cid_len)-unit(8),
           body::binary>> = _req,
         state
       ) do
    supported = Map.get(Wire.version_matrix(), key)

    cond do
      is_nil(supported) ->
        kill(state, {:unknown_api_key, key})

      ver < elem(supported, 0) or ver > elem(supported, 1) ->
        # KIP-183: unsupported ApiVersions is the one exception to the
        # crash-only law — real brokers answer a v0-shaped body with
        # error 35 UNSUPPORTED_VERSION so the client can downgrade
        # (kafka-python check_version negotiates exactly this way);
        # everything else outside the matrix still kills.
        if key == 18 do
          send_response(state.sock, corr, [<<35::signed-integer-size(16), 0::integer-size(32)>>])

          state
        else
          kill(state, {:unsupported_version, key, ver})
        end

      true ->
        route(key, ver, corr, body, state)
      end
  end

  defp dispatch(_req, state) do
    kill(state, :malformed_request_header)
  end

  defp route(2, ver, corr, body, state),
    do: route_list_offsets(2, ver, corr, body, state)

  defp route(1, ver, corr, body, state), do: route_fetch(1, ver, corr, body, state)
  # -- ApiVersions v0 ------------------------------------------------------------

  defp route(18, 0, corr, _body, state) do
    entries =
      Wire.version_matrix()
      |> Enum.sort()
      |> Enum.map(fn {k, {lo, hi}} ->
        <<k::integer-size(16), lo::integer-size(16), hi::integer-size(16)>>
      end)

    body = [<<0::signed-integer-size(16), length(entries)::integer-size(32)>>, entries]
    send_response(state.sock, corr, body)
    state
  end

  # -- Metadata v0/v1 ------------------------------------------------------------

  defp route(3, ver, corr, _body, state) do
    topics = Log.list_topics()
    parts = Log.partition_count()

    # MetadataResponse v0: brokers(id,host,port) | topics(err,topic,partitions
    # (err,partition,leader,replicas[],isr[])). v1 adds rack per broker,
    # controller_id, and is_internal per topic (cluster_id arrives only in
    # v2+, which this face does not serve).
    rack = if ver >= 1, do: [<<-1::signed-integer-size(16)>>], else: []
    controller = if ver >= 1, do: [<<0::integer-size(32)>>], else: []

    topic_blocks =
      Enum.map(topics, fn t ->
        part_blocks =
          Enum.map(0..(parts - 1), fn p ->
            # err i16 | partition i32 | leader i32 | replicas[1]=[0] | isr[1]=[0]
            <<
              0::signed-integer-size(16), p::integer-size(32), 0::integer-size(32),
              1::integer-size(32), 0::integer-size(32), 1::integer-size(32),
              0::integer-size(32)
            >>
          end)

        is_internal = if ver >= 1, do: [<<0::integer-size(8)>>], else: []

        [
          <<0::signed-integer-size(16), byte_size(t)::unsigned-integer-size(16), t::binary>>,
          is_internal,
          <<parts::integer-size(32)>>,
          part_blocks
        ]
      end)

    broker = [
      <<0::integer-size(32), 9::integer-size(16)>>,
      "127.0.0.1",
      <<state.port::integer-size(32)>>,
      rack
    ]

    resp = [
      <<1::integer-size(32)>>,
      broker,
      controller,
      <<length(topic_blocks)::integer-size(32)>>,
      topic_blocks
    ]

    send_response(state.sock, corr, resp)
    state
  end

  # -- Produce v0..v2 --------------------------------------------------------------

  defp route(0, ver, corr, body, state) do

    case parse_produce(body) do
      {:ok, entries} ->
        results =
          Enum.map(entries, fn {topic, parts} ->
            part_blocks =
              Enum.map(parts, fn {p, raw_set} ->
                {err, base} = produce_partition(topic, p, raw_set)

                # ProduceResponse partition block: partition i32 |
                # error_code i16 | base_offset i64 (| timestamp i64 in v2).
                case ver do
                  v when v <= 1 ->
                    [<<p::signed-integer-size(32), err::signed-integer-size(16),
                       base::signed-integer-size(64)>>]

                  _ ->
                    [<<p::signed-integer-size(32), err::signed-integer-size(16),
                       base::signed-integer-size(64), -1::signed-integer-size(64)>>]
                end
              end)

            [
              <<byte_size(topic)::unsigned-integer-size(16), topic::binary>>,
              <<length(part_blocks)::integer-size(32)>>,
              part_blocks
            ]
          end)

        # ProduceResponse v1/v2 carry throttle_time_ms AFTER the topics array.
        throttle = if ver >= 1, do: [<<0::integer-size(32)>>], else: []

        send_response(state.sock, corr, [
          <<length(results)::integer-size(32)>>,
          results,
          throttle
        ])

        state

      :kill ->
        kill(state, :malformed_produce_request)
    end
  catch
    {:kill_batch, reason} -> kill(state, {:corrupt_batch, reason})
  end

  # Verify every batch fail-closed (magic 2 + CRC32C) BEFORE anything is
  # stored; a bad batch kills the connection (crash-only law).
  defp produce_partition(topic, p, raw_set) do
    batches =
      case Records.parse_message_set(raw_set) do
        {:ok, batches} ->
          Enum.each(batches, fn b ->
            case Records.verify_batch(b) do
              :ok -> :ok
              {:error, reason} -> throw({:kill_batch, reason})
            end
          end)

          batches

        {:error, reason} ->
          throw({:kill_batch, reason})
      end

    # EXPL-4 F4: the partition-index bound is enforced at the wire face —
    # produce to an unserved {topic, partition} answers error 3, never
    # auto-creates an unbounded partition.
    if Log.partition_known?(topic, p) do
      case Log.produce(topic, p, batches) do
        {:ok, base, _count} -> {0, base}
        {:error, {:policy_violation, _reason}} -> {Wire.error_code(:policy_violation), -1}
        {:error, _} -> {Wire.error_code(:corrupt_message), -1}
      end
    else
      {Wire.error_code(:unknown_topic_or_partition), -1}
    end
  end

  defp parse_produce(<<_acks::integer-size(16), _timeout::integer-size(32),
                       n::integer-size(32), rest::binary>>),
    do: take_topic_sets(rest, n, [])

  defp parse_produce(_), do: :kill

  defp take_topic_sets(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp take_topic_sets(
         <<tlen::unsigned-integer-size(16), topic::binary-size(tlen)-unit(8),
           nparts::integer-size(32), rest::binary>>,
         n,
         acc
       ) do
    {parts, rest} = take_partitions(rest, nparts, [])
    take_topic_sets(rest, n - 1, [{topic, parts} | acc])
  end

  defp take_topic_sets(_, _, _), do: :kill

  defp take_partitions(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp take_partitions(
         <<p::integer-size(32), set_size::integer-size(32), set::binary-size(set_size)-unit(8),
           rest::binary>>,
         n,
         acc
       )
       when set_size >= 0,
       do: take_partitions(rest, n - 1, [{p, set} | acc])

  defp take_partitions(_, _, _), do: :kill

  # -- ListOffsets v0/v1 -----------------------------------------------------------

  defp route_list_offsets(2, ver, corr, body, state) do

    case parse_list_offsets(body, ver) do
      {:ok, entries} ->
        results =
          Enum.map(entries, fn {topic, parts} ->
            blocks =
              Enum.map(parts, fn {p, ts, max_num} ->
                # EXPL-4 F4: unknown {topic, partition} answers error 3
                # (UNKNOWN_TOPIC_OR_PARTITION), never an empty success with
                # error 0.
                known = Log.partition_known?(topic, p)
                err = if known, do: 0, else: Wire.error_code(:unknown_topic_or_partition)
                hwm = Log.high_watermark(topic, p)

                offset =
                  cond do
                    not known -> -1
                    ts == -2 -> 0
                    hwm > 0 -> hwm
                    true -> 0
                  end

                # OffsetResponse v0 block: partition i32 | error_code i16 |
                # offsets[] (array of Int64). v1: partition i32 | error_code
                # i16 | timestamp i64 | offset i64.
                base = <<
                  p::signed-integer-size(32), err::signed-integer-size(16)
                >>

                if ver == 0 do
                  offs =
                    if max_num == 0,
                      do: <<0::integer-size(32)>>,
                      else: [
                        <<1::integer-size(32)>>,
                        <<offset::signed-integer-size(64)>>
                      ]

                  [base, offs]
                else
                  [
                    base,
                    <<-1::signed-integer-size(64), offset::signed-integer-size(64)>>
                  ]
                end
              end)

            [
              <<byte_size(topic)::unsigned-integer-size(16), topic::binary>>,
              <<length(blocks)::integer-size(32)>>,
              blocks
            ]
          end)

        send_response(state.sock, corr, [<<length(results)::integer-size(32)>>, results])
        state

      :kill ->
        kill(state, :malformed_list_offsets_request)
    end
  end

  defp parse_list_offsets(<<_replica::integer-size(32), n::integer-size(32), rest::binary>>, ver),
    do: take_lo_topics(rest, n, [], ver)

  defp parse_list_offsets(_, _), do: :kill

  defp take_lo_topics(_rest, 0, acc, _ver), do: {:ok, Enum.reverse(acc)}

  defp take_lo_topics(
         <<tlen::unsigned-integer-size(16), topic::binary-size(tlen)-unit(8),
           nparts::integer-size(32), rest::binary>>,
         n,
         acc,
         ver
       ) do
    {parts, rest} = take_lo_partitions(rest, nparts, [], ver)
    take_lo_topics(rest, n - 1, [{topic, parts} | acc], ver)
  end

  defp take_lo_topics(_, _, _, _), do: :kill

  defp take_lo_partitions(rest, 0, acc, _ver), do: {Enum.reverse(acc), rest}

  defp take_lo_partitions(
         <<p::integer-size(32), ts::signed-integer-size(64), rest::binary>>,
         n,
         acc,
         ver = 1
       ) do
    take_lo_partitions(rest, n - 1, [{p, ts, nil} | acc], ver)
  end

  defp take_lo_partitions(
         <<p::integer-size(32), ts::signed-integer-size(64), max_num::integer-size(32),
           rest::binary>>,
         n,
         acc,
         ver = 0
       ) do
    take_lo_partitions(rest, n - 1, [{p, ts, max_num} | acc], ver)
  end

  defp take_lo_partitions(_, _, _, _), do: :kill

  # -- Fetch v0 ---------------------------------------------------------------------

  defp route_fetch(1, ver, corr, body, state) do

    case parse_fetch(body, ver) do
      {:ok, entries} ->
        results =
          Enum.map(entries, fn {topic, parts} ->
            blocks =
              Enum.map(parts, fn {p, fetch_offset, max_bytes} ->
                # EXPL-4 F4: unknown {topic, partition} answers error 3 with
                # an empty payload, never an empty success.
                known = Log.partition_known?(topic, p)
                err = if known, do: 0, else: Wire.error_code(:unknown_topic_or_partition)
                hwm = if known, do: Log.high_watermark(topic, p), else: 0
                batches = if known, do: Log.fetch(topic, p, fetch_offset), else: []
                payload = take_batches(batches, max_bytes, ver)

                # FetchResponse v0 partition block: partition i32 |
                # error_code i16 | highwater_offset i64 | message_set bytes.
                [
                  <<
                    p::signed-integer-size(32), err::signed-integer-size(16),
                    hwm::signed-integer-size(64)
                  >>,
                  <<IO.iodata_length(payload)::unsigned-integer-size(32)>>,
                  payload
                ]
              end)

            [
              <<byte_size(topic)::unsigned-integer-size(16), topic::binary>>,
              <<length(blocks)::integer-size(32)>>,
              blocks
            ]
          end)

        # FetchResponse v1/v2 prepend throttle_time_ms before the topics array.
        throttle = if ver >= 1, do: [<<0::integer-size(32)>>], else: []

        send_response(state.sock, corr, [
          throttle,
          <<length(results)::integer-size(32)>>,
          results
        ])

        state

      :kill ->
        kill(state, :malformed_fetch_request)
    end
  catch
    # KD-181: a stored batch that fails to down-convert (parse-refused at
    # fetch time — never expected on a produce-verified batch, so it is a
    # crash-only face, not a best-effort skip).
    {:down_convert_failed, reason} -> kill(state, {:down_convert_failed, reason})
  end

  # FetchRequest v0/v1/v2 share the v0 schema (the top-level max_bytes
  # field arrives only in v3+).
  defp parse_fetch(<<_replica::integer-size(32), _max_wait::integer-size(32),
                     _min_bytes::integer-size(32), n::integer-size(32), rest::binary>>, _ver) do
    take_f_topics(rest, n, [])
  end

  # Fail-closed fallback for malformed Fetch request bodies (typed :kill,
  # never a partial admit). Kept from the v0-only parser; arity repaired to
  # match the call site (parse_fetch/2) so the arm is reachable again.
  defp parse_fetch(_, _), do: :kill

  defp take_f_topics(_rest, 0, acc), do: {:ok, Enum.reverse(acc)}

  defp take_f_topics(
         <<tlen::unsigned-integer-size(16), topic::binary-size(tlen)-unit(8),
           nparts::integer-size(32), rest::binary>>,
         n,
         acc
       ) do
    {parts, rest} = take_f_partitions(rest, nparts, [])
    take_f_topics(rest, n - 1, [{topic, parts} | acc])
  end

  defp take_f_topics(_, _, _), do: :kill

  defp take_f_partitions(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp take_f_partitions(
         <<p::integer-size(32), off::signed-integer-size(64), max_bytes::integer-size(32),
           rest::binary>>,
         n,
         acc
       ) do
    take_f_partitions(rest, n - 1, [{p, off, max_bytes} | acc])
  end

  defp take_f_partitions(_, _, _), do: :kill

  # Fetch-side message-set framing: {int64 offset, int32 size, batch bytes}
  # — honoring the client's per-partition max_bytes budget.
  #
  # KD-181 down-conversion: on a Fetch v0/v1 request (api_version <= 1) a
  # stored magic-2 RecordBatch is re-encoded as legacy message-set v0 frames
  # (real Kafka's down-conversion semantics) — the witnessed defect served
  # the magic-2 bytes verbatim as a garbage legacy record to a low-version
  # client. v2 fetches keep the byte-exact verbatim serve.
  defp take_batches(batches, max_bytes, ver) do
    {acc, _} =
      Enum.reduce_while(batches, {[], max_bytes}, fn %{base_offset: base, raw: raw},
                                                     {acc, budget} ->
        served = serve_batch(base, raw, ver)
        framed = IO.iodata_length(served)

        cond do
          budget <= 0 ->
            {:halt, {acc, budget}}

          acc != [] and framed > budget ->
            {:halt, {acc, budget}}

          true ->
            {:cont, {[acc, served], budget - framed}}
        end
      end)

    acc
  end

  # KD-COVERS: KD-181 — version-dispatched fetch face.
  defp serve_batch(base, raw, ver) do
    case raw do
      <<_::binary-size(16), 2::integer-size(8), _::binary>> when ver <= 1 ->
        down_convert(base, raw)

      <<_::binary-size(16), 2::integer-size(8), _::binary>> ->
        # v2 fetch: byte-exact verbatim serve (offset was broker-stamped).
        [<<base::signed-integer-size(64), byte_size(raw)::unsigned-integer-size(32)>>, raw]

      legacy ->
        # Legacy stored frame keeps its {offset, size} wrapper:
        # serve the stored bytes verbatim (offset was stamped).
        legacy
    end
  end

  # Re-encode a stored magic-2 RecordBatch as legacy message-set v0 frames.
  # The record list comes from the same parser the produce face verifies
  # (Records.parse_records/1 — the count cross-check fires here too, typed
  # throw on any mismatch). Offsets are stamped per record: base + index
  # (offset_delta is the record index in a well-formed batch) — the legacy
  # wrapper {offset i64, size i32} is the only offset face on this wire
  # format; the broker-assigned base lives in the stored batch's own
  # baseOffset field AND lands in each down-converted wrapper offset
  # (dual stamp, BK-KFKV-1 law).
  defp down_convert(base, raw) do
    case Records.parse_records(raw) do
      {:ok, records} ->
        records
        |> Enum.with_index()
        |> Enum.map(fn {rec, i} -> legacy_frame(base + i, rec) end)

      {:error, reason} ->
        throw({:down_convert_failed, reason})
    end
  end

  # Legacy message-set v0 record (message format v0): crc u32 | magic 0 |
  # attributes 0 | keyLen i32 | key | valueLen i32 | value. IEEE CRC32 over
  # everything after the CRC field — the same face Records.verify_batch/1
  # checks on the legacy produce side.
  defp legacy_frame(offset, %{key: key, value: value}) do
    key_part = if key, do: <<byte_size(key)::signed-32, key::binary>>, else: <<-1::signed-32>>

    value_part =
      if value, do: <<byte_size(value)::signed-32, value::binary>>, else: <<-1::signed-32>>

    body = <<0::8>> <> key_part <> value_part
    frame = <<:erlang.crc32(<<0::8, body::binary>>)::unsigned-32, 0::8, body::binary>>

    [
      <<offset::signed-integer-size(64), IO.iodata_length(frame)::unsigned-integer-size(32)>>,
      frame
    ]
  end

  # -- shared ---------------------------------------------------------------------

  defp send_response(sock, corr, body) do
    payload = IO.iodata_length(body) + 4

    :gen_tcp.send(sock, [
      <<payload::unsigned-integer-size(32), corr::unsigned-integer-size(32)>>,
      body
    ])
  end
end
