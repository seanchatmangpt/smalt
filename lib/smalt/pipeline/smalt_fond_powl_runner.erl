%% FONDRUNNER — HTN→FOND→POWL→OCEL pipeline as a self-driving gen_statem.
%%
%% Five stages, each entered and driven by its own `enter` event
%% (state_enter callback mode), no external clock or coordinator:
%%   htn → fond → powl → ocel → seal
%%
%% gen_statem law observed here (verified against stdlib-8.1.1 source): an
%% `enter` call may NOT change state (bad_state_enter_return) and may NOT
%% insert events (bad_state_enter_action) — both are StateCall-only. The
%% lawful self-driving idiom:
%%   init / event handlers (StateCall context) mint
%%   {next_event, internal, advance} alongside their state transition;
%%   the enter call of each state is the entry hook (state_enter mode),
%%   re-fired on the fond 412 loopback (same-state re-entry).
-module(smalt_fond_powl_runner).

-behaviour(gen_statem).

-export([run/1, start_pipeline/1]).
-export([init/1, callback_mode/0, handle_event/4, terminate/3]).

-define(MAX_RETRIES, 10).

-type receipt() :: #{
    merkle := binary(),
    event_count := non_neg_integer(),
    step_count := non_neg_integer(),
    plan := [term()],
    otp_release := integer()
}.

%% ===================================================================
%% API
%% ===================================================================

%% @doc Synchronous runner. Returns {ok, Receipt} on completion or
%% {crash, Reason} on any fatal divergence (crash-only: no recovery).
-spec run(map()) -> {ok, receipt()} | {crash, term()}.
run(Opts) when is_map(Opts) ->
    %% Optional bounded receive (EXPL-10 F6 repair): a contingency fun that
    %% never returns (timer:sleep(infinity)) would otherwise hang the caller
    %% forever — the FSM is blocked INSIDE Cont(Step) and can neither reply
    %% nor handle a stop. The bound lives at this receive; on expiry the
    %% caller gets a typed crash carrying the work still outstanding (the
    %% plan spine, honestly labeled: with the FSM blocked mid-step, the
    %% caller cannot know which steps already completed).
    Timeout = timeout(Opts),
    %% Single-message protocol: the FSM carries the receipt out as its exit
    %% reason ({completed, Receipt}). A raw `send` from the FSM plus the
    %% kernel's 'DOWN' is a two-sender race — DOWN(normal) can overtake an
    %% unordered receipt and corrupt the result. One message, one sender.
    case gen_statem:start(?MODULE, {self(), Opts}, []) of
        {ok, P} ->
            M = erlang:monitor(process, P),
            receive
                {'DOWN', M, process, P, {completed, Receipt}} -> {ok, Receipt};
                {'DOWN', M, process, P, Reason} -> {crash, Reason}
            after Timeout ->
                erlang:demonitor(M, [flush]),
                {crash, {fond_receive_timeout, remaining_work(Opts, Timeout)}}
            end;
        {error, Reason} ->
            {crash, Reason}
    end.

%% @doc Bounded receive: `infinity` (default) preserves the old behavior for
%% start_pipeline owners; a positive integer bound is milliseconds.
timeout(Opts) ->
    case maps:find(timeout, Opts) of
        error -> infinity;
        {ok, T} when T =:= infinity; is_integer(T) andalso T > 0 -> T;
        {ok, Bad} -> erlang:error({bad_timeout_opt, Bad})
    end.

%% @doc Work not yet witnessed complete at timeout expiry. The FSM is blocked
%% inside a contingency fun, so per-step completion is unknowable from the
%% caller — the full plan spine is reported as outstanding.
remaining_work(Opts, Timeout) ->
    Plan =
        case maps:find(plan, Opts) of
            {ok, P} -> P;
            error -> smalt_fond_plan:linear_plan(maps:get(tasks, Opts, []))
        end,
    #{timeout_ms => Timeout,
      plan => [maps:get(id, S) || S <- smalt_fond_plan:steps(Plan)],
      note => <<"fsm blocked in contingency fun; per-step completion unknowable from caller">>}.

%% @doc Direct (async) entry point — caller owns the gen_statem lifecycle.
-spec start_pipeline(map()) -> gen_statem:start_ret().
start_pipeline(Opts) ->
    gen_statem:start(?MODULE, {self(), Opts}, []).

%% ===================================================================
%% gen_statem callbacks
%% ===================================================================

callback_mode() ->
    [state_enter, handle_event_function].

init({Parent, Opts}) ->
    Plan =
        case maps:find(plan, Opts) of
            {ok, P} -> P;
            error -> smalt_fond_plan:linear_plan(maps:get(tasks, Opts, []))
        end,
    Data =
        #{parent => Parent,
          opts => Opts,
          plan => Plan,
          done => #{},
          ledger => #{},
          seq => 0,
          retries => 0,
          max_retries => maps:get(max_retries, Opts, ?MAX_RETRIES),
          contingency => maps:get(contingency, Opts, fun(_Step) -> ok end)},
    {ok, htn, Data, [{next_event, internal, advance}]}.

%% ---------------- stage 1: HTN decomposition ----------------
%% enter: acyclicity is a hard precondition (crash-only fatal divergence).
handle_event(enter, _Prev, htn, _Data) ->
    keep_state_and_data;
handle_event(internal, advance, htn, #{plan := Plan} = Data) ->
    %% Crash-only: a cyclic spine refuses to boot.
    ok = smalt_fond_plan:assert_acyclic(Plan),
    Steps = smalt_fond_plan:steps(Plan),
    Data2 =
        lists:foldl(
            fun(#{id := ID}, Acc) ->
                {Acc2, _} = emit(Acc, #{kind => htn_decompose, step => ID}),
                Acc2
            end,
            Data,
            Steps
        ),
    {next_state, fond, Data2, [{next_event, internal, advance}]};

%% ---------------- stage 2: FOND execution with 412 loopback ----------------
handle_event(enter, _Prev, fond, _Data) ->
    keep_state_and_data;
handle_event(internal, advance, fond, Data) ->
    case smalt_fond_plan:next_ready(smalt_fond_plan:steps(maps:get(plan, Data)),
                                    maps:get(done, Data))
    of
        none ->
            {next_state, powl, Data, [{next_event, internal, advance}]};
        Step ->
            #{id := ID} = Step,
            Cont = maps:get(contingency, Data),
            case Cont(Step) of
                ok ->
                    {Data2, _} =
                        emit(Data#{done => (maps:get(done, Data))#{ID => true}},
                             #{kind => step_executed, step => ID}),
                    {next_state, fond, Data2,
                     [{next_event, internal, advance}]};
                {precondition_failed, 412} ->
                    loopback(Data, Step);
                Other ->
                    erlang:error({bad_contingency_result, Other})
            end
    end;

%% ---------------- stage 3: POWL projection ----------------
handle_event(enter, _Prev, powl, _Data) ->
    keep_state_and_data;
handle_event(internal, advance, powl, Data) ->
    Done = maps:get(done, Data),
    Order =
        [maps:get(id, S)
         || S <- smalt_fond_plan:steps(maps:get(plan, Data)), maps:is_key(maps:get(id, S), Done)],
    {Data2, _} =
        emit(Data#{powl => {partial_order, Order}}, #{kind => powl_projected, order => Order}),
    {next_state, ocel, Data2, [{next_event, internal, advance}]};

%% ---------------- stage 4: OCEL ledger finalization ----------------
handle_event(enter, _Prev, ocel, _Data) ->
    keep_state_and_data;
handle_event(internal, advance, ocel, Data) ->
    {Data2, _} = emit(Data, #{kind => ocel_finalized}),
    {next_state, seal, Data2, [{next_event, internal, advance}]};

%% ---------------- stage 5: seal + reply ----------------
handle_event(enter, _Prev, seal, _Data) ->
    keep_state_and_data;
handle_event(internal, advance, seal, Data) ->
    {Data2, #{kind := sealed}} = emit(Data, #{kind => sealed}),
    Ledger = maps:get(ledger, Data2),
    case smalt_fond_seal:seal(Ledger) of
        {ok, Merkle} ->
            Receipt =
                #{merkle => Merkle,
                  event_count => maps:size(Ledger),
                  step_count => maps:size(maps:get(done, Data)),
                  plan => [maps:get(id, S)
                           || S <- smalt_fond_plan:steps(maps:get(plan, Data))],
                  otp_release => otp_release_int()},
            {stop, {completed, Receipt}};
        {refuse, Reason} ->
            %% Typed refusal: the fingerprint gate failed — no digest exists.
            erlang:error({seal_refused, Reason})
    end;

handle_event(_EventType, _Event, _State, _Data) ->
    %% Unknown events are a fatal divergence (self-driving FSM: nothing
    %% external should ever poke it).
    erlang:error({unexpected_pipeline_event, unknown}).

%% Retry ceiling wired through a plain range guard (is_integer/3 does not
%% exist in Erlang; this is the equivalent range check). Passing clause admits retries in [0, Max];
%% the fallthrough clause is the crash-only exhaustion path. The loopback is
%% a same-state re-entry of fond — enter refires, the tail replans.
loopback(#{retries := R, max_retries := Max} = Data, Step)
    when is_integer(R) andalso R >= 0 andalso R =< Max ->
    {Data2, _} =
        emit(Data#{retries => R + 1}, #{kind => fond_412_loopback, step => maps:get(id, Step)}),
    {next_state, fond, Data2, [{next_event, internal, advance}]};
loopback(#{retries := R, max_retries := Max, plan := Plan}, Step) ->
    erlang:error({fond_loop_bound_exhausted,
                  #{retries => R,
                    max_retries => Max,
                    stuck_on => maps:get(id, Step),
                    plan => [maps:get(id, S) || S <- smalt_fond_plan:steps(Plan)]}}).


%% ---------------- shared emit ----------------
emit(Data, Event0) ->
    Seq = maps:get(seq, Data),
    Idx = Seq + 1,
    Event = Event0#{seq => Idx},
    Ledger = (maps:get(ledger, Data))#{Idx => Event},
    {Data#{seq => Idx, ledger => Ledger}, Event}.

otp_release_int() ->
    case erlang:system_info(otp_release) of
        N when is_integer(N) -> N;
        S when is_list(S) -> list_to_integer(S)
    end.

terminate(_Reason, _State, _Data) ->
    ok.
