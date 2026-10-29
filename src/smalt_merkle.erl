%% smalt_merkle.erl — merkle root over binary leaves (universal ARM engine).
%% Leaves are hashed once (sha256), tree padded to a power of two with
%% the zero digest, paired up to a single 32-byte root. Deterministic:
%% same leaf set (order-significant) => same root, always.
-module(smalt_merkle).
-export([root/1, leaf/1]).

leaf(Bin) when is_binary(Bin) -> crypto:hash(sha256, Bin).

root([]) -> leaf(<<>>);
root(Leaves0) when is_list(Leaves0) ->
    Leaves = [case is_binary(L) andalso byte_size(L) =:= 32 of
                  true -> L;
                  false -> leaf(L)
              end || L <- Leaves0],
    root1(pad(Leaves)).

root1([Root]) -> Root;
root1(Level) ->
    root1(pair_up(Level, [])).

pair_up([], Acc) -> lists:reverse(Acc);
pair_up([A], Acc) -> lists:reverse([{h(A, A)} | Acc]);
pair_up([A, B | Rest], Acc) -> pair_up(Rest, [h(A, B) | Acc]).

h(A, B) -> crypto:hash(sha256, <<A/binary, B/binary>>).

pad(Leaves) ->
    N = length(Leaves),
    case power_of_two(N) of
        true -> Leaves;
        false ->
            Pad = [<<0:256>> || _ <- lists:seq(1, next_pow2(N) - N)],
            Leaves ++ Pad
    end.

power_of_two(1) -> true;
power_of_two(N) when N > 1 -> power_of_two(N, 2).
power_of_two(N, P) when P >= N -> P =:= N;
power_of_two(N, P) -> power_of_two(N, P * 2).

next_pow2(1) -> 1;
next_pow2(N) -> next_pow2(N, 1).
next_pow2(N, P) when P >= N -> P;
next_pow2(N, P) -> next_pow2(N, P * 2).
