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
      reds_per_op := Reds, heap_delta_words := Heap} =
        Results,
    io:format("BENCH5 n=~b ok=~b errors=~b agg_wall_ms=~.1f ops_per_sec=~.1f~n"
              "BENCH5 reds_per_op=~.1f heap_delta_words=~b~n"
              "BENCH5 machine=~0p~n",
              [N2, N2 - E, E, W, OPS, Reds, Heap, Machine]),
    case E of
        0 -> halt(0);
        _ -> halt(1)
    end.

measure(N) ->
    lists:foreach(fun(_) -> one_op() end, lists:seq(1, ?WARMUP)),
    %% GC fence before the timed region (kept).
    erlang:garbage_collect(),
    {Reds0, Heap0} = self_stats(),
    %% BATCH-timed region: the two timer calls are hoisted OUTSIDE the
    %% per-op samples — per-op brackets previously paid 2 timer calls per
    %% op into every sample (V10 finding). Reductions/heap sampled outside
    %% the bracket too. Per-op percentile walls are therefore NOT
    %% measurable without per-op timer calls; the aggregate wall carries
    %% the claim (same treatment as bench_amqp_frame.erl).
    T0 = erlang:monotonic_time(microsecond),
    Results = [one_op() || _ <- lists:seq(1, N)],
    T3 = erlang:monotonic_time(microsecond),
    WallUs = T3 - T0,
    %% Quantization guard: the region must span >= 10 ticks of the clock.
    case WallUs >= 10 of
        true -> ok;
        false -> erlang:error({quantization_risk, wall_us, WallUs})
    end,
    %% GC fence after the timed region (kept).
    erlang:garbage_collect(),
    {Reds1, Heap1} = self_stats(),
    Errors = length([R || R <- Results, element(1, R) =/= ok]),
    #{n => N,
      errors => Errors,
      agg_wall_ms => WallUs / 1000,
      ops_per_sec => N / (WallUs / 1_000_000),
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
               agg_wall_ms := W,
               reds_total := Reds,
               reds_per_op := RedsPerOp,
               heap_delta_words := Heap},
             Machine) ->
    File = "/Users/sac/smalt/tmp/bench/court_bench_powl.jsonl",
    ok = filelib:ensure_dir(File),
    Row =
        [ "{\"lane\":\"bench5\",\"surface\":\"erlang_powl_runner_postfix\","
          "\"op\":\"settlement_orchestration_4step\",\"n\":",
          integer_to_list(N),
          ",\"ops_per_sec\":",
          float_to_list(OPS, [{decimals, 1}]),
          ",\"errors\":",
          integer_to_list(E),
          ",\"machine\":",
          json_machine(Machine),
          ",\"agg_wall_ms\":",
          float_to_list(W, [{decimals, 1}]),
          ",\"reds_total\":",
          integer_to_list(Reds),
          ",\"reds_per_op\":",
          float_to_list(RedsPerOp, [{decimals, 1}]),
          ",\"heap_delta_words\":",
          integer_to_list(Heap),
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
