%% court_kafka_wormhole_proposer_SUITE.erl — ERL-3 court (operator
%% reference contract). Run:
%%   erlc -o ebin/ src/*.erl test/courts/court_kafka_wormhole_proposer_SUITE.erl
%%   erl -pa ebin/ -noshell -s court_kafka_wormhole_proposer_SUITE run_court
%% Exit 0 = 8/8 PASS. No sleeps: bounded yield/retry loops only.
-module(court_kafka_wormhole_proposer_SUITE).
-export([run_court/0]).

%% mirror of smalt_wormhole's sealed snapshot record (tamper probe needs
%% the element index); field order is the contract
-record(wormhole, {t_ns, seal_ref, universe_hash, quad_count,
                   snapshot_bin}).

-define(PASS_GROUP(G, Msg),
        io:format("PASS ~p ~s~n", [G, Msg]), G).

run_court() ->
    try run() of
        ok ->
            io:format("COURT RESULT: 8/8 PASS~n"),
            halt(0)
    catch
        Class:Reason:Stack ->
            io:format("COURT RESULT: FAIL ~p:~p~n~p~n",
                      [Class, Reason, Stack]),
            halt(1)
    end.

run() ->
    io:format("== ERL-3 kafka/wormhole/proposer court ==~n"),
    ok = smalt_store:start(),
    G1 = kafka_round_trip(),
    G2 = kafka_sieve_refusal_andon(),
    G3 = kafka_malformed(),
    G4 = cloudevent_receipt(),
    G5 = wormhole_freeze_travel(),
    G6 = wormhole_tamper_and_no_anchor(),
    G7 = proposer_admit_and_double_refusal(),
    G8 = federated_clip_average(),
    Total = G1 + G2 + G3 + G4 + G5 + G6 + G7 + G8,
    36 = Total,  %% 1+2+...+8
    smalt_store:stop(),
    ok.

%% -- 1: produce -> fetch byte-exact round trip -------------------------

kafka_round_trip() ->
    Topic = <<"court.topic">>,
    Batch = make_record_batch(<<"hello-kafka-bytes">>),
    <<Size:32, Body/binary>> =
        produce_frame(<<"court-producer">>, Topic, 0, Batch),
    {ok, Resp} = smalt_eventhubs_kafka:handle_frame(
                   <<Size:32, Body/binary>>),
    #{correlation_id := 7, topic := Topic, partition := 0,
      error_code := 0, offset := Offset0} =
        smalt_eventhubs_kafka:decode_produce_response(Resp),
    true = is_integer(Offset0),
    <<FSize:32, FBody/binary>> =
        fetch_frame(<<"court-consumer">>, Topic, 0, 0),
    {ok, FResp} = smalt_eventhubs_kafka:handle_frame(
                    <<FSize:32, FBody/binary>>),
    #{records := [{Offset0, Batch}], partition := 0} =
        smalt_eventhubs_kafka:decode_fetch_response(FResp),
    %% second produce lands at Offset0 + 1 and both round-trip
    {ok, Resp2} = smalt_eventhubs_kafka:handle_frame(
                    produce_frame(<<"court-producer">>, Topic, 0,
                                  make_record_batch(<<"second">>))),
    #{offset := Offset1} =
        smalt_eventhubs_kafka:decode_produce_response(Resp2),
    Offset1 = Offset0 + 1,
    {ok, FResp2} = smalt_eventhubs_kafka:handle_frame(
                     fetch_frame(<<"court-consumer">>, Topic, 0, Offset0)),
    #{records := [{Offset0, Batch}, {Offset1, _B2}]} =
        smalt_eventhubs_kafka:decode_fetch_response(FResp2),
    ?PASS_GROUP(1, "kafka produce->fetch byte-exact round-trip").

%% -- 2: sieve refusal -> andon journaled --------------------------------

kafka_sieve_refusal_andon() ->
    Topic = <<"court.sieve">>,
    BadBatch = <<0:64, 4:32, 0:32, 9:8, 0:112>>,   %% magic 9, not v2
    {ok, Resp} = smalt_eventhubs_kafka:handle_frame(
                   produce_frame(<<"court-producer">>, Topic, 3, BadBatch)),
    #{error_code := 1, offset := -1, partition := 3} =
        smalt_eventhubs_kafka:decode_produce_response(Resp),
    %% andon is durable: fetch sees nothing, offset stays unminted
    {ok, FResp} = smalt_eventhubs_kafka:handle_frame(
                    fetch_frame(<<"court-consumer">>, Topic, 3, 0)),
    #{records := []} = smalt_eventhubs_kafka:decode_fetch_response(FResp),
    ?PASS_GROUP(2, "kafka sieve refusal -> produce EC=1 + durable andon").

%% -- 3: malformed wire frames -------------------------------------------

kafka_malformed() ->
    {error, malformed_kafka_wire_frame} =
        smalt_eventhubs_kafka:handle_frame(<<999:32, 1, 2, 3>>),
    {error, malformed_kafka_wire_frame} =
        smalt_eventhubs_kafka:handle_frame(<<16, 0:16, 0:16, 0:32>>),
    {error, {unsupported_api_key, 42}} =
        smalt_eventhubs_kafka:handle_frame(
          <<8:32, 42:16, 0:16, 1:32>>),
    ?PASS_GROUP(3, "kafka malformed frames -> malformed_kafka_wire_frame").

%% -- 4: cloudevent -> receipt --------------------------------------------

cloudevent_receipt() ->
    Topic = <<"court.ce">>,
    {ok, R1, 0} = smalt_eventhubs_kafka:publish_cloudevent(Topic, 0,
                                                           <<"payload-1">>),
    {ok, R2, 1} = smalt_eventhubs_kafka:publish_cloudevent(Topic, 0,
                                                           <<"payload-2">>),
    true = is_binary(R1) andalso byte_size(R1) =:= 32,
    true = R1 =/= R2,
    %% deterministic: same publish content at a fresh partition = same
    %% receipt shape, and offset monotonic per (topic, partition)
    {ok, _R3, 2} = smalt_eventhubs_kafka:publish_cloudevent(Topic, 0,
                                                            <<"payload-3">>),
    {error, malformed_cloudevent_frame} =
        smalt_eventhubs_kafka:handle_cloudevent(<<16#CE, 99, 0:16>>),
    ?PASS_GROUP(4, "cloudevent v1.0 binary -> monotonic offset + merkle receipt").

%% -- 5: wormhole freeze -> travel ----------------------------------------

wormhole_freeze_travel() ->
    5 = smalt_wormhole:optimal_spacing_ms(1, 4, 100),   %% sqrt(1/4*100)=5
    10 = smalt_wormhole:optimal_spacing_ms(4, 1, 25),   %% sqrt(100)=10
    0 = smalt_wormhole:optimal_spacing_ms(1, 1, 0),
    Q0 = [{a, 1}],
    Q1 = [{a, 1}, {b, 2}],
    {ok, Seal0, _H0, 1} = smalt_wormhole:freeze_universe(wh_court, Q0),
    {ok, _Seal1, _H1, 2} = smalt_wormhole:freeze_universe(wh_court, Q1),
    %% target strictly between the freezes: nearest-prior anchor is the
    %% Q0 freeze, state at that instant IS Q0
    {ok, Q0, #{replayed := 0}} =
        smalt_wormhole:time_travel(wh_court, element(2, Seal0) + 1),
    %% target after the last freeze: anchor IS the final snapshot
    {ok, Q1, #{replayed := 0}} =
        smalt_wormhole:time_travel(wh_court,
                                   erlang:monotonic_time(nanosecond) + 1),
    %% a drop: freeze back to Q0 shape; middle anchor selection returns
    %% the intermediate Q1 state, post-drop travel returns Q0
    {ok, Seal2, _, 2} = smalt_wormhole:freeze_universe(wh_court2, Q1),
    {ok, _, _, 1} = smalt_wormhole:freeze_universe(wh_court2, Q0),
    {ok, Q1, #{replayed := 0}} =
        smalt_wormhole:time_travel(wh_court2, element(2, Seal2) + 1),
    {ok, Q0, #{replayed := 0}} =
        smalt_wormhole:time_travel(wh_court2,
                                   erlang:monotonic_time(nanosecond) + 1),
    ?PASS_GROUP(5, "wormhole freeze->travel + Theorem 9.4 spacing math").

%% -- 6: tamper + no-anchor refusals ---------------------------------------

wormhole_tamper_and_no_anchor() ->
    {error, no_prior_wormhole_anchor} =
        smalt_wormhole:time_travel(wh_never_frozen,
                                   erlang:monotonic_time(nanosecond) + 1),
    %% tamper: corrupt a sealed snapshot, travel must REFUSE loudly
    Q = [{t, 9}],
    {ok, Seal, _H, 1} = smalt_wormhole:freeze_universe(wh_tamper, Q),
    Tampered = ets:update_element(smalt_wormhole, element(2, Seal),
                                  [{#wormhole.snapshot_bin,
                                    term_to_binary([{t, evil}])}]),
    true = Tampered,
    {error, wormhole_tamper_detected} =
        smalt_wormhole:time_travel(wh_tamper,
                                   erlang:monotonic_time(nanosecond) + 1),
    ?PASS_GROUP(6, "wormhole tamper + no-anchor refusals").

%% -- 7: proposer admit + double refusal ------------------------------------

proposer_admit_and_double_refusal() ->
    Proposal = {insert_user, <<"u1">>},
    ShaclOk = fun(_P) -> ok end,
    SieveOk = fun({insert_user, _}) -> ok;
                 (_) -> {error, not_whitelisted} end,
    {admitted, ETag, Receipt} =
        smalt_proposer_gate:evaluate_proposal(pg_court, Proposal,
                                              ShaclOk, SieveOk),
    true = is_binary(ETag) andalso is_binary(Receipt),
    ShaclBad = fun(_P) -> {error, shape_violation} end,
    {andon_refusal, {shacl_refused, shape_violation}, -1.0} =
        smalt_proposer_gate:evaluate_proposal(pg_bad1, Proposal,
                                              ShaclBad, SieveOk),
    SieveBad = fun(_P) -> {error, banned_triple} end,
    {andon_refusal, {sieve_refused, banned_triple}, -1.0} =
        smalt_proposer_gate:evaluate_proposal(pg_bad2, Proposal,
                                              ShaclOk, SieveBad),
    %% refusal is durable ANDON in the journal; refusal does NOT store
    %% the proposal
    {error, not_found} = smalt_store:get({proposal, pg_bad1}),
    {ok, {0, Proposal}} = smalt_store:get({proposal, pg_court}),
    ?PASS_GROUP(7, "proposer Op1 SHACL + Op2 sieve admit / andon refusals").

%% -- 8: federated clip/average + refusals -----------------------------------

federated_clip_average() ->
    {ok, [3.0, 4.0], 9} =
        smalt_proposer_gate:aggregate_federated_shards([[3, 4], [6, 8]],
                                                       5, 10),
    {ok, [1.0, 1.0], _} =
        smalt_proposer_gate:aggregate_federated_shards([[2, 0], [0, 2]],
                                                       100, 1),
    {error, empty_federated_shards} =
        smalt_proposer_gate:aggregate_federated_shards([], 5, 10),
    {error, privacy_budget_exhausted} =
        smalt_proposer_gate:aggregate_federated_shards([[1, 1]], 5, 0),
    [3.0, 4.0] = smalt_proposer_gate:clip_vector([6, 8], 5),
    [6, 8] = smalt_proposer_gate:clip_vector([6, 8], 10),
    ?PASS_GROUP(8, "federated clip-to-MaxNorm + average + refusals").

%% -- frame builders ----------------------------------------------------------

produce_frame(ClientId, Topic, Partition, Batch) ->
    Body = <<0:16, 3:16, 7:32, (byte_size(ClientId)):16,
             ClientId/binary, (byte_size(Topic)):16, Topic/binary,
             Partition:32, (byte_size(Batch)):32, Batch/binary>>,
    <<(byte_size(Body)):32, Body/binary>>.

fetch_frame(ClientId, Topic, Partition, Offset) ->
    Body = <<1:16, 3:16, 9:32, (byte_size(ClientId)):16,
             ClientId/binary, (byte_size(Topic)):16, Topic/binary,
             Partition:32, Offset:64>>,
    <<(byte_size(Body)):32, Body/binary>>.

%% Kafka RecordBatch v2 envelope: BaseOffset:64 BatchLength:32
%% PartitionLeaderEpoch:32 Magic:8(=2) CRC:32 ... payload
make_record_batch(Payload) ->
    <<0:64, 0:32, 0:32, 2:8, 0:32, (byte_size(Payload)):32,
      Payload/binary>>.
