defmodule Smalt.Egress.KinesisRoutes do
  @moduledoc """
  K-IN lane (v26.11.6+): AWS Kinesis JSON protocol face over the SAME event
  store the Event Hubs lanes use (hub = stream), so a Kinesis PutRecord and
  its Event Hubs twin meet in one partition row (KD-KIN-4).

  Wire shape:

      POST /
      Authorization: AWS4-HMAC-SHA256 Credential=AKID/date/region/kinesis/aws4_request, ...
      X-Amz-Target: Kinesis_20131202.PutRecord
      Content-Type: application/x-amz-json-1.1
      {"StreamName": "...", "Data": "<base64>", "PartitionKey": "..."}

  Contract:

    * `X-Amz-Target` is stripped of the `Kinesis_20131202.` prefix and
      dispatched; unknown targets are a typed 400 `InvalidActionException`.
    * SigV4 dual posture (KD-KIN-1): when `config :smalt, :kinesis` pins a
      key/region, requests are verified for real via `:aws_signature` — the
      library is sign-only, so verification is re-sign-and-compare over the
      client's own SignedHeaders list. Unpinned (dev) admits any non-blank
      AWS4-HMAC-SHA256 header; a missing header is a typed 403
      `UnrecognizedClientException`.
    * Shard registry pinned at 2 shards (`shardId-000000000000/001`); the
      pk->shard routing law is KD-76 (md5 first byte rem 2), mirrored from
      `Smalt.Egress.EventHubsRestRoutes` so a Kinesis record and its Event
      Hubs twin for the same key land in the same store row.
    * SequenceNumber rendering is a plain decimal (`Integer.to_string/1`),
      NOT the real service's 56-digit zero-padded form (KD-KIN-2).
    * Iterator tokens are W-close by construction:
      `Base.url_encode64("\#{stream}|\#{shard}|\#{after_seq}")`.
    * >1 MiB PutRecord Data is a typed 400 `InvalidArgumentException`; over
      the transport body cap is `PayloadTooLargeException`.
    * Errors render `{"__type": "com.amazonaws.kinesis#<Code>",
      "message": ...}`; `ResourceNotFoundException` is at 400 (botocore
      metadata law).
    * When `config :smalt, :kinesis_streams` pins a stream list, an unknown
      stream is a typed 400 `ResourceNotFoundException`.
  """
  use Plug.Router
  import Smalt.EgressRouter, except: [match: 2, match: 3, dispatch: 2, send_json: 3, route_not_ready: 1]
  plug :match
  plug :dispatch

  alias Smalt.Messaging.EventHubs

  @target_prefix "Kinesis_20131202."
  @max_body_bytes 4_194_304
  @max_record_bytes 1_048_576
  @max_records_limit 10_000
  @pinned_shards 2

  post "/" do
    conn
    |> kinesis_arm()
    |> halt_if_sent()
  end

  # Same guard as Smalt.Egress.EventHubsRestRoutes.halt_if_sent/1 (kd07 class:
  # a sent response that returns un-halted falls through to the next router in
  # the mount chain and AlreadySentErrors there).
  defp halt_if_sent(conn) do
    if conn.state in [:sent, :chunked] or conn.halted do
      Plug.Conn.halt(conn)
    else
      conn
    end
  end

  match _ do
    conn
  end

  defp kinesis_arm(conn) do
    if :ets.info(:smalt_eh_partitions) == :undefined do
      route_not_ready(conn)
    else
      with {:ok, body, conn} <- read_capped_body(conn),
           :ok <- verify_sigv4(conn, body) do
        case dispatch_target(conn, body) do
          {:resp, status, code, message} -> send_error(conn, status, code, message)
          conn -> conn
        end
      else
        {:resp, status, code, message} -> send_error(conn, status, code, message)
      end
    end
  end

  # -- target dispatch ---------------------------------------------------------

  defp dispatch_target(conn, body) do
    case get_req_header(conn, "x-amz-target") do
      [target] ->
        case strip_prefix(String.trim(target)) do
          {:ok, action} -> dispatch_action(conn, action, body)
          :error -> {:resp, 400, "InvalidActionException", "invalid X-Amz-Target"}
        end

      _ ->
        {:resp, 400, "MissingAuthenticationTokenException", "missing X-Amz-Target header"}
    end
  end

  defp strip_prefix(@target_prefix <> rest), do: {:ok, rest}
  defp strip_prefix(_other), do: :error

  defp dispatch_action(conn, action, body) do
    case parse_json_body(body) do
      {:ok, req} ->
        case action do
          "PutRecord" -> put_record(conn, req)
          "PutRecords" -> put_records(conn, req)
          "GetShardIterator" -> get_shard_iterator(conn, req)
          "GetRecords" -> get_records(conn, req)
          "ListShards" -> list_shards(conn, req)
          "DescribeStream" -> describe_stream(conn, req)
          "ListStreams" -> list_streams(conn)
          _unknown -> {:resp, 400, "InvalidActionException", "unsupported operation #{action}"}
        end

      {:resp, _, _, _} = resp ->
        resp
    end
  end

  defp parse_json_body(""), do: {:resp, 400, "SerializationException", "empty request body"}

  defp parse_json_body(body) do
    case Jason.decode(body) do
      {:ok, req} -> {:ok, req}
      {:error, _} -> {:resp, 400, "SerializationException", "request body is not valid JSON"}
    end
  end

  # -- body cap ----------------------------------------------------------------

  # Transport cap (4 MiB): real Kinesis refuses oversized payloads with a
  # typed 400. The per-record 1 MiB law is enforced per Data element below.
  defp read_capped_body(conn) do
    case read_body(conn, length: @max_body_bytes) do
      {:ok, body, conn} ->
        {:ok, body, conn}

      {:more, _, _} ->
        {:resp, 400, "PayloadTooLargeException", "request body exceeds the transport cap"}

      {:error, _} ->
        {:resp, 400, "SerializationException", "request body could not be read"}
    end
  end

  # -- SigV4 dual posture (KD-KIN-1) -------------------------------------------

  # Pinned posture: `config :smalt, :kinesis` = %{access_key_id:, secret_access_key:, region:}
  # (keyword form accepted too). aws_signature is sign-only, so verification
  # is re-sign-and-compare: re-sign the request over exactly the client's own
  # SignedHeaders list and compare signatures.
  defp verify_sigv4(conn, body) do
    pin = Application.get_env(:smalt, :kinesis)

    case get_req_header(conn, "authorization") do
      [] ->
        {:resp, 403, "UnrecognizedClientException",
         "missing AWS4-HMAC-SHA256 authorization header"}

      [auth] ->
        cond do
          String.trim(auth) == "" ->
            {:resp, 403, "UnrecognizedClientException", "blank authorization header"}

          is_nil(pin) ->
            :ok

          true ->
            verify_pinned(conn, body, auth, sigv4_pin(pin))
        end

      [_multiple] ->
        {:resp, 403, "UnrecognizedClientException", "multiple authorization headers"}
    end
  end

  defp sigv4_pin(%{} = pin) do
    %{
      access_key_id: pin[:access_key_id] || pin["access_key_id"],
      secret_access_key: pin[:secret_access_key] || pin["secret_access_key"],
      region: pin[:region] || pin["region"]
    }
  end

  defp sigv4_pin(pin) when is_list(pin) do
    sigv4_pin(%{
      access_key_id: pin[:access_key_id],
      secret_access_key: pin[:secret_access_key],
      region: pin[:region]
    })
  end

  defp verify_pinned(conn, body, auth, pin) do
    case parse_sigv4_header(auth) do
      {:ok, parsed} ->
        headers = signed_headers_of(conn, parsed.signed_headers)
        re_sign_and_compare(conn, body, headers, parsed, pin)

      :error ->
        {:resp, 403, "InvalidSignatureException", "malformed authorization header"}
    end
  end

  defp parse_sigv4_header("AWS4-HMAC-SHA256 " <> rest) do
    kv =
      rest
      |> String.split(",", trim: true)
      |> Map.new(fn part ->
        case String.split(String.trim(part), "=", parts: 2) do
          [k, v] -> {String.trim(k), String.trim(v)}
          [k] -> {String.trim(k), ""}
        end
      end)

    with credential when is_binary(credential) <- Map.get(kv, "Credential"),
         signed when is_binary(signed) <- Map.get(kv, "SignedHeaders"),
         signature when is_binary(signature) <- Map.get(kv, "Signature"),
         [akid, date, region, service, "aws4_request"] <-
           String.split(credential, "/", parts: 5) do
      {:ok,
       %{
         akid: akid,
         date: date,
         region: region,
         service: service,
         signed_headers: String.split(signed, ";"),
         signature: String.downcase(signature)
       }}
    else
      _ -> :error
    end
  end

  defp parse_sigv4_header(_other), do: :error

  defp signed_headers_of(conn, names) do
    # Only request-PRESENT headers re-enter the re-sign. aws_signature
    # re-injects its own canonical headers (x-amz-content-sha256 from the
    # body, x-amz-date); feeding absent headers as empty values diverges the
    # canonical string from the client's (witnessed: empty sha256 ->
    # signature mismatch on a byte-identical client twin). Names are deduped
    # first: the lib's own SignedHeaders string can carry duplicate entries
    # (witnessed "x-amz-date;x-amz-date"), and duplicated canonical headers
    # re-sign to a different signature than the client's single entry.
    names
    |> Enum.uniq()
    |> Enum.flat_map(fn name ->
      case get_req_header(conn, name) do
        [value | _] -> [{name, value}]
        [] -> []
      end
    end)
  end

  defp re_sign_and_compare(conn, body, headers, parsed, pin) do
    with {:ok, datetime} <- scope_and_date(conn, parsed) do
      computed =
        :aws_signature.sign_v4(
          "#{pin.access_key_id}",
          "#{pin.secret_access_key}",
          "#{parsed.region}",
          "kinesis",
          datetime,
          "POST",
          "https://localhost/",
          Enum.map(headers, fn {k, v} -> {"#{k}", "#{v}"} end),
          body
        )

      case Enum.find(computed, fn {k, _v} -> k == "Authorization" end) do
        {"Authorization", computed_auth} ->
          case extract_signature(computed_auth) do
            sig when sig == parsed.signature -> :ok
            _ -> {:resp, 403, "InvalidSignatureException", "signature mismatch"}
          end

        _ ->
          {:resp, 403, "InvalidSignatureException",
           "re-sign did not yield an authorization header"}
      end
    else
      {:resp, _, _, _} = resp -> resp
    end
  end

  # x-amz-date must be present and agree with the Credential scope date; a
  # scope dated for another day is a typed 403 (real service semantics).
  defp scope_and_date(conn, parsed) do
    case get_req_header(conn, "x-amz-date") do
      [x_amz_date | _] ->
        cond do
          not String.starts_with?(x_amz_date, parsed.date) ->
            {:resp, 403, "InvalidSignatureException", "credential scope date != x-amz-date"}

          true ->
            parse_amz_datetime(x_amz_date)
        end

      [] ->
        {:resp, 403, "InvalidSignatureException", "missing x-amz-date header"}
    end
  end

  defp parse_amz_datetime(bin) do
    with <<y::binary-size(4), mo::binary-size(2), d::binary-size(2), "T", h::binary-size(2),
           mi::binary-size(2), s::binary-size(2), "Z">> <- bin,
           {y, ""} <- Integer.parse(y),
           {mo, ""} <- Integer.parse(mo),
           {d, ""} <- Integer.parse(d),
           {h, ""} <- Integer.parse(h),
           {mi, ""} <- Integer.parse(mi),
           {s, ""} <- Integer.parse(s) do
      {:ok, {{y, mo, d}, {h, mi, s}}}
    else
      _ -> {:resp, 403, "InvalidSignatureException", "unparseable x-amz-date"}
    end
  end

  defp extract_signature("AWS4-HMAC-SHA256 " <> rest) do
    rest
    |> String.split(",", trim: true)
    |> Enum.find_value(fn part ->
      case String.split(String.trim(part), "=", parts: 2) do
        ["Signature", sig] -> String.downcase(sig)
        _ -> nil
      end
    end)
  end

  # -- shard law (KD-76 reuse, never re-derive) --------------------------------

  @doc """
  KD-76 shard routing, mirrored from `Smalt.Egress.EventHubsRestRoutes`
  pk_partition/1 verbatim (same md5-first-byte law, same pinned set size of
  2) so a Kinesis record and its Event Hubs twin for the same key land in
  the same store row (KD-KIN-4). Mirrors
  `Smalt.Amqp.Connection.eh_pk_partition/1`, the law's canonical home.
  """
  def pk_partition(pk) do
    bin = if is_binary(pk), do: pk, else: :erlang.term_to_binary(pk)
    <<first::unsigned-8, _::binary>> = :erlang.md5(bin)
    Integer.to_string(rem(first, @pinned_shards))
  end

  defp shard_id(idx) when idx >= 0 and idx < @pinned_shards do
    "shardId-" <> String.pad_leading(Integer.to_string(idx), 12, "0")
  end

  defp shard_index(shard) do
    case shard_index_str(shard) do
      {:ok, idx} when idx >= 0 and idx < @pinned_shards -> {:ok, idx}
      {:ok, _} -> {:resp, 400, "ResourceNotFoundException", "shard not found"}
      {:resp, _, _, _} = resp -> resp
    end
  end

  defp shard_index_str("shardId-" <> rest) do
    digits = String.trim_leading(rest, "0")
    digits = if digits == "", do: "0", else: digits

    case Integer.parse(digits) do
      {n, ""} -> {:ok, n}
      _ -> {:resp, 400, "ResourceNotFoundException", "invalid shard id"}
    end
  end

  defp shard_index_str(_other) do
    {:resp, 400, "ResourceNotFoundException", "invalid shard id"}
  end

  defp stream_known?(stream) do
    case Application.get_env(:smalt, :kinesis_streams) do
      streams when is_list(streams) ->
        if stream in streams do
          :ok
        else
          {:resp, 400, "ResourceNotFoundException",
           "Stream #{stream} under account #{account_id()} not found."}
        end

      _ ->
        :ok
    end
  end

  defp account_id, do: Application.get_env(:smalt, :kinesis_account_id, "smalt")

  # -- PutRecord / PutRecords --------------------------------------------------

  defp put_record(conn, req) do
    with {:ok, stream} <- fetch_stream(req),
         :ok <- stream_known?(stream),
         {:ok, data} <- fetch_data(req),
         :ok <- check_record_size(data),
         {:ok, pk} <- fetch_partition_key(req) do
      publish(conn, stream, [%{data: data, pk: pk}], :single)
    else
      {:resp, _, _, _} = resp -> resp
    end
  end

  defp put_records(conn, req) do
    with {:ok, stream} <- fetch_stream(req),
         :ok <- stream_known?(stream),
         {:ok, records} <- fetch_records(req),
         {:ok, prepared} <- prepare_records(records) do
      publish(conn, stream, prepared, :batch)
    else
      {:resp, _, _, _} = resp -> resp
    end
  end

  defp prepare_records(records) do
    Enum.reduce_while(records, {:ok, []}, fn rec, {:ok, acc} ->
      with {:ok, data} <- fetch_data(rec),
           :ok <- check_record_size(data),
           {:ok, pk} <- fetch_partition_key(rec) do
        {:cont, {:ok, acc ++ [%{data: data, pk: pk}]}}
      else
        {:resp, _, _, _} = resp -> {:halt, resp}
      end
    end)
  end

  defp fetch_stream(req) do
    case req do
      %{"StreamName" => s} when is_binary(s) and s != "" -> {:ok, s}
      _ -> {:resp, 400, "InvalidArgumentException", "StreamName is required"}
    end
  end

  defp fetch_data(req) do
    case req do
      %{"Data" => data} when is_binary(data) ->
        case Base.decode64(data) do
          {:ok, decoded} -> {:ok, decoded}
          :error -> {:resp, 400, "InvalidArgumentException", "Data is not valid base64"}
        end

      _ ->
        {:resp, 400, "InvalidArgumentException", "Data is required"}
    end
  end

  defp fetch_partition_key(req) do
    case req do
      %{"PartitionKey" => pk} when is_binary(pk) and pk != "" -> {:ok, pk}
      _ -> {:resp, 400, "InvalidArgumentException", "PartitionKey is required"}
    end
  end

  defp fetch_records(req) do
    case req do
      %{"Records" => records} when is_list(records) ->
        if length(records) > 500 do
          {:resp, 400, "InvalidArgumentException", "Records exceeds the 500 entry limit"}
        else
          {:ok, records}
        end

      _ ->
        {:resp, 400, "InvalidArgumentException", "Records is required"}
    end
  end

  defp check_record_size(data) do
    if byte_size(data) > @max_record_bytes do
      {:resp, 400, "InvalidArgumentException", "Record Data exceeds the 1 MiB limit"}
    else
      :ok
    end
  end

  # Kinesis success is ALWAYS 200 with a JSON body carrying ShardId +
  # SequenceNumber (never a 201-empty; that shape belongs to the EH face).
  defp publish(conn, stream, records, :single) do
    case do_publish(stream, records) do
      [%{shard_id: sid, sequence_number: seq}] ->
        send_json(conn, 200, %{"ShardId" => sid, "SequenceNumber" => seq})

      [{:error, face}] ->
        {:resp, 400, "LimitExceededException", "publish throttled: #{inspect(face)}"}
    end
  end

  defp publish(conn, stream, records, :batch) do
    results = do_publish(stream, records)

    failed = Enum.count(results, &match?({:error, _}, &1))

    body = %{
      "FailedRecordCount" => failed,
      "Records" =>
        Enum.map(results, fn
          %{shard_id: sid, sequence_number: seq} -> %{"ShardId" => sid, "SequenceNumber" => seq}
          {:error, _face} -> nil
        end)
    }

    send_json(conn, 200, body)
  end

  defp do_publish(stream, records) do
    Enum.map(records, fn %{data: data, pk: pk} ->
      idx = String.to_integer(pk_partition(pk))
      partition = "#{stream}/partitions/#{pk_partition(pk)}"

      case EventHubs.send_event(partition, data, partition_key: pk) do
        {:ok, seq, _event} ->
          %{shard_id: shard_id(idx), sequence_number: Integer.to_string(seq)}

        {:error, {:throttled, face}} ->
          {:error, face}
      end
    end)
  end

  # -- shard iteration ---------------------------------------------------------

  defp get_shard_iterator(conn, req) do
    with {:ok, stream} <- fetch_stream(req),
         :ok <- stream_known?(stream),
         {:ok, _idx} <- shard_index(req["ShardId"]),
         {:ok, after_seq} <- resolve_shard_iterator(stream, req["ShardId"], req) do
      token = Base.url_encode64("#{stream}|#{req["ShardId"]}|#{after_seq}")
      send_json(conn, 200, %{"ShardIterator" => token})
    else
      {:resp, _, _, _} = resp -> resp
    end
  end

  defp resolve_shard_iterator(stream, shard, req) do
    partition = partition_of(stream, shard)

    case req["ShardIteratorType"] do
      "TRIM_HORIZON" ->
        {:ok, 0}

      "LATEST" ->
        {:ok, latest_seq(partition)}

      "AT_SEQUENCE_NUMBER" ->
        {:ok, req_seq(req) - 1}

      "AFTER_SEQUENCE_NUMBER" ->
        {:ok, req_seq(req)}

      "AT_TIMESTAMP" ->
        at_timestamp_after_seq(partition, req["Timestamp"])

      _other ->
        {:resp, 400, "InvalidArgumentException", "ShardIteratorType is required"}
    end
  end

  # AT_TIMESTAMP: first event enqueued at-or-after the timestamp; the iterator
  # lands one BEFORE it (receive_events is exclusive on after_seq), so the
  # first GetRecords record is that event. No qualifying event (or no
  # timestamp at all) falls back to TRIM_HORIZON / a typed 400.
  defp at_timestamp_after_seq(partition, ts) when is_number(ts) do
    ts_ms = trunc(ts * 1000)

    first =
      partition_events(partition)
      |> Enum.find(fn ev -> ev["enqueued"] >= ts_ms end)

    case first do
      nil -> {:ok, 0}
      ev -> {:ok, ev["seq"] - 1}
    end
  end

  defp at_timestamp_after_seq(_partition, _other) do
    {:resp, 400, "InvalidArgumentException", "Timestamp is required for AT_TIMESTAMP"}
  end

  defp req_seq(req) do
    case req["SequenceNumber"] do
      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, ""} when n >= 0 -> n
          _ -> 0
        end

      _ ->
        0
    end
  end

  defp latest_seq(partition) do
    case EventHubs.last_enqueued(partition) do
      :none -> 0
      %{"seq" => seq} -> seq
    end
  end

  defp partition_of(stream, shard), do: "#{stream}/partitions/#{shard_index_str!(shard)}"

  defp shard_index_str!("shardId-" <> rest) do
    digits = String.trim_leading(rest, "0")
    digits = if digits == "", do: "0", else: digits
    {n, ""} = Integer.parse(digits)
    n
  end

  # -- GetRecords --------------------------------------------------------------

  defp get_records(conn, req) do
    with {:ok, token} <- fetch_shard_iterator(req),
         {:ok, {stream, shard, after_seq}} <- decode_iterator(token) do
      limit =
        case req["Limit"] do
          n when is_integer(n) and n > 0 -> min(n, @max_records_limit)
          _ -> @max_records_limit
        end

      partition = partition_of(stream, shard)
      events = EventHubs.receive_events(partition, after_seq, limit)

      last_seq =
        case List.last(events) do
          nil -> after_seq
          ev -> ev["seq"]
        end

      now_ms = System.system_time(:millisecond)
      last_ms = latest_enqueued_ms(partition)

      send_json(conn, 200, %{
        "Records" =>
          Enum.map(events, fn ev ->
            %{
              "SequenceNumber" => Integer.to_string(ev_seq(ev)),
              "Data" => Base.encode64(ev_body(ev)),
              "PartitionKey" => ev_pk(ev),
              "ApproximateArrivalTimestamp" => ev_enqueued(ev) / 1000.0
            }
          end),
        "NextShardIterator" => Base.url_encode64("#{stream}|#{shard}|#{last_seq}"),
        "MillisBehindLatest" => max(0, now_ms - (last_ms || now_ms))
      })
    else
      {:resp, _, _, _} = resp -> resp
    end
  end

  defp fetch_shard_iterator(req) do
    case req do
      %{"ShardIterator" => t} when is_binary(t) and t != "" -> {:ok, t}
      _ -> {:resp, 400, "InvalidArgumentException", "ShardIterator is required"}
    end
  end

  defp decode_iterator(token) do
    case Base.url_decode64(token) do
      {:ok, raw} ->
        case String.split(raw, "|", parts: 3) do
          [stream, shard, seq_bin] ->
            case Integer.parse(seq_bin) do
              {n, ""} when n >= 0 ->
                {:ok, {stream, shard, n}}

              _ ->
                {:resp, 400, "ResourceNotFoundException", "invalid shard iterator sequence"}
            end

          _ ->
            {:resp, 400, "ResourceNotFoundException", "invalid shard iterator"}
        end

      :error ->
        {:resp, 400, "ResourceNotFoundException", "invalid shard iterator"}
    end
  end

  defp ev_seq(%{"seq" => seq}), do: seq
  defp ev_body(%{"body" => body}) when is_binary(body), do: body
  defp ev_body(_), do: ""

  defp ev_pk(%{"partition_key" => pk}) when is_binary(pk), do: pk
  defp ev_pk(_), do: "none"

  defp ev_enqueued(%{"enqueued" => ms}) when is_number(ms), do: ms
  defp ev_enqueued(_), do: System.system_time(:millisecond)

  defp latest_enqueued_ms(partition) do
    case EventHubs.last_enqueued(partition) do
      :none -> nil
      %{"enqueued" => ms} when is_number(ms) -> ms
      _ -> nil
    end
  end

  defp partition_events(partition) do
    EventHubs.receive_events(partition, 0, 10_000_000)
  end

  # -- ListShards / DescribeStream / ListStreams -------------------------------

  defp list_shards(conn, req) do
    with {:ok, stream} <- fetch_stream(req),
         :ok <- stream_known?(stream) do
      send_json(conn, 200, %{
        "Shards" => Enum.map(0..(@pinned_shards - 1), &shard_description/1),
        "StreamName" => stream
      })
    else
      {:resp, _, _, _} = resp -> resp
    end
  end

  defp describe_stream(conn, req) do
    with {:ok, stream} <- fetch_stream(req),
         :ok <- stream_known?(stream) do
      send_json(conn, 200, %{
        "StreamDescription" => %{
          "StreamName" => stream,
          "StreamARN" => "arn:aws:kinesis:#{region()}::stream/#{stream}",
          "StreamStatus" => "ACTIVE",
          "Shards" => Enum.map(0..(@pinned_shards - 1), &shard_description/1),
          "HasMoreShards" => false
        }
      })
    else
      {:resp, _, _, _} = resp -> resp
    end
  end

  defp shard_description(idx) do
    %{
      "ShardId" => shard_id(idx),
      "HashKeyRange" => %{
        "StartingHashKey" => if(idx == 0, do: "0", else: "170141183460469231731687303715884105728"),
        "EndingHashKey" => "340282366920938463463374607431768211455"
      },
      "SequenceNumberRange" => %{"StartingSequenceNumber" => "1"}
    }
  end

  defp list_streams(conn) do
    stream_names =
      if :ets.info(:smalt_eh_partitions) == :undefined do
        []
      else
        :smalt_eh_partitions
        |> :ets.tab2list()
        # The partitions table also carries tuple keys ({:seq_counter, path})
        # from the Store counter path — only binary partition keys name
        # streams (witnessed: FunctionClauseError in String.split on the
        # tuple key, 500 on ListStreams after a first publish).
        |> Enum.flat_map(fn
          {partition, _} when is_binary(partition) ->
            case String.split(partition, "/partitions/") do
              [stream, _] -> [stream]
              _ -> []
            end

          _non_binary ->
            []
        end)
        |> Enum.uniq()
        |> Enum.sort()
      end

    send_json(conn, 200, %{
      "StreamNames" => stream_names,
      "HasMoreStreams" => false
    })
  end

  # -- errors / json -----------------------------------------------------------

  defp send_json(conn, status, body_map) do
    conn
    |> put_resp_header("content-type", "application/x-amz-json-1.1")
    |> send_resp(status, Jason.encode!(body_map))
  end

  defp send_error(conn, status, code, message) do
    send_json(conn, status, %{"__type" => "com.amazonaws.kinesis##{code}", "message" => message})
  end

  defp region, do: Application.get_env(:smalt, :kinesis_region, "smalt-1")

  defp route_not_ready(conn) do
    # The EH partition table doesn't exist yet — the store server hasn't booted.
    send_error(conn, 503, "LimitExceededException", "event store not ready")
  end
end
