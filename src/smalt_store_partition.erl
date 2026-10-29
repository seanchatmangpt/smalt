%% smalt_store_partition.erl — STORE-4 single partition worker.
%% Owns one named PUBLIC ets table (smalt_store_p<N>) with the dedicated
%% heir process as its heir. Serialization point for CAS writes on that
%% partition. On worker death: table -> heir (zero loss), supervisor
%% restarts the worker, worker ADOPTS the heir-held table by name.
-module(smalt_store_partition).
-behaviour(gen_server).
-export([start_link/1, put_cas/4, delete/2, partition_name/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-define(HEIR, smalt_store_heir).

start_link(N) ->
    gen_server:start_link({local, partition_name(N)},
                          ?MODULE, N, []).

partition_name(N) ->
    %% list_to_atom is compile-time-bounded: exactly 16 fixed names derived
    %% from N in 0..15 at sup boot, never wire input — safe by construction.
    list_to_atom("smalt_store_p" ++ integer_to_list(N)).

%% ------------------------------------------------------------------
%% API (routed to the partition worker by smalt_store facade)
%% ------------------------------------------------------------------

put_cas(N, Key, Value, ETagExpect) ->
    gen_server:call(partition_name(N), {put_cas, Key, Value, ETagExpect}).

delete(N, Key) ->
    gen_server:call(partition_name(N), {delete, Key}).

%% ------------------------------------------------------------------
%% gen_server
%% ------------------------------------------------------------------

init(N) ->
    Tab = partition_name(N),
    case ets:whereis(Tab) of
        undefined ->
            %% Fresh boot: create with the dedicated heir so a crash
            %% hands the table (and all contents) to the heir process.
            Heir =
                case whereis(?HEIR) of
                    undefined -> whereis(init);
                    P -> P
                end,
            ets:new(Tab, [named_table, public, set,
                          {heir, Heir, []}]),
            {ok, N};
        _ ->
            %% Adoption: table alive under heir ownership after a crash.
            %% Keep it and every key in it — ownership RESTS WITH the heir
            %% (public table, all accesses are public ops; no reclaim).
            {ok, N}
    end.

handle_call({put_cas, Key, Value, ETagExpect}, _From, N) ->
    Tab = partition_name(N),
    Reply =
        case ets:lookup(Tab, Key) of
            [] ->
                case ETagExpect of
                    any -> ets:insert(Tab, {Key, Value, etag_for(Key)}), ok;
                    undefined -> ets:insert(Tab, {Key, Value, etag_for(Key)}), ok;
                    _ -> {error, not_found}
                end;
            [{Key, _Val, ETag}] ->
                case ETagExpect of
                    ETag -> ets:insert(Tab, {Key, Value, etag_for(Key)}), ok;
                    any -> {error, etag_mismatch};
                    undefined -> {error, etag_mismatch};
                    _ -> {error, etag_mismatch}
                end
        end,
    {reply, Reply, N};
handle_call({delete, Key}, _From, N) ->
    Tab = partition_name(N),
    Reply =
        case ets:lookup(Tab, Key) of
            [] -> ok;
            _ -> ets:delete(Tab, Key), ok
        end,
    {reply, Reply, N};
handle_call(_Req, _From, N) ->
    {reply, {error, unknown_call}, N}.

handle_cast(_Req, N) -> {noreply, N}.
handle_info(_Info, N) -> {noreply, N}.
terminate(_R, _N) -> ok.
code_change(_Old, N, _Extra) -> {ok, N}.

%% phash2-derived etags: deterministic, no counter process needed;
%% a value change yields a different etag.
etag_for(Key) ->
    erlang:phash2({key_tag, Key, erlang:unique_integer()}).
