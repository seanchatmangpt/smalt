%% smalt_bicep_deployer.erl — universal ARM engine reference deployer.
%% Wave schedule -> CONCURRENT PUTs per wave (one spawned process per
%% resource, results collected deterministically by request order) ->
%% merkle root over the deployment receipts. A wave with any refusal
%% outcome fails the deployment loudly; later waves never run.
-module(smalt_bicep_deployer).
-export([deploy/1, deploy_wave/1]).

%% deploy(Waves) :: [[{Uri, Headers, Body}]]
%%   -> {ok, Root, Receipts} | {refused, Root, Results}
deploy(Waves) ->
    case deploy_waves(Waves, []) of
        {refused, Results} ->
            Root = smalt_arm_router:receipt_root(
                     [R || R <- Results, is_map(R)]),
            {refused, Root, Results};
        Receipts ->
            Root = smalt_arm_router:receipt_root(Receipts),
            {ok, Root, Receipts}
    end.

deploy_waves([], Acc) -> lists:reverse(Acc);
deploy_waves([Wave | Rest], Acc) ->
    {Status, Results} = deploy_wave(Wave),
    case Status of
        ok ->
            Receipts = [R || {200, _, R} <- Results],
            deploy_waves(Rest, lists:reverse(Receipts, Acc));
        refused ->
            {refused, lists:reverse(Acc) ++ Results}
    end.

%% One wave: all PUTs in concurrent processes; collect replies by caller
%% ordering (deterministic regardless of completion order).
deploy_wave(Resources) ->
    Parent = self(),
    Refs = [begin
                Ref = make_ref(),
                erlang:spawn(fun() ->
                    Result = smalt_arm_router:put(Uri, Headers, Body),
                    Parent ! {wave_result, Ref, Result}
                end),
                Ref
            end || {Uri, Headers, Body} <- Resources],
    Results = [receive
                   {wave_result, Ref, Result} -> Result
               after 15000 ->
                       exit({wave_timeout, Ref})
               end || Ref <- Refs],
    Refusals = [R || R = {Code, _, _} <- Results, Code =/= 200],
    case Refusals of
        [] -> {ok, Results};
        _ -> {refused, Results}
    end.
