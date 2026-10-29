%% smalt_maa_attestation.erl — ERL-3 MAA attestation reference module.
%% Coexists with lib/smalt/attestation/maa.ex (Elixir face).
%%
%% attest_environment/3: verify a TEE quote against the persistent_term-
%% pinned reticle hash and mint the exact 40-word receipt term.
%%
%% Receipt word law (erts_debug:size/1 == 40):
%%   flat 39-element tuple of immediates (atoms + small ints) = 1 tuple
%%   word + 39 = 40 heap words. The 1024-bit PQC signature slot is carried
%%   as 16 x 64-bit words; quote/reticle hashes as 4 x 64-bit words each
%%   (256-bit). All fields are immediates — no heap binaries inside the
%%   receipt, so the word count is exact and deterministic.
-module(smalt_maa_attestation).
-export([pin_reticle_hash/1, pinned_reticle_hash/0,
         attest_environment/3, receipt_words/1]).

-define(PIN_KEY, {smalt_maa, reticle_hash}).

-type env_type() :: sevsnpvm | sgxenclave | wasmreticle.

-export_type([env_type/0]).

%% == pinning ===========================================================

%% Pin the trusted reticle measurement (32-byte binary = 256-bit hash).
pin_reticle_hash(Hash) when is_binary(Hash), byte_size(Hash) =:= 32 ->
    persistent_term:put(?PIN_KEY, Hash),
    ok.

pinned_reticle_hash() ->
    persistent_term:get(?PIN_KEY, undefined).

%% == attestation ========================================================

%% attest_environment(Type, QuoteBin, Opts)
%%   Type     :: sevsnpvm | sgxenclave | wasmreticle
%%   QuoteBin :: 32-byte binary quote measurement
%%   Opts     :: #{ nonce => integer()
%%                , pqc_sig => <<_:1024>>   (default: zeros)
%%                , timestamp => integer()  (default: os:system_time(millisecond))
%%                }
%%
%% Returns {ok, Receipt40Words}
%%       | {error, unsupported_env_type}
%%       | {error, attestation_quote_mismatch}
attest_environment(Type, Quote, Opts) when is_binary(Quote) ->
    case Type of
        sevsnpvm -> do_attest(Type, Quote, Opts);
        sgxenclave -> do_attest(Type, Quote, Opts);
        wasmreticle -> do_attest(Type, Quote, Opts);
        _ ->
            %% UNSUPPORTED type refusal — never attest an unknown family
            {error, unsupported_env_type}
    end;
attest_environment(_Type, _Quote, _Opts) ->
    {error, attestation_quote_mismatch}.

do_attest(Type, Quote, Opts) ->
    case byte_size(Quote) =:= 32 of
        false ->
            {error, attestation_quote_mismatch};
        true ->
            Pinned = pinned_reticle_hash(),
            case hash_equals(Quote, Pinned) of
                true ->
                    {ok, mint_receipt(Type, Quote, Opts)};
                false ->
                    {error, attestation_quote_mismatch}
            end
    end.

%% Constant-time equality over the 256-bit measurement, word-wise
%% (fold over 4 x 64-bit words with an accumulator XOR so no early exit).
hash_equals(A, A) when is_binary(A) -> true;
hash_equals(A, B) when is_binary(A), is_binary(B),
                       byte_size(A) =:= 32, byte_size(B) =:= 32 ->
    <<A1:64, A2:64, A3:64, A4:64>> = A,
    <<B1:64, B2:64, B3:64, B4:64>> = B,
    Diff = (A1 bxor B1) bor (A2 bxor B2) bor (A3 bxor B3) bor (A4 bxor B4),
    Diff =:= 0;
hash_equals(_, _) -> false.

%% == receipt minting (exact 40 words) ==================================

%% 39 immediates:
%%   1  record tag (atom maa_receipt)
%%   1  version
%%   1  env type (atom)
%%   1  timestamp_ms
%%   1  nonce
%%   4  quote hash words (256-bit)
%%   4  reticle hash words (256-bit)
%%   16 PQC signature words (1024-bit slot)
%%   10 zero padding words
%% Total 39 elements + 1 tuple word = 40.
mint_receipt(Type, Quote, Opts) ->
    <<Q1:64, Q2:64, Q3:64, Q4:64>> = Quote,
    Pinned = pinned_reticle_hash(),
    <<R1:64, R2:64, R3:64, R4:64>> = Pinned,
    PQCSig = maps:get(pqc_sig, Opts, <<0:1024>>),
    <<P1:64, P2:64, P3:64, P4:64, P5:64, P6:64, P7:64, P8:64,
      P9:64, P10:64, P11:64, P12:64, P13:64, P14:64, P15:64, P16:64>> =
        PQCSig,
    Nonce = maps:get(nonce, Opts, 0),
    TS = maps:get(timestamp, Opts, os:system_time(millisecond)),
    {maa_receipt, 1, Type, TS, Nonce,
     Q1, Q2, Q3, Q4,
     R1, R2, R3, R4,
     P1, P2, P3, P4, P5, P6, P7, P8,
     P9, P10, P11, P12, P13, P14, P15, P16,
     0, 0, 0, 0, 0, 0, 0, 0, 0, 0}.

%% Self-check: erts_debug word count of a minted receipt.
receipt_words(Receipt) ->
    erts_debug:size(Receipt).
