%% FONDRUNNER — deterministic Merkle seal for the HTN→FOND→POWL→OCEL pipeline.
%%
%% Order-fingerprint gate (IMPL-12 form, operator-sanctioned per
%% docs/jira/v26.10.20... actually docs/jira/v26.10.21/SNIPPET-REVIEW.md §4 and
%% docs/jira/v26.10.21/receipts/impl12-maporder-2912.md WO-PROPOSAL):
%% raw `maps:fold` streaming is admissible ONLY when
%%   (1) otp_release >= 28, AND
%%   (2) a fixed 64-key sentinel map iterates in the pinned release order
%%       (29.1.2: phash2(maps:keys(maps:from_keys(lists:seq(0,63),true))) = 628801).
%% Any mismatch ⇒ typed {:order_fingerprint_mismatch, Got, Want} refusal and
%% NO digest is produced. Determinism is a release-stability fact, not a
%% language guarantee (26.2.1 iterates differently) — the gate converts the
%% premise into an observed invariant.
-module(smalt_fond_seal).

-export([order_gate/0, seal/1, sentinel_fingerprint/0]).

-define(SENTINEL_FP, 628801).

-type ledger() :: #{integer() | binary() => event()}.
-type event() :: binary() | map() | term().
-type digest32() :: <<_:256>>.

%% @doc Gate: toolchain pin (otp_release major >= 28) + order-fingerprint
%% sentinel check. Returns ok only when raw fold order is admissible.
-spec order_gate() -> ok | {refuse, {order_fingerprint_mismatch, integer(), integer()}}.
order_gate() ->
    Want = ?SENTINEL_FP,
    Got = sentinel_fingerprint(),
    case otp_release_major() >= 28 andalso Got =:= Want of
        true -> ok;
        false -> {refuse, {order_fingerprint_mismatch, Got, Want}}
    end.

sentinel_fingerprint() ->
    erlang:phash2(maps:keys(sentinel_map())).

sentinel_map() ->
    maps:from_keys(lists:seq(0, 63), true).

otp_release_major() ->
    case erlang:system_info(otp_release) of
        N when is_integer(N) -> N;
        S when is_list(S) -> list_to_integer(S)
    end.

%% @doc Seal an OCEL event ledger (a map) into a 32-byte Merkle root.
%% Leaf  = sha256(deterministic term_to_binary of the event).
%% Inner = sha256(left ++ right); odd last leaf is duplicated.
%% The walk streams in RAW maps:fold order — lawful only behind order_gate/0.
-spec seal(ledger()) -> {ok, digest32()} | {refuse, {order_fingerprint_mismatch, integer(), integer()}}.
seal(Ledger) when is_map(Ledger) ->
    case order_gate() of
        ok -> {ok, merkle_root(leaves(Ledger))};
        Refuse -> Refuse
    end.

leaves(Ledger) ->
    maps:fold(
        fun(_K, E, Acc) ->
            [crypto:hash(sha256, event_bin(E)) | Acc]
        end,
        [],
        Ledger
    ).

event_bin(E) when is_binary(E) -> E;
event_bin(E) -> erlang:term_to_binary(E, [deterministic]).

merkle_root([]) -> crypto:hash(sha256, <<"smalt-fond-empty-ledger">>);
merkle_root([L]) -> L;
merkle_root(Ls) -> merkle_root(pair(Ls)).

pair([A, B | T]) -> [crypto:hash(sha256, <<A/binary, B/binary>>) | pair(T)];
pair([A]) -> [crypto:hash(sha256, <<A/binary, A/binary>>)];
pair([]) -> [].
