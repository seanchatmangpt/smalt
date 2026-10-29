%% smalt_arm_router.erl — universal ARM engine reference router.
%% PUT admits -> 200 + etag + receipt; ANDON op-1 (leading <<1:8>> or
%% x-andon: op-1 header) -> 422 ZERO-MUTATION refusal; GET 200/not_found;
%% DELETE -> tombstone; malformed URI -> 400-class refusal.
%% Storage goes through smalt_journal_sink_compat (real STORE-4 ets ops);
%% body classification through smalt_wasm_pool:gl_call (stub siever).
-module(smalt_arm_router).
-export([put/3, get/1, delete/1, parse_uri/1, receipt_root/1]).

-define(ANDON_OP1, {422, andon_op1_refused, zero_mutation}).

%% -- PUT: admit or refuse --------------------------------------------

put(Uri, Headers, Body) when is_binary(Uri), is_binary(Body) ->
    case parse_uri(Uri) of
        {error, Reason} ->
            {400, Reason, no_receipt};
        Resource ->
            case andon_refusal(Headers, Body) of
                true ->
                    %% ANDON pull-cord: refuse BEFORE any store touch.
                    ?ANDON_OP1;
                false ->
                    {ok, Sieved} = smalt_wasm_pool:gl_call(sieve, Body),
                    case smalt_journal_sink_compat:put(Resource, Body) of
                        {ok, ETag} ->
                            Receipt = receipt(put, Resource, ETag, Sieved),
                            {200, ETag, Receipt};
                        {error, Reason} ->
                            {error, Reason}
                    end
            end
    end;
put(_Uri, _Headers, _Body) ->
    {400, malformed_body, no_receipt}.

%% -- GET --------------------------------------------------------------

get(Uri) when is_binary(Uri) ->
    case parse_uri(Uri) of
        {error, Reason} -> {400, Reason, no_receipt};
        Resource ->
            case smalt_journal_sink_compat:get(Resource) of
                {ok, Value, ETag} -> {200, Value, ETag};
                {error, not_found} -> {404, not_found, no_receipt};
                {error, Reason} -> {error, Reason}
            end
    end;
get(_) ->
    {400, malformed_uri, no_receipt}.

%% -- DELETE: tombstone write, journal keeps the causal record ---------

delete(Uri) when is_binary(Uri) ->
    case parse_uri(Uri) of
        {error, Reason} -> {400, Reason, no_receipt};
        Resource ->
            ok = smalt_journal_sink_compat:delete(Resource),
            {ok, Sieved} =
                smalt_wasm_pool:gl_call(sieve, <<"tombstone">>),
            ETag = tombstone_etag(Resource),
            {200, tombstoned, receipt(delete, Resource, ETag, Sieved)}
    end;
delete(_) ->
    {400, malformed_uri, no_receipt}.

%% -- URI law ----------------------------------------------------------
%% A lawful resource URI is "/subscriptions/<sub>/resourcegroups/<rg>/
%% providers/<prov>/<name>" with every segment non-empty printable binary.
%% Anything else is a 400-class refusal.

parse_uri(Uri) when is_binary(Uri) ->
    Segs = [S || S <- binary:split(Uri, <<"/">>, [global]), S =/= <<>>],
    case valid_segments(Segs) andalso length(Segs) >= 2 of
        true -> {resource, Segs};
        false -> {error, malformed_uri}
    end;
parse_uri(_) ->
    {error, malformed_uri}.

valid_segments([]) -> true;
valid_segments([S | Rest]) ->
    case printable(S) of
        true -> valid_segments(Rest);
        false -> false
    end.

printable(<<>>) -> false;
printable(Bin) -> printable(Bin, true).
printable(<<C, Rest/binary>>, OK) when C >= 16#20, C < 16#7F ->
    printable(Rest, OK);
printable(<<>>, true) -> true;
printable(_, _) -> false.

%% -- ANDON law --------------------------------------------------------

andon_refusal(_Headers, <<1:8, _/binary>>) -> true;
andon_refusal(Headers, _Body) ->
    lists:any(fun
        ({K, V}) when is_binary(K) ->
            lower(K) =:= <<"x-andon">> andalso lower(V) =:= <<"op-1">>;
        ({K, V}) when is_list(K); is_atom(K) ->
            lower(to_bin(K)) =:= <<"x-andon">>
                andalso lower(to_bin(V)) =:= <<"op-1">>;
        (_) -> false
    end, Headers).

lower(Bin) -> list_to_binary(string:to_lower(binary_to_list(Bin))).
to_bin(Bin) when is_binary(Bin) -> Bin;
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(L) when is_list(L) -> list_to_binary(L).

%% -- receipts + merkle ------------------------------------------------

receipt(Op, {resource, Segs}, ETag, Sieved) ->
    #{op => Op,
      resource => Segs,
      etag => ETag,
      wall_ms => os:system_time(millisecond),
      sieved => Sieved}.

%% merkle root over a list of receipts (deployer consumption)
receipt_root(Receipts) ->
    smalt_merkle:root([term_to_binary(R) || R <- Receipts]).

tombstone_etag(Resource) ->
    %% the delete receipt cites the etag minted for the tombstone key
    case ets:lookup(smalt_store:table_for({tombstone, Resource}),
                    {tombstone, Resource}) of
        [{_, _, ETag}] -> ETag;
        [] -> none
    end.
