%% BENCH-7: pure-Erlang actor concurrency ceiling.
%% Raw `!' + receive ping/pong round-trips (NOT gen_server) — the floor
%% beneath PB-3's in-process face. Sweep N processes x R rounds,
%% measure aggregate wall + reductions per round-trip per N.
-module(bench_concurrency_ceiling).
-export([run/0, run/1]).
-define(NS, [1000, 4000, 8000, 16000, 32000]).
-define(OUT, "tmp/bench/court_bench_ceiling.jsonl").

run() -> run(?NS).

run(Ns) ->
    S = erlang:system_info(schedulers_online),
    L = erlang:system_info(logical_processors_available),
    {T0, _} = statistics(reductions),
    Rows = [bench(N) || N <- Ns],
    {T1, _} = statistics(reductions),
    Meta = [
        {kind, meta},
        {module, atom_to_list(?MODULE)},
        {n, null},
        {otp, erlang:system_info(otp_release)},
        {schedulers, S},
        {logical, L},
        {sweep_self_reds, T1 - T0}
    ],
    ok = filelib:ensure_dir(?OUT),
    {ok, Fd} = file:open(?OUT, [append]),
    try
        io:put_chars(Fd, [json(Meta), $\n]),
        [io:put_chars(Fd, [json(Row), $\n]) || Row <- Rows]
    after file:close(Fd) end,
    io:format("wrote ~s (~p rows)~n", [?OUT, length(Rows) + 1]),
    Rows.

bench(N) ->
    Pids = [spawn(fun ponger/0) || _ <- lists:seq(1, N)],
    Rounds = rounds_for(N),
    Ref = make_ref(),
    roundtrip(Pids, Ref, 1),          % warm: page in mailboxes, settle spawns
    {_, _} = statistics(reductions),
    T = erlang:monotonic_time(millisecond),
    roundtrip(Pids, Ref, Rounds),
    Wall = erlang:monotonic_time(millisecond) - T,
    {Total, _} = statistics(reductions),
    RT = N * Rounds,
    [
        {kind, row}, {n, N}, {rounds, Rounds}, {round_trips, RT},
        {wall_ms, Wall},
        {usec_per_roundtrip, (Wall * 1000.0) / RT},
        {reds_per_roundtrip, Total / RT},
        {ops_per_sec, case Wall of 0 -> null; _ -> RT * 1000 / Wall end}
    ].

rounds_for(32000) -> 10;
rounds_for(16000) -> 20;
rounds_for(_) -> 50.

ponger() ->
    receive
        {ping, Ref, From} -> From ! {pong, Ref}, ponger()
    end.

roundtrip(_Pids, _Ref, 0) -> ok;
roundtrip(Pids, Ref, K) ->
    [Pid ! {ping, Ref, self()} || Pid <- Pids],
    await(length(Pids), Ref),
    roundtrip(Pids, Ref, K - 1).

await(0, _) -> ok;
await(K, Ref) ->
    receive
        {pong, Ref} -> await(K - 1, Ref)
    end.

json(Pairs) ->
    "{" ++ lists:join(",", [kv(K, V) || {K, V} <- Pairs]) ++ "}".

kv(K, null) -> io_lib:format("\"~s\":null", [K]);
kv(K, V) when is_atom(V); is_list(V) -> io_lib:format("\"~s\":\"~s\"", [K, V]);
kv(K, V) when is_number(V) -> io_lib:format("\"~s\":~w", [K, V]);
kv(K, V) -> io_lib:format("\"~s\":\"~w\"", [K, V]).
