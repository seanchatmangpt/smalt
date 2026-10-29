%% FONDRUNNER — plan structure for the HTN→FOND→POWL→OCEL pipeline.
%%
%% A plan is #{steps => [step()]}; a step is
%%   #{id => id(), needs => [id()], provides => [id()], action => term()}.
%% FOND = Full Observability + Nondeterminism: a step may contingently fail
%% with a CAS-style 412 (precondition failed), which forces a loopback replan.
%% The spine must be acyclic — assert_acyclic/1 crashes the caller on a cycle
%% (crash-only fatal divergence, no recovery path).
-module(smalt_fond_plan).

-export([assert_acyclic/1, linear_plan/1, steps/1, next_ready/2]).

-type id() :: atom() | binary().
-type step() :: #{id := id(), needs => [id()], provides => [id()], action => term()}.
-type plan() :: #{steps := [step()]}.

-export_type([id/0, step/0, plan/0]).

-spec steps(plan()) -> [step()].
steps(#{steps := S}) -> S.

%% @doc Linear HTN decomposition: one step per task, chained provides/needs.
-spec linear_plan([id()]) -> plan().
linear_plan(Tasks) ->
    Steps =
        lists:zipwith(
            fun(Task, Idx) ->
                #{id => Task,
                  needs => case Idx of 0 -> []; _ -> [lists:nth(Idx, Tasks)] end,
                  provides => [Task],
                  action => {execute, Task}}
            end,
            Tasks,
            lists:seq(0, length(Tasks) - 1)
        ),
    #{steps => Steps}.

%% @doc Kahn's algorithm over the needs-edges. Crash-only on a cycle:
%% erlang:error({cyclic_plan, IdsRemaining}).
-spec assert_acyclic(plan()) -> ok.
assert_acyclic(#{steps := Steps} = _Plan) ->
    %% BK-DUPID (bkfondv-f1a-verify): the executor's done-set is id-keyed and
    %% collapses duplicate step ids, so the fixpoint count must be over the
    %% DEDUPED id set — counting duplicates made dup-id plans unreachable
    %% (maps:size(Done) =:= length(Ids) never held) and false-refused them as
    %% cyclic_plan while the executor ran them.
    Ids = lists:usort([ID || #{id := ID} <- Steps]),
    NeedsMap = maps:from_list([{ID, maps:get(needs, S, [])} || #{id := ID} = S <- Steps]),
    %% F1-A (bkfondskep): next_ready/2 accepts ANY done provider, so the
    %% Providing map is term -> [id()] — a last-wins single-provider map
    %% falsely refused dup-provider plans as cyclic_plan.
    Providing =
        lists:foldl(
            fun(#{id := ID} = S, Acc) ->
                lists:foldl(
                    fun(Prov, A) ->
                        maps:update_with(Prov, fun(L) -> [ID | L] end, [ID], A)
                    end,
                    Acc, maps:get(provides, S, []))
            end,
            #{}, Steps),
    %% EXPL10-R F1: an unprovided need is NOT externally satisfiable — the
    %% executor (next_ready/2) can only ever satisfy needs from the done-set
    %% or from a DONE step's provides. A need no step provides can never be
    %% satisfied at execution time, so the plan is refused typed here (the
    %% old External/1 clause admitted it and the runner silently skipped the
    %% step while still sealing a partial run as complete).
    %% F1-A: the done-id arm is part of next_ready/2's law — a need that IS
    %% some step's id is satisfied when that step completes, even with no
    %% `provides` anywhere (the natural hand-built `join` shape). The old
    %% precheck ignored this arm and falsely refused join/done-id-only plans
    %% as unprovided_need.
    Unprovided =
        [ {ID, N}
          || #{id := ID} = S <- Steps,
             N <- maps:get(needs, S, []),
             not lists:member(N, Ids),
             not maps:is_key(N, Providing) ],
    case Unprovided of
        [] -> kahn(Ids, NeedsMap, Providing, #{}, 0);
        _ -> erlang:error({unprovided_need, lists:sort(Unprovided)})
    end.

%% @doc A need is satisfiable iff the executor could satisfy it: it is a done
%% step id, or some DONE step provides it (Providing maps term -> [id()] so ANY
%% done provider satisfies — next_ready/2's law, not last-wins). This mirrors
%% next_ready/2 exactly: done-id arm (need is some step's id, witnessable at
%% runtime even with no `provides` anywhere) + any-done-provider arm. The
%% 15-shape F1-A court (fond_powl_runner_court_test.exs) pins the equivalence
%% against real run/1 executor probes — planner admits iff the executor runs.
needs_sat(N, Done, Providing) ->
    maps:is_key(N, Done) orelse
        case maps:find(N, Providing) of
            {ok, IDs} -> lists:any(fun(ID) -> maps:is_key(ID, Done) end, IDs);
            error -> false
        end.

kahn(Ids, NeedsMap, Providing, Done, Round) when Round =< length(Ids) ->
    Ready =
        [ID || ID <- Ids,
               not maps:is_key(ID, Done),
               lists:all(fun(N) -> needs_sat(N, Done, Providing) end, maps:get(ID, NeedsMap))],
    case Ready of
        [] ->
            case maps:size(Done) =:= length(Ids) of
                true -> ok;
                false -> erlang:error({cyclic_plan, lists:sort(Ids -- maps:keys(Done))})
            end;
        _ ->
            Done2 = lists:foldl(fun(ID, Acc) -> maps:put(ID, true, Acc) end, Done, Ready),
            kahn(Ids, NeedsMap, Providing, Done2, Round + 1)
    end.

%% @doc First not-yet-done step whose needs are satisfied by the done set.
-spec next_ready([step()], maps:map(id(), true)) -> step() | none.
next_ready(Steps, Done) ->
    Providing = fun(N) ->
        lists:any(fun(#{id := ID, provides := P}) ->
                          maps:is_key(ID, Done) andalso lists:member(N, P)
                  end, Steps)
    end,
    case [S || S <- Steps,
               not maps:is_key(maps:get(id, S), Done),
               lists:all(fun(N) -> maps:is_key(N, Done) orelse Providing(N) end,
                         maps:get(needs, S, []))] of
        [] -> none;
        [S | _] -> S
    end.
