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
    {reductions, R0} = process_info(self(), reductions),
    Rows = [bench(N) || N <- Ns],
    {reductions, R1} = process_info(self(), reductions),
    Meta = [
        {kind, meta},
        {module, atom_to_list(?MODULE)},
        {n, null},
        {otp, erlang:system_info(otp_release)},
        {schedulers, S},
        {logical, L},
        {sweep_self_reds, R1 - R0}
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
    %% Per-process reductions ONLY (node-global statistics(reductions)
    %% counts every scheduler — banned per BENCH-ERLANG AR-BENCH; see
    %% bench_aq_boundary_alloc.erl, the strict exemplar).
    {reductions, Reds0} = process_info(self(), reductions),
    %% Nanosecond monotonic clock: ms resolution over 10-50 roundtrips
    %% repeats the quantization bug documented at kafka_vs_aoq_court.erl:264.
    T0 = erlang:monotonic_time(nanosecond),
    roundtrip(Pids, Ref, Rounds),
    T1 = erlang:monotonic_time(nanosecond),
    WallNs = T1 - T0,
    quantization_guard(WallNs, timer_resolution_ns()),
    {reductions, Reds1} = process_info(self(), reductions),
    Total = Reds1 - Reds0,
    RT = N * Rounds,
    [
        {kind, row}, {n, N}, {rounds, Rounds}, {round_trips, RT},
        {wall_ns, WallNs},
        {wall_ms, WallNs / 1.0e6},
        {usec_per_roundtrip, WallNs / 1000.0 / RT},
        {reds_per_roundtrip, Total / RT},
        {ops_per_sec, RT * 1.0e9 / WallNs}
    ].

%% Structural guard: the measured region must span >= 10 ticks of the
%% clock, else the sample is quantization noise (V10 bug class).
quantization_guard(RegionNs, ResNs) when RegionNs >= ResNs * 10 -> ok;
quantization_guard(RegionNs, ResNs) ->
    erlang:error({quantization_risk, RegionNs, ResNs}).

timer_resolution_ns() ->
    %% os_monotonic_time_source reports `resolution` in parts per second
    %% (Hz); one tick in ns = 1e9 / resolution. Conservative 1us fallback.
    case erlang:system_info(os_monotonic_time_source) of
        Src when is_list(Src) ->
            case lists:keyfind(resolution, 1, Src) of
                {resolution, R} when is_integer(R), R > 0 ->
                    erlang:max(1, 1_000_000_000 div R);
                _ -> 1000
            end;
        _ -> 1000
    end.

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
