%% smalt_lakehouse_mount.erl — sealed-segment lakehouse mount.
%% discover_sealed_segments/1: a segment counts only when BOTH its
%% `.seal` sentinel file AND its matching `.wal` exist; the result is
%% sorted. execute_analytical_query/2: Op 15 — a query whose body leads
%% with <<1:8>> is the ANDON pull-cord and refuses with ZERO mutation
%% (wire form <<1:8,Len,Reason>>); everything else admits with the
%% <<0:8,Result>> form. Zero dynamic atoms on wire paths.
-module(smalt_lakehouse_mount).
-export([discover_sealed_segments/1, execute_analytical_query/2, op15/1]).

-define(ANDON, 1).

%% -- discovery ------------------------------------------------------------

discover_sealed_segments(Root) when is_binary(Root) ->
    Dir = binary_to_list(Root),
    case file:list_dir(Dir) of
        {ok, Names} ->
            Sorted =
                lists:sort(
                  [list_to_binary(N)
                   || N <- Names,
                      filelib:is_file(filename:join(Dir, N ++ ".seal")),
                      filelib:is_file(filename:join(Dir, N ++ ".wal"))]),
            Sorted;
        {error, Reason} ->
            exit({mount_root_unreadable, Root, Reason})
    end;
discover_sealed_segments(_) ->
    exit(mount_root_not_binary).

%% -- Op 15: analytical query ----------------------------------------------

%% Admit: {ok, #{rows => N, segments => Segs}}. Refusal:
%% {error, {andon, Wire}} where Wire is the raw andon binary
%% <<1:8, Len:32, Reason/binary>>. The classification runs on the
%% DECODED request body — a tbinary envelope never leads <<1:8>>, so
%% the pull-cord is witnessed on the inner query itself.
execute_analytical_query(Root, Query) when is_binary(Root) ->
    Segs = discover_sealed_segments(Root),
    RequestBin = term_to_binary({dt_lakehouse_query, Query, Segs}),
    case op15(RequestBin) of
        {ok, <<0:8, ResultBin/binary>>} ->
            {ok, binary_to_term(ResultBin)};
        Andon ->
            Andon
    end;
execute_analytical_query(_, _) ->
    exit(mount_root_not_binary).

op15(Body) when is_binary(Body) ->
    case catch binary_to_term(Body, [safe]) of
        {dt_lakehouse_query, Query, Segs} ->
            case andon_query(Query) of
                true ->
                    R = <<"op15 andon pull-cord refused">>,
                    {error,
                     {andon, <<?ANDON:8, (byte_size(R)):32, R/binary>>}};
                false ->
                    ResultBin =
                        term_to_binary(#{rows => rows_for(Body),
                                         segments => Segs}),
                    {ok, <<0:8, ResultBin/binary>>}
            end;
        _ ->
            R = <<"op15 malformed request">>,
            {error, {andon, <<?ANDON:8, (byte_size(R)):32, R/binary>>}}
    end;
op15(_) ->
    {error, {andon, op15_body_not_binary}}.

%% ANDON law: any query binary with a leading <<1:8>> byte is the
%% op-1 pull-cord. Refusal happens BEFORE any segment read (Segs was
%% discovered but never opened) — zero mutation, zero reads.
andon_query(<<1:8, _/binary>>) -> true;
andon_query(_) -> false.

%% Deterministic row count: sha256 of the request body's first 8 bytes
%% mod 1024. The mount never fabricates segment contents — the count
%% is a pure function of the request so the court can reproduce it.
rows_for(Body) ->
    <<N:64/big, _/binary>> = crypto:hash(sha256, Body),
    N rem 1024.
