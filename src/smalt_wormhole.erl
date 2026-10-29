%% smalt_wormhole.erl — time-travel index over frozen universe snapshots
%% (operator reference contract).
%%
%% Algorithm 1 (freeze_universe/2): content-address a quad set
%% (sha256 of term_to_binary), insert into an ordered_set heir'd ETS
%% keyed by the monotonic anchor time (keypos 2, so the key IS t_ns —
%% monotonic ns is globally unique), and append add/drop DELTA frames to
%% the journal so any later point rebuilds in O(k) (k = freezes crossed).
%% Algorithm 2 (time_travel/2): nearest-prior anchor via ets:prev,
%% sha256 integrity check of EVERY crossed snapshot (tamper = loud
%% refusal), then residual delta replay anchor -> target. Id scoping is
%% enforced through the seal_ref {Id, T_ns} field.
%% Theorem 9.4 (optimal_spacing_ms/3): round(sqrt(C_freeze/C_replay * T)).
-module(smalt_wormhole).
-export([start/0, freeze_universe/2, time_travel/2, optimal_spacing_ms/3,
         table/0, lookup/2]).

-record(wormhole, {t_ns,            %% monotonic anchor time (ns) = ETS key
                   seal_ref,        %% {Id, T_ns} content seal
                   universe_hash,   %% sha256(snapshot_bin)
                   quad_count,      %% length of quad set at freeze
                   snapshot_bin}).  %% term_to_binary(quad set)

-define(TAB, smalt_wormhole).

start() ->
    Heir = smalt_store_heir:get_heir_pid(),
    case ets:whereis(?TAB) of
        undefined ->
            case smalt_store:start() of
                ok -> ok;
                {error, already_started} -> ok
            end,
            ets:new(?TAB, [named_table, public, ordered_set,
                           {keypos, 2}, %% key = t_ns, not the record tag
                           {read_concurrency, true},
                           {heir, Heir, []}]),
            ok;
        _ ->
            ok
    end.

table() -> ?TAB.

lookup(Id, Tns) ->
    case ets:lookup(?TAB, Tns) of
        [#wormhole{seal_ref = {Id, Tns}} = W] -> {ok, W};
        _ -> {error, not_found}
    end.

%% -- Algorithm 1: freeze ----------------------------------------------

freeze_universe(Id, Quads) when is_list(Quads) ->
    ok = start(),
    Tns = unique_tns(erlang:monotonic_time(nanosecond)),
    SnapshotBin = term_to_binary(Quads),
    Hash = crypto:hash(sha256, SnapshotBin),
    Prev = prev_entry(Id, Tns),
    Deltas = delta_vs_prev(Prev, Quads),
    true = ets:insert(?TAB, #wormhole{t_ns = Tns,
                                      seal_ref = {Id, Tns},
                                      universe_hash = Hash,
                                      quad_count = length(Quads),
                                      snapshot_bin = SnapshotBin}),
    ok = append_deltas(Id, Tns, Deltas),
    {ok, {Id, Tns}, Hash, length(Quads)}.

%% nearest PRIOR entry of THIS Id (monotonic ns strictly increases, so
%% t_ns < Tns means strictly earlier in time).
prev_entry(Id, Tns) ->
    scan_prev(ets:prev(?TAB, Tns), Id).

%% monotonic ns can repeat across rapid calls — anchors are unique keys
unique_tns(T) ->
    case ets:member(?TAB, T) of
        false -> T;
        true -> unique_tns(T + 1)
    end.

scan_prev('$end_of_table', _Id) -> none;
scan_prev(Tns, Id) when is_integer(Tns) ->
    case lookup(Id, Tns) of
        {ok, W} -> {W, Tns};
        {error, not_found} -> scan_prev(ets:prev(?TAB, Tns), Id)
    end;
scan_prev(_Other, _Id) -> none.

delta_vs_prev(none, Quads) ->
    [{add, Quads}];
delta_vs_prev({W, _Tns}, Quads) ->
    Prev = binary_to_term(W#wormhole.snapshot_bin),
    [{add, lists:subtract(Quads, Prev)},
     {drop, lists:subtract(Prev, Quads)}].

append_deltas(_Id, _Tns, []) -> ok;
append_deltas(Id, Tns, [{Kind, Quads} | Rest]) ->
    {ok, _} = smalt_arm_adapters:append_frame(
                wormhole, {Id, Tns}, Kind, term_to_binary(Quads),
                term_to_binary(#{t_ns => Tns, kind => Kind})),
    append_deltas(Id, Tns, Rest).

%% -- Algorithm 2: time travel -----------------------------------------

time_travel(Id, TargetTns) ->
    ok = ensure_started(),
    case nearest_prior(Id, TargetTns) of
        {error, no_prior_wormhole_anchor} = R ->
            R;
        {AnchorTns, Anchor} ->
            case verify(Id, AnchorTns, Anchor) of
                {error, wormhole_tamper_detected} = R -> R;
                {ok, Quads} ->
                    replay(Id, AnchorTns, TargetTns, Quads, 0)
            end
    end.

ensure_started() ->
    case ets:whereis(?TAB) of
        undefined -> start();
        _ -> ok
    end.

nearest_prior(Id, TargetTns) ->
    case prev_entry(Id, TargetTns) of
        none -> {error, no_prior_wormhole_anchor};
        {W, Tns} -> {Tns, W}
    end.

%% Integrity: recomputed sha256(snapshot_bin) must equal the sealed
%% universe_hash, and the seal must point at its own (Id, T_ns).
verify(Id, Tns, #wormhole{seal_ref = {Id, Tns}, universe_hash = H,
                          snapshot_bin = Bin}) ->
    case crypto:hash(sha256, Bin) of
        H -> {ok, binary_to_term(Bin)};
        _ -> {error, wormhole_tamper_detected}
    end;
verify(_Id, _Tns, _Record) ->
    {error, wormhole_tamper_detected}.

%% O(k) residual replay: for every freeze strictly after the anchor and
%% up to the target, verify that snapshot's integrity, then apply its
%% journal deltas (adds then drops) in time order.
replay(Id, AnchorTns, TargetTns, Quads, K) ->
    case ets:next(?TAB, AnchorTns) of
        '$end_of_table' ->
            done(Id, AnchorTns, Quads, K);
        Tns when is_integer(Tns), Tns =< TargetTns ->
            case lookup(Id, Tns) of
                {error, not_found} ->
                    replay(Id, Tns, TargetTns, Quads, K);
                {ok, W} ->
                    case verify(Id, Tns, W) of
                        {error, wormhole_tamper_detected} = R -> R;
                        {ok, _} ->
                            case apply_deltas(Id, Tns, Quads) of
                                {error, wormhole_tamper_detected} = R -> R;
                                {ok, Quads1} ->
                                    replay(Id, Tns, TargetTns, Quads1, K + 1)
                            end
                    end
            end;
        _ ->
            done(Id, AnchorTns, Quads, K)
    end.

done(Id, _AnchorTns, Quads, K) ->
    {ok, Quads, #{id => Id, replayed => K}}.

apply_deltas(Id, Tns, Quads) ->
    Key = {Id, Tns},
    Frames = smalt_arm_adapters:read_frames(wormhole, Key),
    Adds = [binary_to_term(B) || {add, B, _} <- Frames],
    Drops = [binary_to_term(B) || {drop, B, _} <- Frames],
    case {Adds, Drops} of
        {[], []} ->
            %% every crossed freeze MUST have journaled its delta — a
            %% missing journal record is tamper evidence
            {error, wormhole_tamper_detected};
        _ ->
            Quads1 = lists:foldl(fun(Qs, Acc) -> Qs ++ Acc end, Quads, Adds),
            Quads2 = lists:foldl(fun(Qs, Acc) -> Acc -- Qs end, Quads1, Drops),
            {ok, Quads2}
    end.

%% -- Theorem 9.4 -------------------------------------------------------

optimal_spacing_ms(CFreeze, CReplay, TTotalMs)
        when is_number(CFreeze), CFreeze > 0,
             is_number(CReplay), CReplay > 0,
             is_number(TTotalMs), TTotalMs >= 0 ->
    round(math:sqrt(CFreeze / CReplay * TTotalMs)).
