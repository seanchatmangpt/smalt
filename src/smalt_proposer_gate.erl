%% smalt_proposer_gate.erl — admission gate for proposals (operator
%% reference contract).
%%
%% evaluate_proposal/4: Op 1 is the SHACL-class structural validation,
%% Op 2 is the N3-class sieve; both must pass before the proposal is
%% admitted via store put_cas + journal append + merkle receipt. Any
%% refusal is an ANDON: {andon_refusal, Reason, -1.0} (reward penalty).
%%
%% aggregate_federated_shards/3: clip each shard's gradient vector to
%% MaxNorm (L2), average, and charge the privacy budget. Empty shard
%% set and exhausted budget are typed refusals.
-module(smalt_proposer_gate).
-export([evaluate_proposal/4, aggregate_federated_shards/3,
         clip_vector/2, average_vectors/1]).

-define(STREAM, proposer_gate).
-define(MAX_CAS_RETRY, 32).

%% Op1: ShaclFun(Proposal) -> ok | {error, Reason}
%% Op2: SieveFun(Proposal) -> ok | {error, Reason}
evaluate_proposal(Id, Proposal, ShaclFun, SieveFun)
        when is_function(ShaclFun, 1), is_function(SieveFun, 1) ->
    case gate_op(ShaclFun, Proposal) of
        {error, Reason} ->
            andon(Id, Proposal, {shacl_refused, Reason});
        ok ->
            case gate_op(SieveFun, Proposal) of
                {error, Reason} ->
                    andon(Id, Proposal, {sieve_refused, Reason});
                ok ->
                    admit(Id, Proposal)
            end
    end.

gate_op(Fun, Proposal) ->
    case Fun(Proposal) of
        ok -> ok;
        {error, _} = R -> R;
        true -> ok;
        false -> {error, op_failed}
    end.

admit(Id, Proposal) ->
    case smalt_store:start() of
        ok -> ok;
        {error, already_started} -> ok
    end,
    Key = {proposal, Id},
    SeqKey = {proposal_seq, Id},
    Seq = gate_seq(SeqKey),
    ok = smalt_store:put_cas(Key, {Seq, Proposal}, any),
    ETag = term_to_binary(smalt_arm_adapters:current_etag(Key)),
    {ok, _Seq} = smalt_arm_adapters:append_frame(
                   ?STREAM, Id, admit, term_to_binary(Proposal),
                   term_to_binary(#{seq => Seq})),
    {ok, Receipt} = smalt_arm_adapters:mint_single_receipt(
                      ?STREAM,
                      [term_to_binary(Id),
                       term_to_binary({Seq, Proposal})],
                      ETag),
    {admitted, ETag, Receipt}.

gate_seq(Key) ->
    case smalt_store:get(Key) of
        {ok, N} when is_integer(N) ->
            Next = N + 1,
            case smalt_store:put_cas(Key, Next,
                                     smalt_arm_adapters:current_etag(Key)) of
                ok -> Next;
                {error, etag_mismatch} -> gate_seq(Key)
            end;
        {error, not_found} ->
            case smalt_store:put_cas(Key, 0, any) of
                ok -> 0;
                {error, etag_mismatch} -> gate_seq(Key)
            end
    end.

andon(Id, Proposal, Reason) ->
    %% andon is durable: the refusal itself is journaled, reward -1.0
    {ok, _} = smalt_arm_adapters:append_frame(
                ?STREAM, Id, andon_refusal, term_to_binary(Reason),
                term_to_binary(#{proposal_digest =>
                                     crypto:hash(sha256,
                                                 term_to_binary(Proposal))})),
    {andon_refusal, Reason, -1.0}.

%% -- Federated aggregation ---------------------------------------------

%% Shards: non-empty list of numeric vectors (all same length).
%% Budget: remaining privacy budget (number); each aggregation charges 1.
aggregate_federated_shards([], _MaxNorm, _Budget) ->
    {error, empty_federated_shards};
aggregate_federated_shards(_Shards, _MaxNorm, Budget)
        when is_number(Budget), Budget =< 0 ->
    {error, privacy_budget_exhausted};
aggregate_federated_shards(Shards, MaxNorm, Budget)
        when is_number(MaxNorm), MaxNorm > 0 ->
    Clipped = [clip_vector(Shard, MaxNorm) || Shard <- Shards],
    Avg = average_vectors(Clipped),
    {ok, Avg, Budget - 1}.

%% L2 clip: if ||v|| > MaxNorm, scale to exactly MaxNorm.
clip_vector(Vec, MaxNorm) ->
    NormSq = lists:foldl(fun(X, Acc) -> Acc + X * X end, 0.0, Vec),
    Norm = math:sqrt(NormSq),
    case Norm > MaxNorm of
        true -> [X * MaxNorm / Norm || X <- Vec];
        false -> Vec
    end.

average_vectors([First | _] = Vecs) ->
    N = length(Vecs),
    Sums = lists:foldl(fun(V, Acc) ->
                           lists:zipwith(fun(X, S) -> X + S end, V, Acc)
                       end,
                       lists:duplicate(length(First), 0.0), Vecs),
    [S / N || S <- Sums].
