%% smalt_store_heir.erl — STORE-4 dedicated heir process.
%% Stands by as the ets heir for all 16 partition tables: on partition
%% worker death each table is handed to this process (never destroyed),
%% and the supervisor-restarted worker adopts it by name.
-module(smalt_store_heir).
-export([start_link/0, get_heir_pid/0]).

start_link() ->
    {ok, spawn_link(fun heir_loop/0)}.

%% Idempotent heir acquisition for modules that need the heir pid at
%% ets-create time (e.g. smalt_wormhole). Plain spawn (NOT link): the
%% caller's lifetime must not gate the heir's. Register race-safe.
get_heir_pid() ->
    case whereis(?MODULE) of
        undefined ->
            Pid = erlang:spawn(fun heir_loop/0),
            case catch erlang:register(?MODULE, Pid) of
                true -> Pid;
                _ -> whereis(?MODULE)
            end;
        P ->
            P
    end.

heir_loop() ->
    %% Heir gift messages ({'ETS-TRANSFER', ...}) accumulate unread in the
    %% mailbox; the transfer itself is the mechanism, the unread message
    %% is its witness (same law as the TTV-5 :init heir note).
    receive
        _ -> heir_loop()
    end.
