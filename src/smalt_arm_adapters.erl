%% smalt_arm_adapters.erl — thin adapters the ERL reference modules call
%% (ERL-1 arm_router names, shimmed onto STORE-4 until that lane lands):
%%   append_frame/5          ~ smalt_journal_sink:append_frame/5
%%   mint_single_receipt/3   ~ smalt_merkle:mint_single_receipt/3
%%   current_etag/1          — etag readback for receipt minting
%% Journal frames are append-only: each is stored under a unique
%% monotone {journal, Stream, Seq} key (unique_integer monotone), never
%% overwriting — the store keeps the causal record. mint_single_receipt
%% folds a frame set + etag into one deterministic sha256 merkle root.
-module(smalt_arm_adapters).
-export([append_frame/5, mint_single_receipt/3, current_etag/1,
         read_frames/2]).

append_frame(Stream, Key, Op, FrameBin, MetaBin)
        when is_binary(FrameBin), is_binary(MetaBin) ->
    Seq = erlang:unique_integer([monotonic, positive]),
    ok = smalt_store:put_cas({journal, Stream, Seq},
                             {Key, Op, FrameBin, MetaBin}, any),
    {ok, Seq}.

%% Receipt = merkle root over [stream tag, key, op, frame, meta, etag]
%% leaves — same frame set always yields the identical receipt.
mint_single_receipt(Stream, FrameBins, ETag) ->
    Leaves = [crypto:hash(sha256, term_to_binary({Stream, F, ETag}))
              || F <- FrameBins],
    {ok, smalt_merkle:root(Leaves)}.

%% Frames appended for one logical key (court/debug reader): journal
%% keys hash across all 16 partition tables, so scan every table and
%% merge in monotone Seq order (chronological).
read_frames(Stream, Key) ->
    Rows = lists:append(
             [ets:tab2list(smalt_store_partition:partition_name(P))
              || P <- lists:seq(0, 15)]),
    Matches = [{{journal, S, Seq}, K, Op, FrameBin, MetaBin}
               || {{journal, S, Seq}, K, Op, FrameBin, MetaBin} <- Rows,
                  S =:= Stream, K =:= Key],
    [{Op, FrameBin, MetaBin}
     || {_, _Key, Op, FrameBin, MetaBin} <- lists:sort(Matches)].


current_etag(Key) ->
    [{Key, _V, ETag}] = ets:lookup(smalt_store:table_for(Key), Key),
    ETag.
