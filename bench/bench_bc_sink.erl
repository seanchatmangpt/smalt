%% bench_bc_sink.erl — BC lane's real sink for the partition-worker deliver
%% seam (Chicago: real state — a public named ETS table, not a mock).
%% deliver(ring_id, seq, parsed) -> :ok, one ETS insert per delivered frame.
-module(bench_bc_sink).

-export([deliver/3, count/0]).

deliver(RingId, Seq, Parsed) ->
    true = ets:insert(bc_sink_table, {{RingId, Seq}, Parsed}),
    ok.

count() -> ets:info(bc_sink_table, size).
