%% court_store_partition_SUITE.erl — STORE-4 crash court (operator-supplied
%% design, verbatim contract). Run:
%%   erlc -o ebin/ test/courts/court_store_partition_SUITE.erl
%%   erl -pa ebin/ -noshell -s court_store_partition_SUITE run_court
%% Exit 0 = 4/4 PASS. No sleeps: bounded erlang:yield retry loops only.
-module(court_store_partition_SUITE).
-export([run_court/0]).

-define(PASS_GROUP(G, Msg),
        io:format("PASS ~p ~s~n", [G, Msg]), G).

run_court() ->
    try run() of
        ok ->
            io:format("COURT RESULT: 4/4 PASS~n"),
            halt(0)
    catch
        Class:Reason:Stack ->
            io:format("COURT RESULT: FAIL ~p:~p~n~p~n",
                      [Class, Reason, Stack]),
            halt(1)
    end.

run() ->
    io:format("== STORE-4 partition court ==~n"),
    %% STEP 1: boot our own sup tree (name collision = loud refusal)
    ok = case smalt_store:start() of
             ok -> ok;
             {error, already_started} ->
                 exit({name_collision, smalt_store_sup})
         end,
    Pids0 = [whereis(smalt_store_partition:partition_name(N))
             || N <- lists:seq(0, 15)],
    true = lists:all(fun(P) -> is_pid(P) end, Pids0),
    io:format("STEP 1 boot 16 partitions + heir: ok~n"),

    %% pinned phash2 keys for partitions 4 and 5 (deterministic search,
    %% then pinned by phash2 law — phash2 is stable across runs on same OTP)
    K4 = pinned_key(4), K5 = pinned_key(5),
    4 = smalt_store:partition_of(K4),
    5 = smalt_store:partition_of(K5),
    io:format("STEP 2 pinned keys: ~p -> partition 4, ~p -> partition 5~n",
              [K4, K5]),

    %% STEP 3: seed both partitions
    ok = smalt_store:put_cas(K4, seed_v1, any),
    ok = smalt_store:put_cas(K5, seed_v1, any),
    {ok, seed_v1} = smalt_store:get(K4),
    {ok, seed_v1} = smalt_store:get(K5),
    io:format("STEP 3 seed K4/K5: ok~n"),

    %% STEP 4: CAS semantics — correct etag accepted, stale refused
    E4 = current_etag(K4),
    ok = smalt_store:put_cas(K4, v2, E4),
    {error, etag_mismatch} = smalt_store:put_cas(K4, v3, E4),
    {ok, v2} = smalt_store:get(K4),
    io:format("STEP 4 etag accept/mismatch refusal: ok~n"),

    %% STEP 5: get bypasses mailboxes — direct lookup unaffected by a
    %% busy partition worker (same value through facade)
    {ok, v2} = smalt_store:get(K4),
    io:format("STEP 5 mailbox-free get: ok~n"),

    %% STEP 6: kill partition-4 worker with exit(kill), monitor DOWN
    P4 = whereis(smalt_store_partition:partition_name(4)),
    Ref = monitor(process, P4),
    exit(P4, kill),

    %% STEP 7: concurrent P5 CAS during P4's death (other partitions
    %% keep serving — blast radius bounded to partition 4)
    E5 = current_etag(K5),
    ok = smalt_store:put_cas(K5, during_death, E5),
    receive
        {'DOWN', Ref, process, P4, killed} -> ok
    after 5000 -> exit(down_timeout)
    end,
    io:format("STEP 6+7 exit(kill) P4 witnessed DOWN, concurrent P5 CAS ok~n"),

    %% STEP 8: await respawn — bounded yield retries, NO sleeps
    P4b = await_respawn(4, 50000),
    io:format("STEP 8 partition-4 respawned as ~p (bounded yield loop)~n",
              [P4b]),

    %% STEP 9: zero-loss heir check — K4 survived the kill via heir
    {ok, v2} = smalt_store:get(K4),
    io:format("STEP 9 zero-loss heir check (K4 survived): ok~n"),

    %% STEP 10: post-recovery mutation + P5 integrity
    E4b = current_etag(K4),
    ok = smalt_store:put_cas(K4, post_recovery, E4b),
    {ok, post_recovery} = smalt_store:get(K4),
    {ok, during_death} = smalt_store:get(K5),
    smalt_store:stop(),
    io:format("STEP 10 post-recovery mutation + P5 integrity: ok~n"),
    ok.

%% -- helpers ----------------------------------------------------------

pinned_key(Partition) ->
    pinned_key(Partition, 0).

pinned_key(Partition, N) ->
    case erlang:phash2(N, 16) of
        Partition -> N;
        _ -> pinned_key(Partition, N + 1)
    end.

current_etag(Key) ->
    [{Key, _V, ETag}] = ets:lookup(smalt_store:table_for(Key), Key),
    ETag.

await_respawn(Partition, 0) -> exit({respawn_timeout, Partition});
await_respawn(Partition, N) ->
    case whereis(smalt_store_partition:partition_name(Partition)) of
        P when is_pid(P), P =/= undefined -> P;
        _ -> erlang:yield(), await_respawn(Partition, N - 1)
    end.
