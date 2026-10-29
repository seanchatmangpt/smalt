%% BENCH-5 — in-process MFA bench of the pure-Erlang FOND/POWL runner
%% (lib/smalt/pipeline/ — smalt_fond_powl_runner, single-sender post-fix
%% protocol). N=5000 4-step settlement orchestrations; aggregate wall +
%% caller reductions + caller heap delta; JSONL to
%% tmp/bench/court_bench_powl.jsonl. Cross-check target: PB-5 gate table
%% post-fix row (p50 0.456 ms, 2117.5 ops/s, n=200, same machine).
%%
%% The per-run gen_statem termination report (a real cost of the post-fix
%% single-sender protocol) is redirected by the SHELL, not by group_leader
%% — the render cost stays INSIDE the timing window, same treatment as
%% PB-5's stderr-suppressed driver.
%%
%% Compile: erlc -o _bench-powl/ebin lib/smalt/pipeline/*.erl bench/bench_powl_pipeline.erl
%% Run:     erl -pa _bench-powl/ebin -noshell -eval 'bench_powl_pipeline:main().' > <log> 2>&1
-module(bench_powl_pipeline).

-export([main/0, main/1]).

-define(N, 5000).
-define(WARMUP, 100).

main() ->
    main(#{}).

main(Opts) ->
    N = maps:get(n, Opts, ?N),
    Results = measure(N),
    Machine = machine_spec(),
    emit_results(Results, Machine),
    #{n := N2, errors := E, agg_wall_ms := W, ops_per_sec := OPS,
      p50_ms := P50, p95_ms := P95, p99_ms := P99, reds_per_op := Reds,
      heap_delta_words := Heap} =
        Results,
    io:format("BENCH5 n=~b ok=~b errors=~b agg_wall_ms=~.1f ops_per_sec=~.1f~n"
              "BENCH5 p50_ms=~.3f p95_ms=~.3f p99_ms=~.3f reds_per_op=~.1f heap_delta_words=~b~n"
              "BENCH5 machine=~0p~n",
              [N2, N2 - E, E, W, OPS, P50, P95, P99, Reds, Heap, Machine]),
    case E of
        0 -> halt(0);
        _ -> halt(1)
    end.

measure(N) ->
    lists:foreach(fun(_) -> one_op() end, lists:seq(1, ?WARMUP)),
    erlang:garbage_collect(),
    {Reds0, Heap0} = self_stats(),
    T0 = erlang:monotonic_time(microsecond),
    PerOp =
        [begin
             T1 = erlang:monotonic_time(microsecond),
             R = one_op(),
             T2 = erlang:monotonic_time(microsecond),
             {T2 - T1, R}
         end
         || _ <- lists:seq(1, N)],
    T3 = erlang:monotonic_time(microsecond),
    erlang:garbage_collect(),
    {Reds1, Heap1} = self_stats(),
    {WallUs, Results} = lists:unzip(PerOp),
    Errors = length([R || R <- Results, element(1, R) =/= ok]),
    Sorted = lists:sort(WallUs),
    Len = length(Sorted),
    #{n => N,
      errors => Errors,
      agg_wall_ms => (T3 - T0) / 1000,
      wall_sum_ms => lists:sum(WallUs) / 1000,
      ops_per_sec => N / ((T3 - T0) / 1_000_000),
      p50_ms => nth_frac(Sorted, Len, 0.50) / 1000,
      p95_ms => nth_frac(Sorted, Len, 0.95) / 1000,
      p99_ms => nth_frac(Sorted, Len, 0.99) / 1000,
      min_ms => hd(Sorted) / 1000,
      max_ms => lists:last(Sorted) / 1000,
      reds_total => Reds1 - Reds0,
      reds_per_op => (Reds1 - Reds0) / N,
      heap_before_words => Heap0,
      heap_after_words => Heap1,
      heap_delta_words => Heap1 - Heap0}.

one_op() ->
    smalt_fond_powl_runner:run(#{tasks => [sttl_open, sttl_capture, sttl_move, sttl_close]}).

self_stats() ->
    {Reds, _} = erlang:statistics(reductions),
    {total_heap_size, Heap} = erlang:process_info(self(), total_heap_size),
    {Reds, Heap}.

nth_frac(Sorted, Len, Frac) ->
    Idx = max(1, min(Len, erlang:round(Frac * Len))),
    lists:nth(Idx, Sorted).

machine_spec() ->
    Cpu = string:trim(os:cmd("sysctl -n machdep.cpu.brand_string")),
    Cores = string:trim(os:cmd("sysctl -n hw.ncpu")),
    RamB = list_to_integer(string:trim(os:cmd("sysctl -n hw.memsize"))),
    #{cpu => Cpu,
      cores => list_to_integer(Cores),
      ram_gb => RamB div (1024 * 1024 * 1024),
      otp => otp_int(),
      darwin => string:trim(os:cmd("sw_vers -productVersion"))}.

otp_int() ->
    case erlang:system_info(otp_release) of
        N when is_integer(N) -> N;
        S when is_list(S) -> list_to_integer(S)
    end.

emit_results(#{n := N,
               errors := E,
               ops_per_sec := OPS,
               p50_ms := P50,
               p95_ms := P95,
               p99_ms := P99,
               agg_wall_ms := W,
               wall_sum_ms := WS,
               reds_total := Reds,
               reds_per_op := RedsPerOp,
               heap_delta_words := Heap,
               min_ms := Min,
               max_ms := Max},
             Machine) ->
    File = "/Users/sac/smalt/tmp/bench/court_bench_powl.jsonl",
    ok = filelib:ensure_dir(File),
    Row =
        [ "{\"lane\":\"bench5\",\"surface\":\"erlang_powl_runner_postfix\","
          "\"op\":\"settlement_orchestration_4step\",\"n\":",
          integer_to_list(N),
          ",\"ops_per_sec\":",
          float_to_list(OPS, [{decimals, 1}]),
          ",\"p50_ms\":",
          float_to_list(P50, [{decimals, 3}]),
          ",\"p95_ms\":",
          float_to_list(P95, [{decimals, 3}]),
          ",\"p99_ms\":",
          float_to_list(P99, [{decimals, 3}]),
          ",\"errors\":",
          integer_to_list(E),
          ",\"machine\":",
          json_machine(Machine),
          ",\"agg_wall_ms\":",
          float_to_list(W, [{decimals, 1}]),
          ",\"wall_sum_ms\":",
          float_to_list(WS, [{decimals, 1}]),
          ",\"reds_total\":",
          integer_to_list(Reds),
          ",\"reds_per_op\":",
          float_to_list(RedsPerOp, [{decimals, 1}]),
          ",\"heap_delta_words\":",
          integer_to_list(Heap),
          ",\"min_ms\":",
          float_to_list(Min, [{decimals, 3}]),
          ",\"max_ms\":",
          float_to_list(Max, [{decimals, 3}]),
          ",\"warmup\":",
          integer_to_list(?WARMUP),
          "}\n"
        ],
    {ok, FD} = file:open(File, [append]),
    try
        io:put_chars(FD, Row)
    after
        file:close(FD)
    end.

json_machine(M) ->
    [ "{\"cpu\":\"",
      json_escape(maps:get(cpu, M)),
      "\",\"cores\":",
      integer_to_list(maps:get(cores, M)),
      ",\"ram_gb\":",
      integer_to_list(maps:get(ram_gb, M)),
      ",\"otp\":",
      integer_to_list(maps:get(otp, M)),
      ",\"darwin\":\"",
      json_escape(maps:get(darwin, M)),
      "\"}" ].

json_escape(S) ->
    string:replace(S, "\"", "\\\"", all).
