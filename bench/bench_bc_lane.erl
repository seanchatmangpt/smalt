%% bench_bc_lane.erl — v26.11.6 wave+1 BENCH lane BC (bench-conversion lane).
%%
%% Converts three unpinned perf claims into measured, fenced benches over the
%% REAL landed modules (Chicago: real collaborators, no mocks):
%%
%%   BC1  SASL PLAIN admission kernel cost (L10): Smalt.Messaging.Kafka.Sasl
%%        parse_plain/1 + authenticate/2 vs the plaintext (no-SASL) admit
%%        path (zero-admission-work baseline). Ratio = per-admission SASL
%%        overhead. Full-socket handshake: TARGET-UNMEASURED (loopback).
%%   BC2  AOQ partitioned-ring vs stateless-pool submit throughput (L5):
%%        real Partitions registry + PartitionSup + PartitionWorker processes
%%        + real WorkerPool workers, real Cursor atomics, real sends.
%%   BC3  PartitionLog produce engine overhead (L6): full engine
%%        (parser seam + journal append + ETS + hwm) vs the raw
%%        JournalSink.append/5 alone (the journal floor). Ratio = engine
%%        overhead multiplier over the journal floor.
%%
%% Contract (BENCH-ERLANG / smalt_bench_court):
%%   - paired min-of-7 rounds, A/B interleaved round-robin (never all-A-
%%     then-all-B — thermal/heap drift must hit both sides equally);
%%   - the reported min row is the min-WALL round, carrying THAT round's
%%     reds and heap delta (no chimeric min across rounds);
%%   - caller-side reductions via smalt_bench_court:run_benchmark/3
%%     (disclosed: GenServer-side work is NOT in caller reds);
%%   - calibration-then-fence: calibrate/0 writes bc_fences.json from the
%%     calibration run; run/0 reads the fences from the PREVIOUS
%%     calibration (never the current run's ratios) and fail-closes on
%%     breach; a missing fence file -> UNFENCED (loud, exit 0); a corrupt
%%     fence file -> BROKEN, halt 1 (never a silent pass);
%%   - state reset at run start: bc_sink_table, the journal dir and the
%%     PartitionLog tables (smalt_kafka_batches/next) are wiped;
%%   - JSONL receipt: docs/jira/v26.11.6/bench/bc.jsonl — every line
%%     encoded via court_receipt:encode_bc/encode_bc_verdict and
%%     validated via court_receipt:validate_bc_file/1 (hand-rolled
%%     json:encode is banned on this surface).
%%
%% Loopback / single-host scoping disclosed; loopback socket handshakes,
%% restart-under-load and multi-node scaling: TARGET-UNMEASURED.
-module(bench_bc_lane).

-export([calibrate/0, run/0, sasl_admit0/0, plaintext_admit0/0, ring_submit0/0,
         pool_submit0/0, produce0/0, journal_floor0/0, fetch0/0]).

-define(RECEIPT_DIR, "docs/jira/v26.11.6/bench").
-define(RECEIPT_FILE, "bc.jsonl").
-define(FENCE_FILE, "docs/jira/v26.11.6/bench/bc_fences.json").
-define(RINGS, 4).
-define(POOL_WORKERS, 4).
-define(ROUNDS, 7).
-define(SASL_N, 200000).
-define(SUBMIT_N, 20000).
-define(PRODUCE_N, 2000).
-define(FETCH_N, 500).
-define(SASL_FENCE, <<"bc_sasl_overhead_max">>).
-define(RING_FENCE, <<"bc_ring_pool_ratio_min">>).
-define(LOG_FENCE, <<"bc_log_engine_overhead_max">>).

-define(NAME_SASL_A, <<"bc_sasl_plain_admit">>).
-define(NAME_SASL_B, <<"bc_plaintext_admit">>).
-define(NAME_RING_A, <<"bc_ring_submit">>).
-define(NAME_RING_B, <<"bc_pool_submit">>).
-define(NAME_LOG_A, <<"bc_partitionlog_produce">>).
-define(NAME_LOG_B, <<"bc_journal_floor_append">>).
-define(NAME_FETCH, <<"bc_partitionlog_fetch">>).

%% ------------------------------------------------------------------
%% Entry points
%% ------------------------------------------------------------------

calibrate() ->
    {ok, Rows} = boot_and_measure(),
    Fences = fences(Rows),
    ok = write_fences(Fences),
    io:format("CALIBRATE PASS fences=~ts~n~ts~n",
              [?FENCE_FILE, json:encode(Fences)]),
    halt(0).

run() ->
    {ok, Rows} = boot_and_measure(),
    case read_fences() of
        {ok, Fences} ->
            Verdicts = [fence_verdict(Pair, Fences, Rows)
                        || Pair <- [{sasl, ?SASL_FENCE, max},
                                    {ring, ?RING_FENCE, min},
                                    {log, ?LOG_FENCE, max}]],
            emit_jsonl(Rows, Verdicts),
            case [V || {_, _, _, false} = V <- Verdicts] of
                [] ->
                    io:format("BC FENCED RUN PASS~n"),
                    halt(0);
                Bad ->
                    io:format("BC FENCED RUN FAIL ~p~n", [Bad]),
                    halt(1)
            end;
        {error, no_fences} ->
            %% First-ever run (no prior calibration): loud UNFENCED, exit 0.
            Verdicts = [unfenced_verdict(Pair, Rows)
                        || Pair <- [{sasl, ?SASL_FENCE},
                                    {ring, ?RING_FENCE},
                                    {log, ?LOG_FENCE}]],
            emit_jsonl(Rows, Verdicts),
            io:format("BC UNFENCED: no prior calibration at ~ts "
                      "(run calibrate/0 first)~n", [?FENCE_FILE]),
            halt(0);
        {error, broken_fences} ->
            %% Corrupt/incomplete calibration: fail closed, never silent.
            io:format("BC BROKEN: corrupt fence file ~ts — "
                      "re-run calibrate/0~n", [?FENCE_FILE]),
            halt(1)
    end.

boot_and_measure() ->
    case boot() of
        {ok, Ctx} -> {ok, measure(Ctx)};
        {error, R} ->
            io:format("BC FAIL boot: ~p~n", [R]),
            halt(1)
    end.

%% ------------------------------------------------------------------
%% Boot (real collaborators, no mocks)
%% ------------------------------------------------------------------

boot() ->
    ok = reset(),
    {ok, _} = application:ensure_all_started(elixir),
    ok = boot_aoq_tables(),
    {ok, _} = 'Elixir.Smalt.Aoq.Partitions':start_link([{sink, bench_bc_sink}]),
    {ok, _} = 'Elixir.DynamicSupervisor':start_link(
        [{name, 'Elixir.Smalt.Aoq.PartitionSup'}]),
    Rings = [ring_id(I) || I <- lists:seq(1, ?RINGS)],
    [ {ok, _} = 'Elixir.Smalt.Aoq.Partitions':ensure_ring(Rg, [{sink, bench_bc_sink}])
      || Rg <- Rings ],
    {ok, _} = 'Elixir.Smalt.Aoq.WorkerPool':start_link([{workers, ?POOL_WORKERS}]),
    {ok, Sink} = 'Elixir.Smalt.Storage.JournalSink':start_link(
        [{name, bc_kafka_sink}, {dir, <<"tmp/bc-bench/journal">>}]),
    {ok, Log} = 'Elixir.Smalt.Messaging.PartitionLog':start_link(
        [{name, bc_log},
         {sink, bc_kafka_sink},
         {dir, <<"tmp/bc-bench/journal">>},
         {parser, {'Elixir.Smalt.Aoq.Storage', passthrough_parser, []}},
         {guard, nil},
         {fan_out, nil},
         {event_type, 16#414F},
         {log_prefix, <<"bc-bench">>}]),
    {ok, #{rings => Rings, sink => Sink, log => Log}}.

ring_id(I) -> <<"bc-ring-", (integer_to_binary(I))/binary>>.

%% reset/0 — wipe all bench state before a run (no cross-run leakage):
%% the lane sink table, the PartitionLog instance tables and the journal
%% directory (rm -rf, fail-closed on unexpected errors).
reset() ->
    _ = catch ets:delete(bc_sink_table),
    _ = catch ets:delete(smalt_kafka_batches),
    _ = catch ets:delete(smalt_kafka_next),
    rm_rf("tmp/bc-bench/journal").

rm_rf(Dir) ->
    case file:list_dir(Dir) of
        {ok, Entries} ->
            [ begin
                  P = filename:join(Dir, E),
                  case filelib:is_dir(P) of
                      true -> rm_rf(P);
                      false -> ok = file:delete(P)
                  end
              end || E <- Entries ],
            ok = file:del_dir(Dir);
        {error, enoent} ->
            ok;
        {error, R} ->
            erlang:error({rm_rf, Dir, R})
    end.

boot_aoq_tables() ->
    _ = 'Elixir.Smalt.Aoq.Tables':boot([]),
    case ets:info(bc_sink_table) of
        undefined ->
            ets:new(bc_sink_table, [named_table, public, set,
                                    {write_concurrency, true}]);
        _ -> ok
    end,
    ok.

%% ------------------------------------------------------------------
%% Measurement — paired min-of-7 rounds, per-side min wall clock
%% ------------------------------------------------------------------

measure(Ctx) ->
    {SaslA, SaslB} = pair(?NAME_SASL_A, ?NAME_SASL_B, fun sasl_admit/1, fun plaintext_admit/1, ?SASL_N, Ctx),
    {RingA, RingB} = pair(?NAME_RING_A, ?NAME_RING_B, fun ring_submit/1, fun pool_submit/1, ?SUBMIT_N, Ctx),
    {ProdA, ProdB} = pair(?NAME_LOG_A, ?NAME_LOG_B, fun produce/1, fun journal_floor/1, ?PRODUCE_N, Ctx),
    Fetch = min_of([run_one(?NAME_FETCH, fun fetch/1, ?FETCH_N, Ctx)
                    || _ <- lists:seq(1, ?ROUNDS)]),
    #{?NAME_SASL_A => SaslA,
      ?NAME_SASL_B => SaslB,
      ?NAME_RING_A => RingA,
      ?NAME_RING_B => RingB,
      ?NAME_LOG_A => ProdA,
      ?NAME_LOG_B => ProdB,
      ?NAME_FETCH => Fetch}.

%% A/B interleaved round-robin: round k measures A then B, so thermal /
%% heap drift hits both sides symmetrically (never all-A-then-all-B).
pair(NameA, NameB, Fa, Fb, N, Ctx) ->
    pair_rr(?ROUNDS, NameA, Fa, NameB, Fb, N, Ctx, [], []).

pair_rr(0, _, _, _, _, _, _, AccA, AccB) ->
    {min_of(lists:reverse(AccA)), min_of(lists:reverse(AccB))};
pair_rr(K, NameA, Fa, NameB, Fb, N, Ctx, AccA, AccB) ->
    pair_rr(K - 1, NameA, Fa, NameB, Fb, N, Ctx,
            [run_one(NameA, Fa, N, Ctx) | AccA],
            [run_one(NameB, Fb, N, Ctx) | AccB]).

%% Non-chimeric min: pick the min-WALL round and carry THAT round's reds
%% and heap delta — never mix minima from different rounds.
min_of([H | _] = Rows) ->
    N = maps:get(n, H),
    MinWall = lists:min([maps:get(wall_ms, R) || R <- Rows]),
    [Best] = [R || R <- Rows, maps:get(wall_ms, R) =:= MinWall],
    #{name => maps:get(name, H),
      n => N,
      rounds => ?ROUNDS,
      wall_ms => MinWall,
      ops_sec => N * 1.0e9 / (MinWall * 1.0e6),
      ns_per_op => MinWall * 1.0e6 / N,
      reds_per_op => maps:get(reds_per_op, Best),
      heap_delta => maps:get(heap_delta, Best)}.

run_one(Name, Fun, N, Ctx) ->
    R = smalt_bench_court:run_benchmark(Name, fun() -> Fun(Ctx) end, N),
    maps:with([name, n, wall_ms, ops_sec, ns_per_op, reds_per_op, heap_delta], R).

%% ------------------------------------------------------------------
%% BC1 — SASL PLAIN admission kernel vs plaintext admit
%% ------------------------------------------------------------------

sasl_token() ->
    Blob = <<"bc-authzid", 0, "bc-authcid", 0, "bc-password">>,
    Len = byte_size(Blob),
    <<Len:32/unsigned-big, Blob/binary>>.

sasl_admit(_) ->
    Tok = sasl_token(),
    case 'Elixir.Smalt.Messaging.Kafka.Sasl':parse_plain(Tok) of
        {ok, _, _, _} = Parsed ->
            case 'Elixir.Smalt.Messaging.Kafka.Sasl':authenticate(plain, Parsed) of
                {ok, _} -> ok;
                Other -> erlang:error({sasl_refused, Other})
            end;
        Other ->
            erlang:error({sasl_malformed, Other})
    end.

plaintext_admit(_) ->
    %% The no-SASL posture: the conn phase gate boots :open and the frame is
    %% admitted with zero admission work — the honest plaintext baseline.
    ok.

%% ------------------------------------------------------------------
%% BC2 — partitioned ring vs stateless pool submit hot path
%% ------------------------------------------------------------------

ring_submit(#{rings := Rings}) ->
    Frame = <<"bc-frame-payload-0123456789">>,
    [ {ok, _} = 'Elixir.Smalt.Aoq.Partitions':submit(Frame, Rg) || Rg <- Rings ].

pool_submit(_) ->
    Frame = <<"bc-frame-payload-0123456789">>,
    [ {ok, _} = 'Elixir.Smalt.Aoq.WorkerPool':submit(Frame)
      || _ <- lists:seq(1, ?RINGS) ].

%% ------------------------------------------------------------------
%% BC3 — PartitionLog produce vs the journal floor
%% ------------------------------------------------------------------

produce(_) ->
    Raw = crypto:strong_rand_bytes(256),
    {ok, _, _} = 'Elixir.Smalt.Messaging.PartitionLog':produce(
        bc_log, <<"bc-topic">>, 0, [Raw], 16#414F).

journal_floor(_) ->
    Raw = crypto:strong_rand_bytes(256),
    {ok, _} = 'Elixir.Smalt.Storage.JournalSink':append(
        bc_kafka_sink, 16#414F, 0, <<"bc-topic">>, Raw).

fetch(_) ->
    %% The instance's tables default to the kafka literal names (the AoQ
    %% instance shares them, per the moduledoc) — fetch over the same pair
    %% produce writes.
    _ = 'Elixir.Smalt.Messaging.PartitionLog':fetch(
        [{batches, smalt_kafka_batches}, {next, smalt_kafka_next}],
        <<"bc-topic">>, 0, 0).

%% ------------------------------------------------------------------
%% Ratios + fences (calibration-only write path; run/0 reads the PREVIOUS
%% calibration — fences are never derived from the current run's ratios)
%% ------------------------------------------------------------------

fences(Rows) ->
    SaslOverhead = ratio(?NAME_SASL_A, ?NAME_SASL_B, Rows),
    RingPool = ratio(?NAME_RING_A, ?NAME_RING_B, Rows),
    LogOverhead = ratio(?NAME_LOG_A, ?NAME_LOG_B, Rows),
    %% Headroom: 10x on upper-bound fences, 0.5x on the lower-bound fence.
    io:format("ratios: sasl_overhead=~.3f ring_pool=~.3f log_overhead=~.3f~n",
              [SaslOverhead, RingPool, LogOverhead]),
    maps:from_list(
      [{?SASL_FENCE, SaslOverhead * 10.0},
       {?RING_FENCE, RingPool * 0.5},
       {?LOG_FENCE, LogOverhead * 10.0}]).

ratio(NameA, NameB, Rows) ->
    #{wall_ms := WA} = maps:get(NameA, Rows),
    #{wall_ms := WB} = maps:get(NameB, Rows),
    WA / WB.

fence_verdict({Pair, Key, Kind}, Fences, Rows) ->
    {NameA, NameB} = pair_names(Pair),
    R = ratio(NameA, NameB, Rows),
    Fence = maps:get(Key, Fences),
    Pass = case Kind of
               max -> R =< Fence;
               min -> R >= Fence
           end,
    {Key, R, verdict(Pass), Pass}.

pair_names(sasl) -> {?NAME_SASL_A, ?NAME_SASL_B};
pair_names(ring) -> {?NAME_RING_A, ?NAME_RING_B};
pair_names(log)  -> {?NAME_LOG_A, ?NAME_LOG_B}.

verdict(true) -> <<"pass">>;
verdict(false) -> <<"FAIL">>.

%% First-ever run with no prior calibration: ratio is reported but the
%% verdict is UNFENCED (never fabricated into a pass).
unfenced_verdict({Pair, Key}, Rows) ->
    {NameA, NameB} = pair_names(Pair),
    R = ratio(NameA, NameB, Rows),
    {Key, R, <<"UNFENCED">>, true}.

%% ------------------------------------------------------------------
%% Receipt emission
%% ------------------------------------------------------------------

%% Typed read: {ok, Fences} | {error, no_fences} | {error, broken_fences}.
read_fences() ->
    case file:read_file(?FENCE_FILE) of
        {ok, Bin} ->
            try json:decode(Bin) of
                M when is_map(M),
                       is_map_key(?SASL_FENCE, M),
                       is_map_key(?RING_FENCE, M),
                       is_map_key(?LOG_FENCE, M) ->
                    {ok, M};
                _ ->
                    {error, broken_fences}
            catch _:_ ->
                {error, broken_fences}
            end;
        {error, enoent} ->
            {error, no_fences};
        {error, _} ->
            {error, broken_fences}
    end.

write_fences(Fences) ->
    ok = filelib:ensure_dir(?FENCE_FILE),
    ok = file:write_file(?FENCE_FILE, [json:encode(Fences), $\n]).

%% Every emitted line goes through court_receipt (encode_bc /
%% encode_bc_verdict), and the written file is validated back through
%% court_receipt:validate_bc_file/1 — hand-rolled json:encode is banned
%% on this surface.
emit_jsonl(Rows, Verdicts) ->
    ok = filelib:ensure_dir(filename:join(?RECEIPT_DIR, ?RECEIPT_FILE)),
    Path = filename:join(?RECEIPT_DIR, ?RECEIPT_FILE),
    RowBins = [[court_receipt:encode_bc(row_map(R)), $\n]
               || {_, R} <- lists:sort(maps:to_list(Rows))],
    VBin = [[court_receipt:encode_bc_verdict(verdict_map(V)), $\n]
            || V <- Verdicts],
    ok = file:write_file(Path, iolist_to_binary(RowBins ++ VBin)),
    ok = court_receipt:validate_bc_file(Path),
    Path.

row_map(#{name := Name} = R) ->
    #{name => Name,
      wall_ms => maps:get(wall_ms, R),
      ops_per_sec => maps:get(ops_sec, R),
      ns_per_op => maps:get(ns_per_op, R),
      reds_per_op => maps:get(reds_per_op, R),
      n => maps:get(n, R),
      rounds => maps:get(rounds, R),
      heap_delta_bytes => maps:get(heap_delta, R, 0)}.

verdict_map({Key, Ratio, Verdict, _Pass}) ->
    #{fence => Key,
      ratio => Ratio,
      verdict => Verdict}.

%% ------------------------------------------------------------------
%% BC court registrations (smalt_bench_court:add_bc_targets/0) — 0-arity
%% wrappers; ctx-dependent boots happen lazily on first call.
%% ------------------------------------------------------------------



sasl_admit0() -> sasl_admit(undefined).

plaintext_admit0() -> plaintext_admit(undefined).

ring_submit0() -> ring_submit(ring_ctx()).
pool_submit0() -> pool_submit(ring_ctx()).

produce0() -> produce(log_ctx()).
journal_floor0() -> journal_floor(log_ctx()).
fetch0() -> fetch(log_ctx()).

ring_ctx() ->
    ok = boot_ring_only(),
    #{rings => [ring_id(I) || I <- lists:seq(1, ?RINGS)]}.

log_ctx() ->
    ok = boot_log_only(),
    #{rings => [ring_id(I) || I <- lists:seq(1, ?RINGS)]}.

boot_ring_only() ->
    {ok, _} = application:ensure_all_started(elixir),
    ok = boot_aoq_tables(),
    {ok, _} = 'Elixir.Smalt.Aoq.Partitions':start_link([{sink, bench_bc_sink}]),
    {ok, _} = 'Elixir.DynamicSupervisor':start_link(
        [{name, 'Elixir.Smalt.Aoq.PartitionSup'}]),
    [ {ok, _} = 'Elixir.Smalt.Aoq.Partitions':ensure_ring(
        ring_id(I), [{sink, bench_bc_sink}])
      || I <- lists:seq(1, ?RINGS) ],
    {ok, _} = 'Elixir.Smalt.Aoq.WorkerPool':start_link([{workers, ?POOL_WORKERS}]),
    ok.

boot_log_only() ->
    {ok, _} = application:ensure_all_started(elixir),
    {ok, _} = 'Elixir.Smalt.Storage.JournalSink':start_link(
        [{name, bc_kafka_sink}, {dir, <<"tmp/bc-bench/journal">>}]),
    {ok, _} = 'Elixir.Smalt.Messaging.PartitionLog':start_link(
        [{name, bc_log},
         {sink, bc_kafka_sink},
         {dir, <<"tmp/bc-bench/journal">>},
         {parser, {'Elixir.Smalt.Aoq.Storage', passthrough_parser, []}},
         {guard, nil},
         {fan_out, nil},
         {event_type, 16#414F},
         {log_prefix, <<"bc-bench">>}]),
    ok.
