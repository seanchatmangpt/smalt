%% BENCH-4: pure-Erlang AMQP frame-decode throughput harness.
%%
%% Method: the smalt beams are Mix-built (Elixir sources in
%% lib/smalt/messaging/amqp/ cannot be compiled by erlc — documented choice:
%% the lane loads the Mix-built beams from MIX_BUILD_ROOT=_bench-amqp via
%% code path, the lawful alternative the lane charter permits). The harness
%% itself is pure Erlang: no Elixir runtime constructs beyond calling the
%% compiled modules.
%%
%% Shape pinned to IMPL-17/IMPL-13: one 1582-byte transfer frame (header +
%% properties + application_properties + 1400-byte body_data,
%% Service-Bus-dialect sections), built with encode_frame/3 and decoded
%% 100k times via decode_frame/1, pure module calls, no app boot.
%% Cross-check target: 254.3 reds/frame (receipts/impl13-jit-2912.md).
%%
%% Build:  erlc -o bench bench/bench_amqp_frame.erl
%% Run:    erl -pa <elixir-stdlib-ebins> -pa _bench-amqp/dev/lib/smalt/ebin \
%%             -pa bench -noshell -s bench_amqp_frame run -s init stop
-module(bench_amqp_frame).
-export([run/0]).

-define(N, 100000).
-define(ROUNDS_PER_RUN, 5).
-define(RUNS, 3).

run() ->
    logger:set_primary_config(level, warning),
    Frame = build_frame(),
    Size = byte_size(Frame),
    true = Size > 1500 andalso Size < 2400, %% assert IMPL-13 shape
    {ok, _} = 'Elixir.Smalt.Amqp.FrameCodec':decode_frame(Frame),
    io:format("frame_bytes=~p~n", [Size]),
    Runs = [one_run(I, Frame) || I <- lists:seq(1, ?RUNS)],
    {BestMs, BestReds} = lists:min(Runs),
    RedsPerFrame = BestReds / ?N,
    OpsPerSec = ?N / (BestMs / 1000),
    UsPerFrame = BestMs * 1000 / ?N,
    io:format("AMQPFRAME otp=~s erts=17.x n=~p best_wall_ms=~p best_reductions=~p "
              "us_per_frame=~s reds_per_frame=~s ops_per_sec=~s~n",
              [erlang:system_info(otp_release),
               ?N, BestMs, BestReds, f(UsPerFrame, 2), f(RedsPerFrame, 1),
               f(OpsPerSec, 0)]),
    emit(Size, Runs, BestReds, RedsPerFrame, OpsPerSec, UsPerFrame),
    ok.

%% min-of-rounds inside each run; the 3 per-run walls are the percentile samples
one_run(_I, Frame) ->
    lists:min(
      [begin
           {R0, _} = erlang:statistics(reductions),
           T0 = erlang:monotonic_time(millisecond),
           ok = decode_loop(?N, Frame),
           T1 = erlang:monotonic_time(millisecond),
           {R1, _} = erlang:statistics(reductions),
           {T1 - T0, R1 - R0}
       end || _ <- lists:seq(1, ?ROUNDS_PER_RUN)]).

decode_loop(0, _Frame) -> ok;
decode_loop(K, Frame) ->
    {ok, _Decoded} = 'Elixir.Smalt.Amqp.FrameCodec':decode_frame(Frame),
    decode_loop(K - 1, Frame).

build_frame() ->
    Sections =
        [{header, #{delivery_count => 0, ttl => 60000}},
         {properties, #{message_id => <<"impl13-000123">>,
                        creation_time => {timestamp, 1760000000000},
                        to => <<"q/impl13-bench">>,
                        subject => <<"bench-transfer">>,
                        content_type => <<"application/json">>}},
         {application_properties,
           #{<<"correlation_id">> => <<"9f8e7d6c">>,
             <<"attempt">> => 2}},
         {body_data, binary:copy(<<"x">>, 1400)}],
    Transfer =
        {transfer, #{handle => 0, delivery_id => 1,
                     delivery_tag => <<"impl13">>, settled => true,
                     message_format => 0},
         {sections, Sections}},
    iolist_to_binary(
      'Elixir.Smalt.Amqp.FrameCodec':encode_frame(amqp, 0, Transfer)).

%% Emit one jsonl row:
%% {lane, surface, op, n, ops_per_sec, p50_ms, p95_ms, p99_ms, errors, machine}
emit(Size, Runs, BestReds, RedsPerFrame, OpsPerSec, UsPerFrame) ->
    {ok, MachineJson} = file:read_file("tmp/bench/machine.json"),
    WallsMs = lists:sort([W || {W, _} <- Runs]),
    Nth = fun(P) ->
              Idx = min(erlang:ceil(P * length(WallsMs)), length(WallsMs)),
              lists:nth(Idx, WallsMs)
          end,
    Machine = machine_str(MachineJson),
    Row = ["{\"lane\":\"bench4-amqp-frame\",\"surface\":\"amqp_frame_decode\","
           "\"op\":\"decode_frame\",\"n\":", integer_to_list(?N),
           ",\"frame_bytes\":", integer_to_list(Size),
           ",\"ops_per_sec\":", f(OpsPerSec, 0),
           ",\"p50_ms\":", integer_to_list(Nth(0.50)),
           ",\"p95_ms\":", integer_to_list(Nth(0.95)),
           ",\"p99_ms\":", integer_to_list(Nth(0.99)),
           ",\"best_reductions\":", integer_to_list(BestReds),
           ",\"reds_per_frame\":", f(RedsPerFrame, 1),
           ",\"us_per_frame\":", f(UsPerFrame, 2),
           ",\"errors\":0,\"machine\":\"", Machine, "\"}\n"],
    ok = filelib:ensure_dir("tmp/bench/court_bench_amqp.jsonl"),
    ok = file:write_file("tmp/bench/court_bench_amqp.jsonl", Row, [append]).

f(X, D) -> binary_to_list(erlang:float_to_binary(X * 1.0, [{decimals, D}, compact])).

machine_str(Json) ->
    Cpu = grab(Json, <<"cpu">>),
    Otp = grab(Json, <<"otp">>),
    binary_to_list(<<Cpu/binary, "/otp-", Otp/binary>>).

grab(Json, Key) ->
    Pattern = iolist_to_binary([$", Key, $", $:]),
    case binary:split(Json, Pattern) of
        [_, Rest] -> val(Rest);
        _ -> <<"unknown">>
    end.

val(<<$", Rest/binary>>) -> val(Rest);
val(Rest) ->
    case binary:split(Rest, <<"\"">>) of
        [V, _] -> V;
        _ -> <<"unknown">>
    end.
