%% smalt_journal_sink_compat.erl — thin adapter the ARM references call.
%% Maps journal-sink ops (put/get/delete) onto the real STORE-4 store:
%% smalt_store:put_cas/get/delete against the 16 phash2 partition tables.
%% Delete is a TOMBSTONE write ({tombstone} marker + monotone seq), not a
%% removal — GET over a tombstone reads {error, not_found} while the
%% journal keeps the causal record.
-module(smalt_journal_sink_compat).
-export([put/2, put/3, get/1, delete/1, tombstone_key/1, entry/1]).

-define(TOMBSTONE, {tombstone}).

put(Key, Value) -> put(Key, Value, any).

put(Key, Value, ETagExpect) ->
    case smalt_store:put_cas(Key, Value, ETagExpect) of
        ok -> {ok, etag_for(Key)};
        Other -> Other
    end.

get(Key) ->
    %% read the stored tuple directly: the etag is the one minted at write
    %% time (etag_for/1 uses unique_integer — recomputing would lie).
    case ets:lookup(smalt_store:table_for(Key), Key) of
        [{Key, ?TOMBSTONE, _}] -> {error, not_found};
        [{Key, {tombstone, _Seq}, _}] -> {error, not_found};
        [{Key, Value, ETag}] -> {ok, Value, ETag};
        [] -> {error, not_found}
    end.

delete(Key) ->
    TKey = tombstone_key(Key),
    Seq = erlang:monotonic_time(millisecond),
    %% `any` only means insert-if-absent in the store's CAS law: overwriting
    %% an existing key requires the CURRENT etag, so read it first.
    ok = cas_write(TKey, ?TOMBSTONE),
    ok = cas_write(Key, {tombstone, Seq}),
    ok.

cas_write(Key, Value) ->
    Expect = case ets:lookup(smalt_store:table_for(Key), Key) of
                 [{Key, _V, ETag}] -> ETag;
                 [] -> any
             end,
    case smalt_store:put_cas(Key, Value, Expect) of
        ok -> ok;
        {error, etag_mismatch} -> cas_write(Key, Value)  %% CAS retry
    end.

%% -- helpers ----------------------------------------------------------

tombstone_key(Key) -> {tombstone, Key}.

%% ETag of a key = the etag currently stored in its partition table.
entry(Key) ->
    [{Key, _V, ETag}] = ets:lookup(smalt_store:table_for(Key), Key),
    ETag.

etag_for(Key) -> entry(Key).
