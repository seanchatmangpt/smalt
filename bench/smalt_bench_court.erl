%% smalt bench court core — pure Erlang, no Mix.
%% BENCH-2 (writer lane; built + smoked on local erlmcp OTP 28.3.1).
%%
%% run_benchmark/3: aggregate wall-clock timing (monotonic ns), reduction
%% accounting via statistics(reductions), GC-stabilized heap delta.
%% Sampling law: the AFTER heap sample is taken AFTER gc_stabilize() —
%% both endpoints are GC-stabilized, never one raw / one collected.
%% Driver-overhead disclosure: the bench loop itself (do_n recursion +
%% retained last result) costs wall-time and reductions that are IN the
%% timed region; the same driver is measured over a noop fun at the same
%% N and disclosed in every row as driver_wall_ms + driver_reds_per_op,
%% so per-op math is never silently attributed to the bench body.
%% Receipts: one JSONL row per bench -> tmp/bench/court_bench_<ts>.jsonl
%% Row fields: name, n, wall_ms, ops_sec, ns_per_op, reds_per_op,
%% heap_delta, driver_wall_ms, driver_reds_per_op.
%%
%% Dispatch table: real-plane targets register via add_target/3 (Name, Mod, Fun);
%% follow-on lanes land their modules and add entries (run_registered/2).
-module(smalt_bench_court).

-export([run_benchmark/3, run_all/1, emit_receipt/2, add_target/3,
         run_registered/2, list_targets/0, court_selftest/0, add_bc_targets/0]).

-define(RECEIPT_DIR, "tmp/bench").
-define(FIELDS, [n, wall_ms, ops_sec, ns_per_op, reds_per_op, heap_delta,
                 driver_wall_ms, driver_reds_per_op]).

%% ------------------------------------------------------------------
%% Public API
%% ------------------------------------------------------------------

%% run_benchmark(Name, fun(() -> any()), N) -> map()
%% Runs Fun N times; the Fun must do ONE unit of bench work (the loop
%% belongs to us, so reductions attribute to the bench, not a wrapper).
run_benchmark(Name, Fun, N) when is_function(Fun, 0), is_integer(N), N > 0 ->
    {DrvWallNs, DrvReds} = driver_overhead(N),
    gc_stabilize(),
    {HeapBefore, RedBefore} = heap_and_reds(),
    T0 = erlang:monotonic_time(nanosecond),
    _LastLive = do_n(Fun, N), %% held live through the after-sample (see do_n/2)
    T1 = erlang:monotonic_time(nanosecond),
    gc_stabilize(),
    {HeapAfter, RedAfter} = heap_and_reds(),
    WallNs = max(1, T1 - T0),
    Reds = max(0, RedAfter - RedBefore),
    #{name => to_bin(Name),
      n => N,
      wall_ms => WallNs / 1.0e6,
      ops_sec => N * 1.0e9 / WallNs,
      ns_per_op => WallNs / N,
      reds_per_op => Reds / N,
      heap_delta => (HeapAfter - HeapBefore) * erlang:system_info(wordsize),
      driver_wall_ms => DrvWallNs / 1.0e6,
      driver_reds_per_op => DrvReds / N}.

%% Run a list of {Name, Fun, N} benches and emit one receipt file.
run_all(Benches) ->
    Rows = [run_benchmark(Nm, F, N) || {Nm, F, N} <- Benches],
    File = emit_receipt(Rows, receipt_path()),
    #{rows => Rows, receipt => File}.

%% Emit rows as JSONL. Returns the receipt path.
emit_receipt(Rows, Path) ->
    filelib:ensure_dir(Path),
    Data = iolist_to_binary([[json_row(R), $\n] || R <- Rows]),
    ok = file:write_file(Path, Data),
    Path.

%% Dispatch table (persistent_term-backed).
add_target(Name, Mod, Fun) when is_atom(Mod), is_atom(Fun) ->
    persistent_term:put({?MODULE, target, to_bin(Name)}, {Mod, Fun}),
    ok.

list_targets() ->
    [Name || {{?MODULE, target, Name}, _} <- persistent_term:get()].

%% Run a registered target: Mod:Fun() executed N times.
run_registered(Name, N) ->
    {Mod, Fun} = persistent_term:get({?MODULE, target, to_bin(Name)}),
    run_benchmark(Name, fun() -> Mod:Fun() end, N).

%% ------------------------------------------------------------------
%% Court selftest: 3 stub benches, receipt well-formedness.
%% Exit 0 = PASS, exit 1 = FAIL (fail-closed).
%% ------------------------------------------------------------------
court_selftest() ->
    T = ets_stub_table,
    _ = case ets:info(T) of
            undefined -> ets:new(T, [named_table, public, set]);
            _ -> ok
        end,
    Benches = [{<<"stub-noop">>, fun() -> ok end, 1000},
               {<<"stub-count">>, fun() -> ets_stub() end, 500},
               {<<"stub-arith">>, fun() -> erlang:phash2(lists:seq(1, 16)) end, 200}],
    try run_all(Benches) of
        #{rows := Rows, receipt := File} ->
            case validate_rows(Rows, File) of
                ok ->
                    io:format("COURT PASS rows=~p receipt=~s~n", [length(Rows), File]),
                    halt(0);
                {fail, Reason} ->
                    io:format("COURT FAIL ~s~n", [Reason]),
                    halt(1)
            end
    catch C:R:ST ->
        io:format("COURT FAIL ~p:~p~n~p~n", [C, R, ST]),
        halt(1)
    end.

validate_rows(Rows, File) ->
    Bad = [maps:get(name, R) || R <- Rows,
                                not is_binary(maps:get(name, R, none)) orelse
                                byte_size(maps:get(name, R)) =:= 0 orelse
                                [K || K <- ?FIELDS, not is_number(maps:get(K, R, none))] =/= []],
    case Bad of
        [] ->
            case parse_jsonl(File) of
                {ok, Count} when Count =:= length(Rows) -> ok;
                {ok, Count} ->
                    {fail, io_lib:format("jsonl rows ~p != ~p", [Count, length(Rows)])};
                {error, E} ->
                    {fail, io_lib:format("jsonl parse: ~p", [E])}
            end;
        _ ->
            {fail, io_lib:format("malformed rows: ~p", [Bad])}
    end.

%% Lightweight JSONL structural parse (pure Erlang, no deps): each line is a
%% balanced-brace JSON object containing every required field name.
parse_jsonl(File) ->
    case file:read_file(File) of
        {ok, Bin} ->
            Lines = [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>],
            Bad = [L || L <- Lines, not balanced_object(L)],
            case Bad of
                [] -> {ok, length(Lines)};
                _ -> {error, {unbalanced_lines, length(Bad)}}
            end;
        {error, E} ->
            {error, E}
    end.

balanced_object(L) ->
    binary:first(L) =:= ${ andalso binary:last(L) =:= $}
        andalso count(${, L) =:= count($}, L)
        andalso [K || K <- [<<"name">>, <<"wall_ms">>, <<"ops_sec">>],
                      binary:match(L, K) =:= nomatch] =:= [].

count(C, Bin) -> length(binary:matches(Bin, <<C>>)).

%% ------------------------------------------------------------------
%% Internal
%% ------------------------------------------------------------------

%% The loop keeps the LAST result live through the after-sample so the
%% heap delta reflects a real allocation footprint for allocating benches
%% (a fully-dropped result would read as 0 delta after GC stabilization).
do_n(Fun, N) -> do_n(Fun, N, undefined).
do_n(_Fun, 0, Last) -> Last;
do_n(Fun, N, _Prev) -> do_n(Fun, N - 1, Fun()).

%% The driver loop itself, measured over a noop fun at the same N.
driver_overhead(N) ->
    gc_stabilize(),
    {_, Red0} = heap_and_reds(),
    T0 = erlang:monotonic_time(nanosecond),
    do_n(fun() -> ok end, N),
    T1 = erlang:monotonic_time(nanosecond),
    {_, Red1} = heap_and_reds(),
    {max(1, T1 - T0), max(0, Red1 - Red0)}.

%% A single full-sweep collect is the stabilization; the second collect
%% was a no-op (nothing new to collect between two back-to-back sweeps).
gc_stabilize() ->
    erlang:garbage_collect(self()).

heap_and_reds() ->
    {heap_size, HeapWords} = erlang:process_info(self(), heap_size),
    Reds = case statistics(reductions) of
               {Total, _SinceLastCall} -> Total;
               Total when is_integer(Total) -> Total
           end,
    {HeapWords, Reds}.

receipt_path() ->
    Ts = calendar:system_time_to_rfc3339(erlang:system_time(millisecond),
                                         [{unit, millisecond}, {offset, "Z"}]),
    Flat = re:replace(Ts, "[-:]", "", [global, {return, list}]),
    filename:join(?RECEIPT_DIR, "court_bench_" ++ Flat ++ ".jsonl").

to_bin(N) when is_binary(N) -> N;
to_bin(N) when is_atom(N) -> atom_to_binary(N);
to_bin(N) when is_list(N) -> list_to_binary(N).

json_row(#{name := Name} = R) ->
    Fields = [[",\"", atom_to_binary(K), "\":", num(maps:get(K, R))] || K <- ?FIELDS],
    iolist_to_binary([<<"{\"name\":\"">>, Name, <<"\"">>, Fields, <<"}">>]).

num(N) when is_integer(N) ->
    integer_to_binary(N);
num(N) when is_float(N) ->
    S = iolist_to_binary(io_lib:format("~.3f", [N])),
    NoTrail = re:replace(S, <<"(\.[0-9]*[1-9])0+$">>, <<"\\1">>, [{return, binary}]),
    re:replace(NoTrail, <<"\.000$">>, <<>>, [{return, binary}]).

%% ------------------------------------------------------------------
%% stub collaborator: a real ETS insert+lookup (Chicago: real state)
%% ------------------------------------------------------------------
ets_stub() ->
    T = ets_stub_table,
    ets:insert(T, {k, erlang:unique_integer()}),
    ets:lookup(T, k).

%% ------------------------------------------------------------------
%% BC lane (v26.11.6 wave+1) — ADDITIVE registrations only. The BC benches
%% that fit the 0-arity Mod:Fun() contract register here; run_registered/2
%% runs them through the standard run_benchmark/3 accounting. The ctx-bound
%% pairs (ring/pool/log) boot their collaborators on first call.
%% ------------------------------------------------------------------

add_bc_targets() ->
    ok = add_target(<<"bc_sasl_plain_admit">>, bench_bc_lane, sasl_admit0),
    ok = add_target(<<"bc_plaintext_admit">>, bench_bc_lane, plaintext_admit0),
    ok = add_target(<<"bc_ring_submit">>, bench_bc_lane, ring_submit0),
    ok = add_target(<<"bc_pool_submit">>, bench_bc_lane, pool_submit0),
    ok = add_target(<<"bc_partitionlog_produce">>, bench_bc_lane, produce0),
    ok = add_target(<<"bc_journal_floor_append">>, bench_bc_lane, journal_floor0),
    ok = add_target(<<"bc_partitionlog_fetch">>, bench_bc_lane, fetch0),
    ok.
