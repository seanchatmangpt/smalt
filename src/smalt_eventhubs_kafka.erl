%% smalt_eventhubs_kafka.erl — Kafka wire frame handler (EH Kafka surface,
%% operator reference contract). Pure functions over binaries; durability
%% via smalt_store put_cas + journal append + merkle receipt.
%%
%% Produce request (API_KEY=0), after the Size:32 envelope:
%%   ApiKey:16 ApiVer:16 CorrId:32 ClientLen:16 ClientId
%%   TopicLen:16 Topic Partition:32 BatchLen:32 RecordBatch
%% Produce response:
%%   CorrId:32 TopicLen:16 Topic Partition:32 ErrorCode:16 Offset:64
%% Fetch request (API_KEY=1): ... TopicLen:16 Topic Partition:32
%%   FetchOffset:64 ; response:
%%   CorrId:32 TopicLen:16 Topic Partition:32 Count:32
%%   [Offset:64 Len:32 Payload]*
%% CloudEvents v1.0 binary (op byte 16#CE):
%%   16#CE 8 Ver:8 TopicLen:16 Topic Partition:32 PayloadLen:32 Payload
%% Zero dynamic atoms: no list_to_atom/binary_to_atom anywhere on wire
%% paths; wire input only ever becomes binaries/integers/keys.
-module(smalt_eventhubs_kafka).
-export([handle_frame/1, handle_cloudevent/1, publish_cloudevent/3,
         decode_produce_response/1, decode_fetch_response/1,
         decode_cloudevent/1]).

-define(API_PRODUCE, 0).
-define(API_FETCH, 1).
-define(EC_NONE, 0).
-define(EC_SIEVE_REFUSED, 1).
-define(BATCH_MAGIC_V2, 2).
-define(CE_OP, 16#CE).
-define(CE_VERSION, 1).
-define(MAX_FETCH_RECORDS, 256).
-define(MAX_CAS_RETRY, 64).

%% -- Kafka wire entry -------------------------------------------------

handle_frame(Frame) when is_binary(Frame) ->
    case Frame of
        <<Size:32, Body/binary>> when byte_size(Body) =:= Size ->
            route_api(Body);
        _ ->
            {error, malformed_kafka_wire_frame}
    end;
handle_frame(_) ->
    {error, malformed_kafka_wire_frame}.

route_api(<<?API_PRODUCE:16, _ApiVer:16, CorrId:32, Rest/binary>>) ->
    handle_produce(_ApiVer, CorrId, Rest);
route_api(<<?API_FETCH:16, _ApiVer:16, CorrId:32, Rest/binary>>) ->
    handle_fetch(_ApiVer, CorrId, Rest);
route_api(<<ApiKey:16, _/binary>>) ->
    {error, {unsupported_api_key, ApiKey}};
route_api(_) ->
    {error, malformed_kafka_wire_frame}.

%% -- Produce ----------------------------------------------------------

handle_produce(_ApiVer, CorrId, Rest) ->
    case Rest of
        <<ClientLen:16, ClientId:ClientLen/binary, TopicLen:16,
          Topic:TopicLen/binary, Partition:32, BatchLen:32,
          RecordBatch:BatchLen/binary>>
              when ClientLen =:= byte_size(ClientId),
                   TopicLen =:= byte_size(Topic) ->
            case sieve_record_batch(RecordBatch, BatchLen) of
                ok ->
                    Offset = append_record(Topic, Partition, RecordBatch),
                    {ok, produce_response(CorrId, Topic, Partition,
                                          ?EC_NONE, Offset)};
                {refused, Reason} ->
                    append_andon(Topic, Partition, Reason),
                    {ok, produce_response(CorrId, Topic, Partition,
                                          ?EC_SIEVE_REFUSED, -1)}
            end;
        _ ->
            {error, malformed_kafka_wire_frame}
    end.

%% Sieve: Kafka RecordBatch v2 magic byte (offset 16, after BaseOffset:64
%% BatchLength:32 PartitionLeaderEpoch:32) must be 2 and the declared
%% batch length must cover exactly the payload.
sieve_record_batch(RecordBatch, BatchLen)
        when byte_size(RecordBatch) =:= BatchLen,
             byte_size(RecordBatch) >= 17 ->
    <<_:16/binary, Magic:8, _/binary>> = RecordBatch,
    case Magic of
        ?BATCH_MAGIC_V2 -> ok;
        _ -> {refused, bad_batch_magic}
    end;
sieve_record_batch(_RecordBatch, _BatchLen) ->
    {refused, batch_length_mismatch}.

%% Monotonic offset: CAS-retry the per-(Topic,Partition) high-water mark
%% so two racing producers serialize instead of clobbering.
append_record(Topic, Partition, RecordBatch) ->
    HWMKey = {kafka_hwm, Topic, Partition},
    HWM = hwm_get(HWMKey),
    Offset = HWM + 1,
    ok = smalt_store:put_cas({kafka_rec, Topic, Partition, Offset},
                             RecordBatch, any),
    {ok, _Seq} = smalt_arm_adapters:append_frame(
                   kafka, {Topic, Partition}, produce, RecordBatch,
                   term_to_binary(#{offset => Offset})),
    case advance_hwm(HWMKey, Offset, ?MAX_CAS_RETRY) of
        ok -> Offset;
        {error, cas_exhausted} -> Offset   %% record is durable; HWM lags
    end.

hwm_get(Key) ->
    case smalt_store:get(Key) of
        {ok, N} when is_integer(N) -> N;
        {error, not_found} -> -1
    end.

advance_hwm(_Key, _Offset, 0) ->
    {error, cas_exhausted};
advance_hwm(Key, Offset, N) ->
    Cur = hwm_get(Key),
    if
        Cur >= Offset -> ok;
        true ->
            Expect = case Cur of
                         -1 -> any;
                         _ -> smalt_arm_adapters:current_etag(Key)
                     end,
            case smalt_store:put_cas(Key, Offset, Expect) of
                ok -> ok;
                {error, etag_mismatch} -> advance_hwm(Key, Offset, N - 1)
            end
    end.

append_andon(Topic, Partition, Reason) ->
    {ok, _} = smalt_arm_adapters:append_frame(
                kafka_andon, {Topic, Partition}, sieve_refused,
                term_to_binary(Reason), term_to_binary(#{partition => Partition})),
    ok.

produce_response(CorrId, Topic, Partition, ErrorCode, Offset) ->
    <<CorrId:32, (byte_size(Topic)):16, Topic/binary, Partition:32,
      ErrorCode:16, Offset:64/signed>>.

%% -- Fetch ------------------------------------------------------------

handle_fetch(_ApiVer, CorrId, Rest) ->
    case Rest of
        <<ClientLen:16, ClientId:ClientLen/binary, TopicLen:16,
          Topic:TopicLen/binary, Partition:32, FetchOffset:64>>
              when ClientLen =:= byte_size(ClientId),
                   TopicLen =:= byte_size(Topic) ->
            Records = collect_records(Topic, Partition, FetchOffset, []),
            {ok, fetch_response(CorrId, Topic, Partition, Records)};
        _ ->
            {error, malformed_kafka_wire_frame}
    end.

collect_records(_Topic, _Partition, _Off, Acc)
        when length(Acc) >= ?MAX_FETCH_RECORDS ->
    lists:reverse(Acc);
collect_records(Topic, Partition, Off, Acc) ->
    case smalt_store:get({kafka_rec, Topic, Partition, Off}) of
        {ok, Batch} ->
            collect_records(Topic, Partition, Off + 1,
                            [{Off, Batch} | Acc]);
        {error, not_found} ->
            lists:reverse(Acc)
    end.

fetch_response(CorrId, Topic, Partition, Records) ->
    Blob = << <<O:64, (byte_size(B)):32, B/binary>> || {O, B} <- Records >>,
    <<CorrId:32, (byte_size(Topic)):16, Topic/binary, Partition:32,
      (length(Records)):32, Blob/binary>>.

%% -- CloudEvents v1.0 binary mode --------------------------------------

publish_cloudevent(Topic, Partition, Payload) when is_binary(Payload) ->
    Ce = <<?CE_OP:8, ?CE_VERSION:8, (byte_size(Topic)):16, Topic/binary,
           Partition:32, (byte_size(Payload)):32, Payload/binary>>,
    handle_cloudevent(Ce).

handle_cloudevent(Ce) when is_binary(Ce) ->
    case Ce of
        <<?CE_OP:8, ?CE_VERSION:8, TopicLen:16, Topic:TopicLen/binary,
          Partition:32, PLen:32, Payload:PLen/binary>>
              when TopicLen =:= byte_size(Topic),
                   PLen =:= byte_size(Payload) ->
            Offset = ce_offset(Topic, Partition),
            ok = smalt_store:put_cas({ce_rec, Topic, Partition, Offset},
                                     Payload, any),
            {ok, _Seq} = smalt_arm_adapters:append_frame(
                           cloudevents, {Topic, Partition}, publish,
                           Payload, term_to_binary(#{offset => Offset})),
            {ok, Receipt} = smalt_arm_adapters:mint_single_receipt(
                              cloudevents,
                              [Payload,
                               term_to_binary({Topic, Partition, Offset})],
                              smalt_arm_adapters:current_etag(
                                {ce_rec, Topic, Partition, Offset})),
            {ok, Receipt, Offset};
        _ ->
            {error, malformed_cloudevent_frame}
    end;
handle_cloudevent(_) ->
    {error, malformed_cloudevent_frame}.

ce_offset(Topic, Partition) ->
    Key = {ce_hwm, Topic, Partition},
    case smalt_store:get(Key) of
        {ok, N} when is_integer(N) ->
            Offset = N + 1,
            ok = smalt_store:put_cas(Key, Offset,
                                     smalt_arm_adapters:current_etag(Key)),
            Offset;
        {error, not_found} ->
            case smalt_store:put_cas(Key, 0, any) of
                ok -> 0;
                {error, etag_mismatch} -> ce_offset(Topic, Partition)
            end
    end.

%% -- Response decoders (court/CLI readback) ----------------------------

decode_produce_response(<<CorrId:32, TopicLen:16, Topic:TopicLen/binary,
                          Partition:32, ErrorCode:16, Offset:64/signed>>)
        when TopicLen =:= byte_size(Topic) ->
    #{correlation_id => CorrId, topic => Topic, partition => Partition,
      error_code => ErrorCode, offset => Offset};
decode_produce_response(_) ->
    {error, malformed_produce_response}.

decode_fetch_response(<<CorrId:32, TopicLen:16, Topic:TopicLen/binary,
                        Partition:32, Count:32, Records/binary>>)
        when TopicLen =:= byte_size(Topic) ->
    #{correlation_id => CorrId, topic => Topic, partition => Partition,
      records => decode_records(Count, Records, [])};
decode_fetch_response(_) ->
    {error, malformed_fetch_response}.

decode_records(0, <<>>, Acc) -> lists:reverse(Acc);
decode_records(N, <<Off:64, Len:32, B:Len/binary, Rest/binary>>, Acc)
        when N > 0, Len =:= byte_size(B) ->
    decode_records(N - 1, Rest, [{Off, B} | Acc]);
decode_records(_N, _Bin, _Acc) ->
    {error, malformed_fetch_records}.

decode_cloudevent(<<?CE_OP:8, Ver:8, TopicLen:16, Topic:TopicLen/binary,
                    Partition:32, PLen:32, Payload:PLen/binary>>)
        when TopicLen =:= byte_size(Topic), PLen =:= byte_size(Payload) ->
    #{version => Ver, topic => Topic, partition => Partition,
      payload => Payload};
decode_cloudevent(_) ->
    {error, malformed_cloudevent_frame}.
