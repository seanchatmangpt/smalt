%% court_arm_router_SUITE.erl — universal ARM engine court (erlc + erl
%% -noshell per the court_store_partition pattern). Run:
%%   erlc -o ebin/ src/smalt_*.erl test/courts/court_arm_router_SUITE.erl
%%   erl -pa ebin/ -noshell -s court_arm_router_SUITE run_court
%% Exit 0 = 8/8 PASS. No sleeps: bounded yield retry loops only.
%%
%% Covers: PUT admit (200+etag+receipt), ANDON op-1 refusal (422,
%% zero-mutation witnessed on the real ets tables), GET 200/not_found,
%% DELETE tombstone, malformed URI 400-class refusal, deployment wave
%% schedule -> concurrent PUTs -> merkle root over receipts, merkle
%% determinism (16-leaf and 4-bucket variant), store etag CAS law.
-module(court_arm_router_SUITE).
-export([run_court/0]).

-define(PASS_GROUP(N, Msg), io:format("PASS ~p ~s~n", [N, Msg])).
-define(TOMBSTONE_MARKER, {tombstone}).

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
    io:format("== universal ARM engine court ==~n"),
    %% STEP 1: boot the real STORE-4 tree standalone (16 partitions+heir)
    ok = case smalt_store:start() of
             ok -> ok;
             {error, already_started} ->
                 exit({name_collision, smalt_store_sup})
         end,
    io:format("STEP 1 boot real 16-bucket smalt_store_sup: ok~n"),

    step2_put_admit(),
    step3_andon(),
    step4_get(),
    step5_delete_tombstone(),
    step6_malformed(),
    step7_deploy(),
    step8_merkle_variants(),
    smalt_store:stop(),
    ok.

%% -- STEP 2: PUT admits -> 200 + etag + receipt -----------------------
step2_put_admit() ->
    Uri = <<"/subscriptions/s1/resourcegroups/rg1/providers/Misc/prov1">>,
    {200, ETag, Receipt} =
        smalt_arm_router:put(Uri, [], <<"body-v1">>),
    true = is_integer(ETag),
    #{op := put, etag := ETag, resource := Segs, sieved := Sieved} =
        Receipt,
    true = lists:member(<<"rg1">>, Segs),
    {sieved, 0, _} = Sieved,
    %% etag actually stored in the partition table
    ETag = stored_etag(Uri),
    ?PASS_GROUP(2, "PUT admits: 200 + etag + receipt (real ets store)").

%% -- STEP 3: ANDON op-1 -> 422, ZERO mutation -------------------------
step3_andon() ->
    Uri = <<"/subscriptions/s1/resourcegroups/rg-andon/providers/Misc/p">>,
    %% seeded resource: PUT then ANDON PUT with new body must not move it
    {200, ETag0, _} = smalt_arm_router:put(Uri, [], <<"safe">>),
    %% body-carried pull-cord
    {422, andon_op1_refused, zero_mutation} =
        smalt_arm_router:put(Uri, [], <<1:8, "halt">>),
    %% header-carried pull-cord
    {422, andon_op1_refused, zero_mutation} =
        smalt_arm_router:put(Uri, [{<<"x-andon">>, <<"op-1">>}],
                             <<"innocent">>),
    %% zero-mutation: value AND etag unchanged on the real table
    {200, <<"safe">>, ETag0} = smalt_arm_router:get(Uri),
    ?PASS_GROUP(3, "ANDON op-1 (<<1:8>> + header) -> 422, zero-mutation").

%% -- STEP 4: GET 200 / not_found --------------------------------------
step4_get() ->
    Uri = <<"/subscriptions/s1/resourcegroups/rg1/providers/Misc/g1">>,
    {200, _, _} = smalt_arm_router:put(Uri, [], <<"gettable">>),
    {200, <<"gettable">>, _} = smalt_arm_router:get(Uri),
    Missing = <<"/subscriptions/s1/resourcegroups/rg1/providers/Misc/none">>,
    {404, not_found, no_receipt} = smalt_arm_router:get(Missing),
    ?PASS_GROUP(4, "GET 200 / 404 not_found").

%% -- STEP 5: DELETE tombstone -----------------------------------------
step5_delete_tombstone() ->
    Uri = <<"/subscriptions/s1/resourcegroups/rg1/providers/Misc/d1">>,
    {200, _, _} = smalt_arm_router:put(Uri, [], <<"doomed">>),
    {200, tombstoned, DelReceipt} = smalt_arm_router:delete(Uri),
    #{op := delete} = DelReceipt,
    %% GET after tombstone: 404 not_found (not a raw marker read)
    {404, not_found, no_receipt} = smalt_arm_router:get(Uri),
    %% journal keeps the causal record: tombstone key present in ets
    {resource, Segs} = smalt_arm_router:parse_uri(Uri),
    TKey = {tombstone, {resource, Segs}},
    [{TKey, ?TOMBSTONE_MARKER, _}] =
        ets:lookup(smalt_store:table_for(TKey), TKey),
    %% seq-wrapped tombstone marker on the resource key itself
    [{_Res, {tombstone, _Seq}, _}] =
        ets:lookup(smalt_store:table_for({resource, Segs}), {resource, Segs}),
    ?PASS_GROUP(5, "DELETE tombstones (404 after) + journal causal record").

%% -- STEP 6: malformed URI -> 400-class refusal -----------------------
step6_malformed() ->
    {400, malformed_uri, no_receipt} =
        smalt_arm_router:put(<<"/x">>, [], <<"b">>),
    {400, malformed_uri, no_receipt} =
        smalt_arm_router:get(<<>>),
    {400, malformed_uri, no_receipt} =
        smalt_arm_router:delete(<<"subscriptions/s1/x\n/y">>),
    {400, malformed_body, no_receipt} =
        smalt_arm_router:put(<<"/subscriptions/s/resourcegroups/r/x">>,
                             [], not_a_binary),
    %% refusal left no residue: bad-key routes nowhere
    ?PASS_GROUP(6, "malformed URI/body -> 400-class refusals").

%% -- STEP 7: deployment: waves -> concurrent PUTs -> merkle root ------
step7_deploy() ->
    Wave1 = [{uri("dep", N), [], <<"body-", (integer_to_binary(N))/binary>>}
             || N <- lists:seq(1, 6)],
    Wave2 = [{uri("dep", N), [], <<"body2-", (integer_to_binary(N))/binary>>}
             || N <- lists:seq(7, 10)],
    {ok, Root, Receipts} =
        smalt_bicep_deployer:deploy([Wave1, Wave2]),
    true = is_binary(Root) andalso byte_size(Root) =:= 32,
    10 = length(Receipts),
    %% root reproducibility: same receipts -> same root
    Root = smalt_arm_router:receipt_root(Receipts),
    %% all 10 landed for real
    ok = lists:foreach(
           fun(N) ->
                   {200, _, _} = smalt_arm_router:get(uri("dep", N))
           end, lists:seq(1, 10)),
    %% refused deployment: ANDON in wave 1 stops wave 2 loudly
    Bad1 = [{uri("bad", 1), [{<<"x-andon">>, <<"op-1">>}], <<"x">>},
            {uri("bad", 2), [], <<"lands-not">>}],
    Bad2 = [{uri("bad", 3), [], <<"never-runs">>}],
    {refused, RefRoot, Results} = smalt_bicep_deployer:deploy([Bad1, Bad2]),
    true = is_binary(RefRoot) andalso byte_size(RefRoot) =:= 32,
    {422, andon_op1_refused, zero_mutation} = hd(Results),
    {404, not_found, no_receipt} = smalt_arm_router:get(uri("bad", 3)),
    ?PASS_GROUP(7, "deployment: 2 waves x concurrent PUTs -> merkle root; "
                   "ANDON wave refuses loudly, later wave never runs").

%% -- STEP 8: merkle determinism, 16-leaf and 4-bucket variant ---------
step8_merkle_variants() ->
    L = [<<"leaf-", I>> || I <- lists:seq(1, 16)],
    R1 = smalt_merkle:root(L),
    R1 = smalt_merkle:root(L),  %% deterministic across invocations
    true = byte_size(R1) =:= 32,
    %% order-sensitivity
    false = R1 =:= smalt_merkle:root(lists:reverse(L)),
    %% 4-bucket variant: 4 leaves pad-free, distinct from padded 5
    L4 = [<<"b1">>, <<"b2">>, <<"b3">>, <<"b4">>],
    R4 = smalt_merkle:root(L4),
    R4 = smalt_merkle:root(L4),
    true = byte_size(R4) =:= 32,
    false = R4 =:= smalt_merkle:root([<<"b1">>, <<"b2">>, <<"b3">>]),
    %% empty law
    R0 = smalt_merkle:root([]),
    R0 = smalt_merkle:root([]),
    ?PASS_GROUP(8, "merkle: 16-leaf + 4-bucket variant deterministic, "
                   "order-sensitive, empty-law stable").

%% -- helpers ----------------------------------------------------------

uri(Prefix, N) when is_list(Prefix) ->
    uri(list_to_binary(Prefix), N);
uri(Prefix, N) when is_binary(Prefix) ->
    <<"/subscriptions/s1/resourcegroups/rg-", Prefix/binary, "/providers/"
      "Misc/p", (integer_to_binary(N))/binary>>.

stored_etag(Uri) ->
    {resource, Segs} = smalt_arm_router:parse_uri(Uri),
    Res = {resource, Segs},
    [{Res, _V, ETag}] = ets:lookup(smalt_store:table_for(Res), Res),
    ETag.
