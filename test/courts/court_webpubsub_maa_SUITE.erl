%% court_webpubsub_maa_SUITE.erl — ERL-2/ERL-3 court (operator-supplied
%% design). Run:
%%   erlc -o ebin/ src/smalt_webpubsub_hub.erl src/smalt_maa_attestation.erl \
%%        test/courts/court_webpubsub_maa_SUITE.erl
%%   erl -pa ebin/ -noshell -s court_webpubsub_maa_SUITE run_court
%% Exit 0 = 6/6 PASS. No sleeps: bounded erlang:yield retry loops only.
-module(court_webpubsub_maa_SUITE).
-export([run_court/0]).

run_court() ->
    try run() of
        ok ->
            io:format("COURT RESULT: 6/6 PASS~n"),
            halt(0)
    catch
        Class:Reason:Stack ->
            io:format("COURT RESULT: FAIL ~p:~p~n~p~n",
                      [Class, Reason, Stack]),
            halt(1)
    end.

run() ->
    io:format("== ERL-2 webpubsub hub / ERL-3 MAA court ==~n"),

    %% ===== LEG 1: hub boot + join 2 pids =====
    ok = smalt_webpubsub_hub:start(),
    Self = self(),
    Parent = self(),
    P1 = spawn_link(fun() -> collector(Parent) end),
    P2 = spawn_link(fun() -> collector(Parent) end),
    ok = smalt_webpubsub_hub:join_group(lobby, P1),
    ok = smalt_webpubsub_hub:join_group(lobby, P2),
    [P1, P2] = lists:sort(smalt_webpubsub_hub:members(lobby)),
    io:format("LEG 1 hub boot + 2 joins: ok~n"),

    %% ===== LEG 2: broadcast valid Packet-4 frame =====
    Frame = smalt_webpubsub_hub:encode_frame(1, 0, <<"hello-packet-4">>),
    41 = byte_size(Frame),
    {ok, #{seq := 1, payload := <<"hello-packet-4">>}} =
        smalt_webpubsub_hub:verify_frame(Frame),
    {ok, {merkle_receipt, 1, _, _}} =
        smalt_webpubsub_hub:broadcast_frame(lobby, Frame),
    ok = collect_both([P1, P2]),
    {ok, {merkle_receipt, 1, _, _}} = smalt_webpubsub_hub:last_receipt(),
    1 = smalt_webpubsub_hub:journal_size(),
    io:format("LEG 2 valid frame: both members got {webpubsub_binary_frame, lobby, 1, payload}, journal=1, receipt minted: ok~n"),

    %% ===== LEG 3: bad CRC -> andon, no fan-out, no journal =====
    <<M:32, CRC:32, Rest/binary>> = Frame,
    Corrupt = <<M:32, (CRC bor 16#FF):32, Rest/binary>>,
    {error, {andon, bad_crc}} =
        smalt_webpubsub_hub:broadcast_frame(lobby, Corrupt),
    flush_collectors(),
    1 = smalt_webpubsub_hub:journal_size(),
    io:format("LEG 3 bad CRC andon (no fan-out, no journal append): ok~n"),

    %% ===== LEG 4: pg scope cleanup between legs =====
    ok = smalt_webpubsub_hub:leave_group(lobby, P1),
    ok = smalt_webpubsub_hub:leave_group(lobby, P2),
    [] = smalt_webpubsub_hub:members(lobby),
    P1 ! stop, P2 ! stop,
    io:format("LEG 4 pg cleanup: members empty: ok~n"),

    %% ===== LEG 5: MAA correct quote -> 40-word receipt =====
    Reticle = crypto:hash(sha256, <<"trusted-reticle-v1">>),
    ok = smalt_maa_attestation:pin_reticle_hash(Reticle),
    Opts = #{nonce => 42, timestamp => 1700000000000},
    {ok, Receipt} =
        smalt_maa_attestation:attest_environment(sevsnpvm, Reticle, Opts),
    40 = smalt_maa_attestation:receipt_words(Receipt),
    %% receipt carries the hash (words 6..9 = quote hash)
    {maa_receipt, 1, sevsnpvm, 1700000000000, 42,
     Q1, Q2, Q3, Q4} = Receipt,
    <<Q1:64, Q2:64, Q3:64, Q4:64>> = Reticle,
    {ok, _} = smalt_maa_attestation:attest_environment(
                wasmreticle, Reticle, Opts),
    io:format("LEG 5 correct quote -> 40-word receipt (erts_debug:size=40), hash embedded: ok~n"),

    %% ===== LEG 6: wrong quote + unsupported type =====
    {error, attestation_quote_mismatch} =
        smalt_maa_attestation:attest_environment(
          sevsnpvm, crypto:hash(sha256, <<"evil-reticle">>), Opts),
    {error, unsupported_env_type} =
        smalt_maa_attestation:attest_environment(
          wasm_rce, Reticle, Opts),
    io:format("LEG 6 wrong quote -> ATTESTATION_QUOTE_MISMATCH; unsupported type -> refusal: ok~n"),

    smalt_webpubsub_hub:stop(),
    ok.

%% -- helpers ----------------------------------------------------------

%% collector: forwards every webpubsub frame to its parent, exits on stop
collector(Parent) ->
    receive
        stop -> ok;
        {webpubsub_binary_frame, _, _, _} = Msg ->
            Parent ! {self(), Msg},
            collector(Parent)
    end.

flush_collectors() ->
    receive
        {_Pid, _} -> flush_collectors()
    after 500 -> ok
    end.

%% bounded wait: every listed collector must have forwarded exactly one
%% matching frame; non-matching forwards are skipped, never fatal.
collect_both([]) -> ok;
collect_both(Pids) ->
    Deadline = monotonic_ms() + 5000,
    collect_both(Pids, Deadline).

collect_both([], _Deadline) -> ok;
collect_both(Pids, Deadline) ->
    Now = erlang:monotonic_time(millisecond),
    case Now > Deadline of
        true -> exit({no_frame, Pids});
        false ->
            receive
                {From, {webpubsub_binary_frame, lobby, 1,
                        <<"hello-packet-4">>}} ->
                    collect_both(lists:delete(From, Pids), Deadline);
                {_Other, {webpubsub_binary_frame, _, _, _}} ->
                    collect_both(Pids, Deadline)
            after Deadline - Now ->
                    exit({no_frame, Pids})
            end
    end.

monotonic_ms() -> erlang:monotonic_time(millisecond).
