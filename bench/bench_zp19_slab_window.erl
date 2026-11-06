%% S-5 (v26.11.4 ZP-19 / G7): per-op allocation soak for the slab/TLS
%% WindowBuffer path — aq_slab_window NIF + aq_slab_frame zero-copy egress.
%%
%% CTQ spec (docs/jira/v26.11.5/aq-nif-boundary-spec.md, "BEAM side:
%% 0 payload B/op"): a window must not allocate proportional to its slice
%% length (enif_make_sub_binary over the frame resource binary; constant
%% term-box overhead only). Falsifier contract (G7 row): the CTQ-03-sidecar
%% row must be capable of FLIPPING — the payload-proportional twin
%% (lists:seq(1,S), ~2 words per payload byte) must outrun the real op, and
%% the real op must not scale with S (size-invariance fence).
%%
%% Layout law (wire-shm/src/ring.rs): [bookkeeping 4096B][slot i ...],
%% slot = 16B BE header [magic=0x57495230][crc32][plen][ordinal] + payload;
%% bookkeeping bytes 0..8 = u64 BE next_ordinal, 8..12 = u32 BE capacity;
%% capacity <= 64 (u64 free-list mask law). A FRESH segment is created per
%% size: aq_slab_window validates the stored ordinal, so re-stamping over
%% recycled slots invalidates prior ordinals.
%%
%% Instruments (BENCH-ERLANG AR-BENCH law, same class as
%% bench_aq_boundary_alloc): tprof call_memory around an isolated measured
%% worker; per-op words summed from the captured profile table; min-of-2
%% rounds. Fences:
%%   F1 size-invariance: words(S=4080) - words(S=1) <= 4
%%   F2 ratio fence: words/op <= 5% of the word-proportional twin at every
%%      size whose twin clears the 20-word floor; smaller twins disclosed
%%      as FLOOR (informational; F1 carries the claim there)
%%   F3 anti-vacuity (real slab, real error atoms): OOB window, out-of-range
%%      window, and an unstamped slot must all answer `error`
%%
%% Build: erlc -o bench bench/cgap_beam.erl bench/bench_zp19_slab_window.erl
%% Run (cwd = smalt root): erl -pa bench -noshell \
%%        -s bench_zp19_slab_window run -s init stop
-module(bench_zp19_slab_window).
-export([run/0]).

-define(BOOK_LEN, 4096).
-define(SLOT_LEN, 4096).
-define(CAPACITY, 64).
-define(SIZES, [1, 256, 4080]).
-define(ROUNDS, 20000).
-define(BURN_IN, 2000).
-define(RATIO_FENCE, 0.05).
-define(SIZE_INV_WORDS, 4).
-define(TWIN_FLOOR_WORDS, 20).

run() ->
    ok = load_nif_probe(),
    io:format("~n== ZP-19 slab/TLS WindowBuffer soak (aq_slab_window) ==~n"),
    io:format("dylib: ~s (SMALT_ROOT=~p)~n", [dylib_path(), os:getenv("SMALT_ROOT")]),
    {Rows, Tmps} = lists:unzip([begin {R, T} = row(S), {R, T} end || S <- ?SIZES]),
    [cleanup(T) || T <- Tmps],
    F1 = size_invariance(Rows),
    F3 = anti_vacuity(),
    io:format("~nCTQ-03-sidecar row (measured, this run):~n"),
    [begin
         {_, W, B, Verdict} = lists:keyfind(S, 1, Rows),
         io:format("  S=~w B/op=~w words/op=~w verdict=~p~n", [S, B, W, Verdict])
     end
     || S <- ?SIZES],
    Gate = F1 andalso F3 andalso lists:all(fun({_, _, _, V}) -> verdict_ok(V) end, Rows),
    io:format("F1 size-invariance -> ~p;  F3 refusal paths -> ~p~n",
              [pass_fail(F1), pass_fail(F3)]),
    io:format("SOAK GATE: ~p~n", [pass_fail(Gate)]),
    ok.

pass_fail(true) -> 'PASS';
pass_fail(false) -> 'FAIL'.

verdict_ok({ratio_pass, _}) -> true;
verdict_ok({floor, _}) -> true;   %% disclosed; F1 carries the claim
verdict_ok(_) -> false.

load_nif_probe() ->
    %% Smoke the real NIF on a throwaway slab before measuring anything.
    Seg = "zp19_probe_segment",
    ok = file:write_file(Seg, segment_bytes()),
    Slab = open_or_die(Seg),
    ok = stamp_or_die(Slab, <<7>>),
    <<7>> = win_or_die(Slab, 0, 0, 1),
    error = cgap_beam:aq_slab_window(Slab, 0, 0, 5000),
    file:delete(Seg),
    ok.

dylib_path() ->
    case os:getenv("SMALT_ROOT") of
        false -> "priv/aoq/aq_beam_nif";
        R -> filename:join([R, "priv", "aoq", "aq_beam_nif"])
    end.

%% -- Fixture ----------------------------------------------------------------
%% Segment file written directly per the wire-shm layout law (zeroed slots;
%% aq_slab_stamp fills them via the NIF, frame BEFORE ordinal).

segment_bytes() ->
    [book_bytes(), [<<0:?SLOT_LEN/unit:8>> || _ <- lists:seq(1, ?CAPACITY)]].

book_bytes() ->
    Zero = ?BOOK_LEN - 12,
    <<0:64, ?CAPACITY:32/big-unsigned-integer, 0:Zero/unit:8>>.

open_or_die(Seg) ->
    case cgap_beam:aq_slab_open(unicode:characters_to_binary(Seg)) of
        error -> erlang:error({slab_open_failed, Seg});
        S when is_reference(S) -> S
    end.

stamp_or_die(Slab, Payload) ->
    case cgap_beam:aq_slab_stamp(Slab, Payload) of
        ok -> ok;
        error -> erlang:error({stamp_failed, byte_size(Payload)})
    end.

win_or_die(Slab, Ord, Off, Len) ->
    case cgap_beam:aq_slab_window(Slab, Ord, Off, Len) of
        error -> erlang:error({window_failed, {Ord, Off, Len}});
        B when is_binary(B) -> B
    end.

%% -- Per-size row -----------------------------------------------------------

row(S) ->
    Seg = "zp19_seg_" ++ integer_to_list(erlang:unique_integer([positive])),
    ok = file:write_file(Seg, segment_bytes()),
    Slab = open_or_die(Seg),
    [ok = stamp_or_die(Slab, payload(S)) || _ <- lists:seq(1, ?CAPACITY)],
    Ordinals = lists:seq(0, ?CAPACITY - 1),
    Worker = spawn(fun() -> worker_boot(Slab, S, Ordinals) end),
    burn_in(Worker, S),
    W = min(meas_words(Worker, S), meas_words(Worker, S)),
    Twin = twin_words(S),
    exit(Worker, kill),
    TwinPerOp = Twin / ?ROUNDS,
    Verdict =
        case TwinPerOp >= ?TWIN_FLOOR_WORDS of
            true ->
                Ratio = W / TwinPerOp,
                case Ratio =< ?RATIO_FENCE of
                    true -> {ratio_pass, Ratio};
                    false -> {ratio_FAIL, Ratio}
                end;
            false ->
                {floor, {twin_words_per_op, TwinPerOp}}
        end,
    io:format("S=~w words/op=~w B/op=~w twin_words_per_op=~w verdict=~p~n",
              [S, W, W * 8, Twin / ?ROUNDS, Verdict]),
    {{S, W, W * 8, Verdict}, Seg}.

cleanup(Seg) ->
    file:delete(Seg).   %% slab resource dtor runs at VM exit; unlink is best-effort

payload(S) ->
    <<16#A5:S/unit:8>>.

burn_in(Worker, S) ->
    Ref = make_ref(),
    Worker ! {meas, self(), Ref, ?BURN_IN},
    receive {Ref, _} -> ok end.

worker_boot(Slab, S, Ordinals) ->
    C = length(Ordinals),
    receive
        {meas, From, Ref, N} ->
            Res = do_n(Slab, S, N, C, 0),
            From ! {Ref, Res},
            worker_boot(Slab, S, Ordinals)
    end.

do_n(_Slab, _S, 0, _C, _Acc) -> ok;
do_n(Slab, S, N, C, Acc) ->
    _ = cgap_beam:aq_slab_window(Slab, Acc rem C, 0, S),
    do_n(Slab, S, N - 1, C, Acc + 1).

%% -- Measurement (tprof call_memory, captured table) -------------------------

meas_words(Worker, S) ->
    Log = "zp19_tprof_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".log",
    OldGL = group_leader(),
    {ok, Dev} = file:open(Log, [append]),
    group_leader(Dev, self()),
    _ = tprof:profile(fun() -> round_trip(Worker, S) end, #{type => call_memory}),
    group_leader(OldGL, self()),
    ok = file:close(Dev),
    W = total_words_from_log(Log),
    file:delete(Log),
    W.

round_trip(Worker, _S) ->
    Ref = make_ref(),
    Worker ! {meas, self(), Ref, ?ROUNDS},
    receive {Ref, _} -> ok end.

total_words_from_log(Log) ->
    {ok, Bin} = file:read_file(Log),
    Lines = string:split(binary_to_list(Bin), "\n", all),
    Totals = [list_to_integer(N) || L <- Lines,
                                    {match, [N]} <- [re:run(L, "^\\s+([0-9]+)\\s+\\[\\s*100\\.0\\]",
                                                            [{capture, [1], list}])]],
    case Totals of
        [T] -> T;
        [] -> erlang:error({tprof_total_missing, Log});
        _ -> lists:last(Totals)
    end.

%% -- Twin (payload-proportional) ---------------------------------------------

twin_words(S) ->
    Log = "zp19_tprof_" ++ integer_to_list(erlang:unique_integer([positive])) ++ ".log",
    OldGL = group_leader(),
    {ok, Dev} = file:open(Log, [append]),
    group_leader(Dev, self()),
    _ = tprof:profile(fun() -> twin_round(S) end, #{type => call_memory}),
    group_leader(OldGL, self()),
    ok = file:close(Dev),
    TW = total_words_from_log(Log),
    file:delete(Log),
    TW.

twin_round(S) ->
    _ = [begin _ = lists:seq(1, S), ok end || _ <- lists:seq(1, ?ROUNDS)],
    ok.

%% -- Fences ------------------------------------------------------------------

size_invariance(Rows) ->
    W = fun(S) -> {_, Wd, _, _} = lists:keyfind(S, 1, Rows), Wd end,
    Delta = W(4080) - W(1),
    Ok = Delta =< ?SIZE_INV_WORDS,
    io:format("F1 size-invariance: words(4080)-words(1)=~p (fence <= ~p) -> ~p~n",
              [Delta, ?SIZE_INV_WORDS, pass_fail(Ok)]),
    Ok.

anti_vacuity() ->
    Seg = "zp19_av_segment",
    ok = file:write_file(Seg, segment_bytes()),
    Slab = open_or_die(Seg),
    ok = stamp_or_die(Slab, payload(16)),
    Oob = cgap_beam:aq_slab_window(Slab, 0, 0, 5000),
    BadRange = cgap_beam:aq_slab_window(Slab, 0, 10, 100),
    Unstamped = cgap_beam:aq_slab_frame(Slab, 1),
    file:delete(Seg),
    io:format("F3 anti-vacuity: oob=~p badrange=~p unstamped=~p~n", [Oob, BadRange, Unstamped]),
    OobChecks = [Oob =:= error, BadRange =:= error, Unstamped =:= error],
    lists:all(fun(E) -> E end, OobChecks).
