%% smalt_store.erl — STORE-4 facade over the 16 phash2 partitions.
%% get/1 bypasses ALL mailboxes: direct ets:lookup on the public named
%% partition table. put_cas/delete route via phash2(Key, 16) to the
%% owning partition worker for serialized CAS.
-module(smalt_store).
-export([start/0, stop/0, get/1, put_cas/2, put_cas/3, delete/1,
         partition_of/1, table_for/1]).

-define(PARTITIONS, 16).

start() ->
    case whereis(smalt_store_sup) of
        undefined -> {ok, _} = smalt_store_sup:start_link(), ok;
        _ -> {error, already_started}
    end.

stop() ->
    case whereis(smalt_store_sup) of
        undefined -> ok;
        Sup ->
            try exit(Sup, shutdown) catch _:_ -> ok end,
            %% bounded wait for full teardown so re-boot in a court is clean
            stop_wait(200)
    end.

stop_wait(0) -> ok;
stop_wait(N) ->
    case whereis(smalt_store_sup) of
        undefined -> ok;
        _ -> erlang:yield(), stop_wait(N - 1)
    end.

partition_of(Key) -> erlang:phash2(Key, ?PARTITIONS).

table_for(Key) ->
    %% deterministic partition naming (mirrors smalt_store_partition)
    list_to_atom("smalt_store_p" ++
                 integer_to_list(erlang:phash2(Key, ?PARTITIONS))).

get(Key) ->
    case ets:lookup(table_for(Key), Key) of
        [{Key, Value, _ETag}] -> {ok, Value};
        [] -> {error, not_found}
    end.

put_cas(Key, Value, ETagExpect) ->
    smalt_store_partition:put_cas(partition_of(Key), Key,
                                  Value, ETagExpect).

put_cas(Key, Value) ->
    put_cas(Key, Value, any).

delete(Key) ->
    smalt_store_partition:delete(partition_of(Key), Key).
