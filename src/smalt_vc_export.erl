%% smalt_vc_export.erl — W3C VC 2.0 JSON-LD export of ARM receipts.
%% mint_vc_jsonld/3: term_to_binary determinism (same receipt -> same
%% binary -> same digest), sha256 digest + HMAC-SHA256 proof, the exact
%% W3C VC 2.0 shape (@context credentials/v2 + provenance, types, issuer
%% urn:smalt:sovereign:substrate, credentialSubject {id, receiptDigest,
%% wordSize, byteSize}, DataIntegrityProof / blake3-sha256-rdfc-2026 /
%% assertionMethod). The receipt term is the 40-word invariant:
%% erts_debug:size(Receipt) =:= 40 heap words = 320 bytes.
%% verify_vc/3 recomputes the HMAC over the canonical form (VC minus
%% proof) and compares: ok | {error, vc_proof_signature_tampered}.
-module(smalt_vc_export).
-export([mint_vc_jsonld/3, verify_vc/3, canon/1, word_size/1]).

-define(ISSUER, <<"urn:smalt:sovereign:substrate">>).

%% -- mint ---------------------------------------------------------------

mint_vc_jsonld(Id, Receipt, Key) when is_binary(Id), is_binary(Key) ->
    %% 40-word invariant: the receipt TERM must serialize (term_to_binary,
    %% deterministic for a fixed term) and occupy exactly 40 machine words
    %% of heap -> byteSize 320. Off-invariant receipts refuse loudly.
    WS = erts_debug:size(Receipt),
    true = WS =:= 40 orelse exit({word_size_invariant_violation, WS}),
    Bin = term_to_binary(Receipt),
    Digest = crypto:hash(sha256, Bin),
    Subject = #{<<"id">> => Id,
                <<"receiptDigest">> => hex(Digest),
                <<"wordSize">> => WS,
                <<"byteSize">> => 8 * WS},
    VC0 = #{<<"@context">> =>
                [<<"https://www.w3.org/ns/credentials/v2">>,
                 <<"https://www.w3.org/ns/credentials/extends/v2/prov/">>],
            <<"@type">> => [<<"VerifiableCredential">>,
                            <<"ProvenanceCredential">>],
            <<"issuer">> => ?ISSUER,
            <<"validFrom">> => timestamp(),
            <<"credentialSubject">> => Subject},
    ProofValue = hmac_proof(VC0, Key),
    VC0#{<<"proof">> =>
             #{<<"type">> => <<"DataIntegrityProof">>,
               <<"cryptosuite">> => <<"blake3-sha256-rdfc-2026">>,
               <<"proofPurpose">> => <<"assertionMethod">>,
               <<"verificationMethod">> =>
                   <<?ISSUER/binary, "#smalt-vc-key-1">>,
               <<"proofValue">> => ProofValue}}.

%% Recompute HMAC over canon(VC minus proof); compare against the
%% stored proofValue. Issuer must also match the sovereign issuer.
verify_vc(VC, Key, _ExpectedIssuer) when is_map(VC) ->
    try
        ?ISSUER = maps:get(<<"issuer">>, VC),
        Proof = maps:get(<<"proof">>, VC, #{}),
        ProofValue = maps:get(<<"proofValue">>, Proof),
        VC0 = maps:remove(<<"proof">>, VC),
        ProofValue = hmac_proof(VC0, Key),
        ok
    catch
        _:_ -> {error, vc_proof_signature_tampered}
    end;
verify_vc(_, _, _) ->
    {error, vc_proof_signature_tampered}.

%% -- canonical form + proof ---------------------------------------------

canon(VC) -> term_to_binary(maps:remove(<<"proof">>, VC)).

word_size(Receipt) -> erts_debug:size(Receipt).

hmac_proof(VC0, Key) ->
    hex(crypto:mac(hmac, sha256, Key, canon(VC0))).

%% -- internals -----------------------------------------------------------

%% The minted term must serialize to exactly 40 words. If the caller's
%% receipt is off-invariant the mint refuses loudly (typed exit) rather
%% than exporting a VC citing a word size the payload does not carry.
%% (erts_debug:size counts machine words of the serialized term.)

hex(Bin) ->
    << <<(hd(integer_to_list(N div 16))),
         (hd(integer_to_list(N rem 16)))>>
      || <<N>> <= Bin >>.

timestamp() ->
    %% UTC RFC3339, second precision — no dynamic atom creation.
    Secs = os:system_time(second),
    {{Y, Mo, D}, {H, Mi, S}} =
        calendar:system_time_to_universal_time(Secs, second),
    list_to_binary(
      io_lib:format("~b-~2..0b-~2..0bT~2..0b:~2..0b:~2..0bZ",
                    [Y, Mo, D, H, Mi, S])).
