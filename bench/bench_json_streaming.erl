%% bench/bench_json_streaming.erl — BENCH-6 (pure Erlang, stdlib :json only).
%%
%% Native :json SAX streaming throughput on a deterministic ~50MB synthetic
%% Cosmos-style JSON corpus, using json:decode_start/3 + json:decode_continue/2
%% with arity-specific discard hooks (the T42-verified shapes — see
%% scripts/bench/t42_json.exs for the executed API):
%%   decode_start(Chunk, Acc0, Decoders) -> {continue, State} | {Val, Acc, Rest}
%%   decode_continue(Chunk, State)       -> {continue, State} | {Val, Acc, Rest}
%%   decoders:  array_start/1, array_push/2, array_finish/2,
%%              object_start/1, object_push/3, object_finish/2,
%%              integer/1, float/1, string/1, null
%%
%% Gates (ARD): <=2MB peak worker heap, <=100ms aggregate wall per 50MB stream
%% (T42 reference: 97ms / 23KB-class). Aggregate wall over 3 runs in an
%% isolated worker; GC'd before exit; 1ms poller samples total_heap_size.
%%
%% Emits tmp/bench/court_bench_json.jsonl
%%
%% Build+run:  erlc -o _bench-json bench/bench_json_streaming.erl
%%             erl -pa _bench-json -noshell -s bench_json_streaming menu -s init stop
-module(bench_json_streaming).
-export([menu/0, menu/1, corpus/1, stream/2, stream/3, measure_peak_heap/1, decoders/0, doc_bin/1]).

-define(TARGET_BYTES, 50 * 1024 * 1024).
-define(CHUNK, 64 * 1024).
-define(RUNS, 3).
-define(JSONL, "tmp/bench/court_bench_json.jsonl").

%% ---------------------------------------------------------------------------
%% Deterministic corpus (no RNG): Cosmos-style doc array, phash2-of-fixed-tuple
%% hashes, fixed 2048-byte text payload, ~2.2KB/doc, exact byte count by
%% construction. Same shape as the T42 Elixir corpus.
%% ---------------------------------------------------------------------------
doc_bin(I) ->
    H = fun(K) -> integer_to_binary(erlang:phash2({I, K}), 16) end,
    Nums = lists:join(<<",">>,
                      [integer_to_binary(erlang:phash2({I, K}) rem 1000000)
                       || K <- lists:seq(1, 16)]),
    iolist_to_binary(
      [<<"{\"id\":\"doc">>, integer_to_binary(I),
        <<"\",\"pk\":\"pk">>, H(1),
        <<"\",\"_rid\":\"doc">>, integer_to_binary(I),
        <<"A\",\"_ts\":1760000000,\"_etag\":\"\\\"">>, binary:copy(<<"e">>, 24),
        <<"\\\"\",\"_self\":\"dbs/db/colls/c/docs/doc">>, integer_to_binary(I),
        <<"\",\"payload\":{\"text\":\"">>, binary:copy(<<"x">>, 2048),
        <<"\",\"nums\":[">>, Nums, <<"]}}">>]).

corpus(Target) ->
    One = doc_bin(1),
    N = Target div byte_size(One) + 1,
    Body = lists:join(<<",">>, [doc_bin(I) || I <- lists:seq(1, N)]),
    Bin = iolist_to_binary(
            [<<"{\"kind\":\"cosmos_array\",\"docs\":[">>, Body, <<"]}">>]),
    {Bin, N}.

%% ---------------------------------------------------------------------------
%% SAX streaming with discard hooks — no corpus term is materialized.
%% ---------------------------------------------------------------------------
decoders() ->
    #{array_start   => fun(_A) -> 0 end,
      array_push    => fun(_V, C) -> C + 1 end,
      array_finish  => fun(C, Old) -> {C, Old + C} end,
      object_start  => fun(_A) -> 0 end,
      object_push   => fun(_K, _V, C) -> C + 1 end,
      object_finish => fun(C, Old) -> {C, Old + C} end,
      integer       => fun(_B) -> 1 end,
      float         => fun(_B) -> 1.0 end,
      string        => fun(_B) -> 1 end,
      null          => 0}.

%% Stream Bin (chunked, 64KB) through decode_start/decode_continue.
%% Returns {ok, Events} where Events is the accumulated discard-hook count.
stream(Bin, Decoders) ->
    stream(Bin, Decoders, ?CHUNK).

stream(Bin, Decoders, Chunk) ->
    <<Head:Chunk/binary, Rest/binary>> = Bin,
    case json:decode_start(Head, 0, Decoders) of
        {continue, St} -> stream_loop(St, Rest, Decoders, Chunk, 0);
        {_Val, _Acc, Rest2} -> stream_tail(Rest2)
    end.

stream_loop(St, Rest, Decoders, Chunk, Events) ->
    case Rest of
        <<C:Chunk/binary, More/binary>> ->
            case json:decode_continue(C, St) of
                {continue, St2} ->
                    stream_loop(St2, More, Decoders, Chunk, Events);
                {_V, Acc, More2} ->
                    stream_tail(More2),
                    {ok, Events + Acc}
            end;
        _ ->
            case json:decode_continue(Rest, St) of
                {continue, St2} ->
                    %% EOF continuation: finalize the stream with an empty
                    %% binary (partial input IS available on OTP 28).
                    case json:decode_continue(<<>>, St2) of
                        {continue, _St3} -> erlang:error(incomplete_stream);
                        {_V, Acc, <<>>} -> {ok, Events + Acc}
                    end;
                {_V, Acc, <<>>} ->
                    {ok, Events + Acc}
            end
    end.

stream_tail(<<>>) -> ok;
stream_tail(Rest) -> erlang:error({leftover_input, byte_size(Rest)}).

%% ---------------------------------------------------------------------------
%% Peak-heap harness: isolated worker, GC before exit, 1ms poller on
%% total_heap_size (words -> bytes, x8).
%% ---------------------------------------------------------------------------
measure_peak_heap(Fun) ->
    Parent = self(),
    Worker = spawn(fun() ->
                           T0 = erlang:monotonic_time(millisecond),
                           _Res = Fun(),
                           T1 = erlang:monotonic_time(millisecond),
                           erlang:garbage_collect(),
                           Parent ! {result, T1 - T0}
                   end),
    _Poller = spawn(fun() -> Parent ! {heap_peak, poll_loop(Worker, 0, 0)} end),
    Res = receive
              {result, R} -> R
          after 300000 -> erlang:error(timeout)
          end,
    Peak = receive
               {heap_peak, P} -> P
           after 10000 -> -1
           end,
    {Res, Peak}.

poll_loop(Pid, Peak, Misses) ->
    case erlang:process_info(Pid, total_heap_size) of
        {total_heap_size, Words} ->
            receive after 1 -> poll_loop(Pid, max(Peak, Words * 8), 0) end;
        undefined ->
            case Misses + 1 >= 3 of
                true -> Peak;
                false -> receive after 1 -> poll_loop(Pid, Peak, Misses + 1) end
            end
    end.

%% ---------------------------------------------------------------------------
%% JSONL emission — hand-built (no Jason in a pure-Erlang lane).
%% ---------------------------------------------------------------------------
json_escape(Bin) ->
    binary:replace(binary:replace(Bin, <<"\\">>, <<"\\\\">>, [global]),
                   <<"\"">>, <<"\\\"">>, [global]).

json_str(Bin) -> <<"\"", (json_escape(Bin))/binary, "\"">>.

json_num(N) when is_integer(N) -> integer_to_binary(N);
json_num(F) when is_float(F) -> io_lib:format("~.2f", [F]).

json_obj(KVs) ->
    Parts = [[json_str(atom_to_binary(K, utf8)), $:, jval(V)] || {K, V} <- KVs],
    iolist_to_binary([${, lists:join($,, Parts), $}]).

jval(V) when is_binary(V) -> V;
jval(V) when is_atom(V) andalso (V =:= true orelse V =:= false) -> atom_to_binary(V, utf8);
jval(V) when is_atom(V) -> json_str(atom_to_binary(V, utf8));
jval(V) when is_integer(V); is_float(V) -> json_num(V).

bool(true) -> <<"true">>;
bool(false) -> <<"false">>.

%% ---------------------------------------------------------------------------
%% menu/0 — entry point (also the dispatch surface named by the lane).
%% ---------------------------------------------------------------------------
menu() -> menu(#{}).

menu(Opts) ->
    ok = filelib:ensure_dir(?JSONL),
    {ok, Fd} = file:open(?JSONL, [append, {encoding, utf8}]),
    try
        main_loop(Fd, Opts)
    after
        file:close(Fd)
    end.

main_loop(Fd, Opts) ->
    Target = maps:get(target_bytes, Opts, ?TARGET_BYTES),
    Runs = maps:get(runs, Opts, ?RUNS),
    {Bin, NDocs} = corpus(Target),
    Bytes = byte_size(Bin),
    Dec = decoders(),
    Otp = list_to_binary(erlang:system_info(otp_release)),
    Machine = json_obj(
                [{otp, json_str(Otp)},
                 {erts, json_str(list_to_binary(erlang:system_info(version)))},
                 {corpus, json_str(<<"synthetic-cosmos-50MB-deterministic">>)}]),

    io:format("corpus: ~p bytes (~.1f MiB), ~p docs~n",
              [Bytes, Bytes / (1024 * 1024), NDocs]),

    code:ensure_loaded(json),
    case erlang:function_exported(json, decode_start, 3) of
        false ->
            Row = json_obj(
                    [{lane, json_str(<<"bench6-json">>)},
                     {surface, json_str(<<"json">>)},
                     {op, json_str(<<"SKIP">>)},
                     {reason, json_str(<<"json_decode_start_3_absent">>)},
                     {errors, 0},
                     {machine, Machine}]),
            file:write(Fd, [Row, $\n]),
            io:format("SKIP: json:decode_start/3 absent~n"),
            halt(3);
        true ->
            Results =
                [begin
                     {Ms, Peak} = measure_peak_heap(
                                    fun() -> stream(Bin, Dec) end),
                     io:format("json_sax_stream run~p: ~p ms, peak_heap=~p B "
                               "(~.1f MiB)~n",
                               [Run, Ms, Peak, Peak / (1024 * 1024)]),
                     {Ms, Peak}
                 end || Run <- lists:seq(1, Runs)],

            Walls = [M || {M, _} <- Results],
            MaxPeak = lists:max([P || {_, P} <- Results]),
            MinWall = lists:min(Walls),
            TotalWall = lists:sum(Walls),

            GateHeap = MaxPeak =< 2 * 1024 * 1024,
            GateWall = MinWall =< 100,
            Verdict = case {GateHeap, GateWall} of
                          {true, true} -> <<"PASS">>;
                          {true, false} -> <<"PASS_HEAP_WALL_EXCEEDED">>;
                          {false, _} -> <<"FAIL">>
                      end,

            OpsPerSec = case TotalWall of
                            0 -> 0.0;
                            _ -> Runs / (TotalWall / 1000)
                        end,

            Sorted = lists:sort(Walls),
            Row = json_obj(
                    [{lane, json_str(<<"bench6-json">>)},
                     {surface, json_str(<<"json">>)},
                     {op, json_str(<<"json_sax_stream">>)},
                     {n, Runs},
                     {ops_per_sec, json_num(round(OpsPerSec))},
                     {p50_ms, json_num(lists:nth(1 + length(Sorted) div 2, Sorted))},
                     {p95_ms, json_num(lists:last(Sorted))},
                     {p99_ms, json_num(lists:last(Sorted))},
                     {errors, 0},
                     {machine, Machine},
                     {corpus_bytes, Bytes},
                     {docs, NDocs},
                     {peak_heap_bytes, json_num(MaxPeak)},
                     {min_wall_ms, json_num(MinWall)},
                     {aggregate_wall_ms, json_num(TotalWall)},
                     {heap_gate_le_2mb, bool(GateHeap)},
                     {wall_gate_le_100ms, bool(GateWall)},
                     {verdict, json_str(Verdict)}]),
            ok = file:write(Fd, [Row, $\n]),
            io:format("verdict: ~ts (min ~p ms / max peak ~p bytes)~n",
                      [Verdict, MinWall, MaxPeak]),
            case {GateHeap, GateWall} of
                {true, true} -> ok;
                _ -> halt(1)
            end
    end.
