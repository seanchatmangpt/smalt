%% smalt_store_sup.erl — STORE-4 supervisor.
%% Boot order: heir process FIRST, then 16 permanent partition workers,
%% one_for_one 5/10. A partition crash costs that partition only; the
%% heir carries its table to the restarted worker.
-module(smalt_store_sup).
-behaviour(supervisor).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Heir = #{id => smalt_store_heir,
             start => {smalt_store_heir, start_link, []},
             restart => permanent, shutdown => 5000, type => worker},
    Partitions =
        [#{id => {smalt_store_partition, N},
           start => {smalt_store_partition, start_link, [N]},
           restart => permanent, shutdown => 5000, type => worker}
         || N <- lists:seq(0, 15)],
    {ok, {{one_for_one, 5, 10}, [Heir | Partitions]}}.
