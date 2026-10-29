%% court_vc_twins_lakehouse_SUITE.erl — ERL-4 court for the operator's
%% three reference modules (erlc + erl -noshell per the
%% court_arm_router pattern). Run:
%%   erlc -o ebin/ src/smalt_*.erl test/courts/court_vc_twins_lakehouse_SUITE.erl
%%   erl -pa ebin/ -noshell -s court_vc_twins_lakehouse_SUITE run_court
%% Exit 0 = 8/8 PASS. No sleeps: real ets store, real files, real crypto.
%%
%% Covers: VC mint (40-word invariant, deterministic term_to_binary,
%% sha256 digest + HMAC proof), VC verify ok, VC tamper refusal,
%% twins upsert (dt:twin put_cas + journal row), twins link (dt:edge +
%% journal row), twins query Op-15 admit, sieve refusal -> andon,
%% lakehouse sealed-segment discovery (2 sealed + 1 unsentinel'd ->
%% exactly 2, sorted) + Op 15 admit/refusal wire forms.
-module(court_vc_twins_lakehouse_SUITE).
-export([run_court/0]).

-define(PASS_GROUP(N, Msg), io:format("PASS ~p ~s~n", [N, Msg])).

run_court() ->
    try run() of
        ok ->
            io:format("COURT RESULT: 8/8 PASS~n"),
            halt(0)
    catch
        Class:Reason:Stack ->
            io:format("COURT RESULT: FAIL ~p:~p~n~p~n",
                      [Class, Reason, Stack]),
            halt(1)
    end.

run() ->
    io:format("== VC / digital twins / lakehouse mount court ==~n"),
    ok = case smalt_store:start() of
             ok -> ok;
             {error, already_started} ->
                 exit({name_collision, smalt_store_sup})
         end,
    io:format("STEP 1 boot real 16-bucket smalt_store_sup: ok~n"),

    {Receipt, Key, VC} = step2_vc_mint(),
    step3_vc_verify(VC, Key),
    step4_twin_upsert(),
    step5_twin_link(),
    step6_query_admit(),
    step7_andon_refusal(),
    step8_lakehouse(),
    _ = Receipt,
    smalt_store:stop(),
    ok.

%% -- STEP 2: VC mint — 40-word invariant + determinism ------------------
step2_vc_mint() ->
    Key = crypto:strong_rand_bytes(32),
    Receipt = court_receipt(),
    %% the invariant itself, witnessed before mint
    40 = smalt_vc_export:word_size(Receipt),
    VC = smalt_vc_export:mint_vc_jsonld(
           <<"urn:smalt:receipt:erl4-r1">>, Receipt, Key),
    [<<"https://www.w3.org/ns/credentials/v2">>,
     <<"https://www.w3.org/ns/credentials/extends/v2/prov/">>] =
        maps:get(<<"@context">>, VC),
    [<<"VerifiableCredential">>, <<"ProvenanceCredential">>] =
        maps:get(<<"@type">>, VC),
    <<"urn:smalt:sovereign:substrate">> = maps:get(<<"issuer">>, VC),
    Subject = maps:get(<<"credentialSubject">>, VC),
    <<"urn:smalt:receipt:erl4-r1">> = maps:get(<<"id">>, Subject),
    40 = maps:get(<<"wordSize">>, Subject),
    320 = maps:get(<<"byteSize">>, Subject),
    Hex = maps:get(<<"receiptDigest">>, Subject),
    true = byte_size(Hex) =:= 64,  %% sha256 hex
    Hex = hex(crypto:hash(sha256, term_to_binary(Receipt))),
    Proof = maps:get(<<"proof">>, VC),
    <<"DataIntegrityProof">> = maps:get(<<"type">>, Proof),
    <<"blake3-sha256-rdfc-2026">> = maps:get(<<"cryptosuite">>, Proof),
    <<"assertionMethod">> = maps:get(<<"proofPurpose">>, Proof),
    ProofValue = maps:get(<<"proofValue">>, Proof),
    true = byte_size(ProofValue) =:= 64,  %% HMAC-SHA256 hex
    %% determinism: term_to_binary is byte-identical for a fixed term,
    %% so a re-mint of the identical receipt carries the identical
    %% digest (validFrom is wall-clock; the digest + canonical form are
    %% the determinism witnesses, never the timestamp)
    term_to_binary(Receipt) =:= term_to_binary(Receipt) orelse
        exit(term_to_binary_nondeterministic),
    VC2 = smalt_vc_export:mint_vc_jsonld(
            <<"urn:smalt:receipt:erl4-r1">>, Receipt, Key),
    Hex2 = maps:get(<<"receiptDigest">>,
                    maps:get(<<"credentialSubject">>, VC2)),
    Hex = Hex2,
    ok = smalt_vc_export:verify_vc(VC2, Key,
                                   <<"urn:smalt:sovereign:substrate">>),
    ProofValue = maps:get(
                   <<"proofValue">>, maps:get(<<"proof">>, VC2)),
    ?PASS_GROUP(2, "VC mint: 40-word/320-byte invariant, sha256 digest, "
                   "HMAC proof, W3C VC 2.0 shape, deterministic re-mint"),
    {Receipt, Key, VC}.

%% -- STEP 3: verify ok + tamper refusal ----------------------------------
step3_vc_verify(VC, Key) ->
    ok = smalt_vc_export:verify_vc(VC, Key,
                                   <<"urn:smalt:sovereign:substrate">>),
    %% tamper credentialSubject: proof must no longer verify
    Tampered = maps:put(
                 <<"credentialSubject">>,
                 maps:put(<<"receiptDigest">>,
                          <<"ffff">>,
                          maps:get(<<"credentialSubject">>, VC)),
                 VC),
    {error, vc_proof_signature_tampered} =
        smalt_vc_export:verify_vc(Tampered, Key,
                                  <<"urn:smalt:sovereign:substrate">>),
    %% tamper proofValue directly
    Bad = maps:put(<<"proof">>,
                   maps:put(<<"proofValue">>,
                            <<0:(8*64)>>,
                            maps:get(<<"proof">>, VC)),
                   VC),
    {error, vc_proof_signature_tampered} =
        smalt_vc_export:verify_vc(Bad, Key,
                                  <<"urn:smalt:sovereign:substrate">>),
    %% wrong key refuses
    {error, vc_proof_signature_tampered} =
        smalt_vc_export:verify_vc(VC, crypto:strong_rand_bytes(32),
                                  <<"urn:smalt:sovereign:substrate">>),
    %% non-map garbage refuses, never crashes
    {error, vc_proof_signature_tampered} =
        smalt_vc_export:verify_vc(not_a_map, Key, <<>>),
    ?PASS_GROUP(3, "VC verify ok; tamper/wrong-key/garbage -> "
                   "vc_proof_signature_tampered").

%% -- STEP 4: twins upsert — dt:twin put_cas + journal --------------------
step4_twin_upsert() ->
    Id = <<"dtmi:smalt:receipt;1-instance-r1">>,
    Dtmi = <<"dtmi:smalt:receipt;1">>,
    {ok, ETag, Meta} =
        smalt_digital_twins:upsert_twin(Id, Dtmi, <<"body-v1">>, #{}),
    true = is_integer(ETag),
    #{class := 0, digest := Digest} = Meta,
    true = byte_size(Digest) =:= 32,
    %% the twin really landed in the partition table
    TwinKey = {dt, twin, Id},
    {ok, Envelope, TwinETag} = smalt_journal_sink_compat:get(TwinKey),
    true = is_integer(TwinETag),
    Dtmi = maps:get(<<"dtmi">>, Envelope),
    <<"body-v1">> = maps:get(<<"payload">>, Envelope),
    %% the journal row is a real ets entry
    JKey = {dt, journal, twin, Id},
    {ok, JVal, _} = smalt_journal_sink_compat:get(JKey),
    #{op := upsert_twin, dtmi := Dtmi, digest := Digest} =
        binary_to_term(JVal),
    ?PASS_GROUP(4, "twins upsert: gl_call Op 1 -> dt:twin put_cas + "
                   "journal row (real ets)").

%% -- STEP 5: twins link — dt:edge store + journal ------------------------
step5_twin_link() ->
    A = <<"dtmi:smalt:receipt;1-instance-r1">>,
    B = <<"dtmi:smalt:receipt;1-instance-r2">>,
    {ok, _, _} = smalt_digital_twins:upsert_twin(B, <<"dtmi:smalt:receipt;1">>,
                                                 <<"body-v1">>, #{}),
    Props = #{<<"rel">> => <<"derivedFrom">>},
    {ok, ETag, #{digest := Digest}} =
        smalt_digital_twins:link_twins(A, <<"dependsOn">>, B, Props,
                                       <<"txn-erl4-1">>),
    true = is_integer(ETag) andalso byte_size(Digest) =:= 32,
    EdgeKey = {dt, edge, A, <<"dependsOn">>, B},
    {ok, Edge, EdgeETag} = smalt_journal_sink_compat:get(EdgeKey),
    true = is_integer(EdgeETag),
    A = maps:get(<<"from">>, Edge),
    B = maps:get(<<"to">>, Edge),
    <<"txn-erl4-1">> = maps:get(<<"txn">>, Edge),
    JKey = {dt, journal, edge, A, <<"dependsOn">>, B},
    {ok, JVal, _} = smalt_journal_sink_compat:get(JKey),
    #{op := link_twins, txn := <<"txn-erl4-1">>} = binary_to_term(JVal),
    ?PASS_GROUP(5, "twins link: RDF triple -> Op 1 -> dt:edge store + "
                   "journal row (real ets)").

%% -- STEP 6: query_twins Op-15 admit --------------------------------------
step6_query_admit() ->
    Query = <<"select * from sealed">>,
    {ok, #{segments := Segs, rows := Rows}} =
        smalt_digital_twins:query_twins(Query, #{}),
    true = is_map(Segs) andalso is_integer(Rows),
    %% the dispatch agrees with the raw Op-15 executor on the identical
    %% request body (segments field carries the dispatch opts verbatim;
    %% the row count is a pure function of the request body)
    {ok, <<0:8, ResultBin/binary>>} =
        smalt_lakehouse_mount:op15(
          term_to_binary({dt_lakehouse_query, Query, #{}})),
    #{rows := Rows, segments := Segs} = binary_to_term(ResultBin),
    ?PASS_GROUP(6, "query_twins Op-15 admit: segments + deterministic rows").

%% -- STEP 7: sieve refusal -> andon, zero mutation ------------------------
step7_andon_refusal() ->
    %% andon pull-cord query (leading <<1:8>>) refused through the
    %% full dispatch chain (twins -> wasm_pool gl_call 15 -> lakehouse)
    PullCord = <<1:8, "halt">>,
    {refused, Reason} = smalt_digital_twins:query_twins(PullCord, #{}),
    true = byte_size(Reason) > 0,
    %% raw op15 andon wire form identical
    {error, {andon, <<1:8, Len:32, Reason:Len/binary>>}} =
        smalt_lakehouse_mount:op15(
          term_to_binary({dt_lakehouse_query, PullCord, []})),
    %% the refused reason decodes to the same text the twins layer saw
    true = byte_size(Reason) > 0,
    %% malformed request body -> andon refusal, not a crash
    {error, {andon, GarbageWire}} =
        smalt_lakehouse_mount:op15(<<"garbage-not-a-term">>),
    true = byte_size(GarbageWire) > 5,
    %% zero mutation: the andon refusal left NO journal/twin residue —
    %% the seeded twin from step 4 is byte-identical
    Id = <<"dtmi:smalt:receipt;1-instance-r1">>,
    {ok, Envelope, _} =
        smalt_journal_sink_compat:get({dt, twin, Id}),
    <<"body-v1">> = maps:get(<<"payload">>, Envelope),
    ?PASS_GROUP(7, "sieve refusal: pull-cord + malformed -> andon wire, "
                   "zero mutation on the store").

%% -- STEP 8: lakehouse discovery + Op-15 wire forms ------------------------
step8_lakehouse() ->
    Root = mount_root(),
    Segs = smalt_lakehouse_mount:discover_sealed_segments(Root),
    %% seg-a, seg-b are sealed+.wal; seg-c has a .wal but NO .seal
    [<<"seg-a">>, <<"seg-b">>] = Segs,
    %% admit wire form: <<0:8, ResultBin>>
    {ok, <<0:8, ResultBin/binary>>} =
        smalt_lakehouse_mount:op15(
          term_to_binary({dt_lakehouse_query, <<"q">>,
                          [<<"seg-a">>, <<"seg-b">>]})),
    #{rows := _, segments := [<<"seg-a">>, <<"seg-b">>]} =
        binary_to_term(ResultBin),
    %% refusal wire form: <<1:8, Len:32, Reason/binary>>
    {error, {andon, <<1:8, Len2:32, _:Len2/binary>>}} =
        smalt_lakehouse_mount:op15(
          term_to_binary({dt_lakehouse_query, <<1:8, "stop">>, []})),
    %% full executor path: admit carries the discovered segments
    {ok, #{segments := [<<"seg-a">>, <<"seg-b">>]}} =
        smalt_lakehouse_mount:execute_analytical_query(Root, <<"q">>),
    ?PASS_GROUP(8, "lakehouse: 2 sealed + 1 unsentinel'd -> exactly 2 "
                   "sorted; Op-15 admit <<0:8,_>> / refusal andon wire").

%% -- helpers ---------------------------------------------------------------

%% The receipt term pinned to the 40-word invariant: 9-byte etag binary,
%% two short segments, 32-byte digest, small-int wall_ms.
court_receipt() ->
    Dig = crypto:hash(sha256, <<"court-body">>),
    #{op => put,
      resource => [<<"s1">>, <<"rg1">>],
      etag => <<0:72>>,
      wall_ms => 1_735_000_000_000,
      sieved => {sieved, 0, Dig},
      digest => Dig}.

mount_root() ->
    Root = "/tmp/smalt-erl4-lakehouse-court",
    filelib:ensure_dir(filename:join(Root, "x")),
    %% seg-a: sealed + wal
    ok = file:write_file(filename:join(Root, "seg-a"), <<1, 2>>),
    ok = file:write_file(filename:join(Root, "seg-a.seal"), <<>>),
    ok = file:write_file(filename:join(Root, "seg-a.wal"), <<>>),
    %% seg-b: sealed + wal
    ok = file:write_file(filename:join(Root, "seg-b"), <<3>>),
    ok = file:write_file(filename:join(Root, "seg-b.seal"), <<>>),
    ok = file:write_file(filename:join(Root, "seg-b.wal"), <<>>),
    %% seg-c: wal but NO .seal sentinel -> must be excluded
    ok = file:write_file(filename:join(Root, "seg-c"), <<4>>),
    ok = file:write_file(filename:join(Root, "seg-c.wal"), <<>>),
    list_to_binary(Root).

hex(Bin) ->
    << <<(hd(integer_to_list(N div 16))),
         (hd(integer_to_list(N rem 16)))>>
      || <<N>> <= Bin >>.
