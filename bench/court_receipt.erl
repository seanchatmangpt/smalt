%% court receipt schema + encoder — pure Erlang, no deps (BENCH-11).
%%
%% Canonical JSONL row schema (one line per bench run):
%%   name (bin), n (int), wall_ms (num), ops_sec (num), ns_per_op (num),
%%   reds_per_op (num), heap_delta_kb (num), machine (bin),
%%   otp_release (bin), timestamp (rfc3339 bin), context (bin),
%%   source (measured|const|unmeasured — closed), source_ref (bin)
%%
%% Encoder: term -> iolist -> single jsonl line (no trailing newline).
%% Validation: structural self-check (balanced object + all 11 field
%% names present) plus a fail-closed selftest; the lane driver gates
%% every emitted line through python3 json.loads.
-module(court_receipt).

-export([encode/1, encode_rows/1, write_rows/2, validate_file/1,
         encode_bc/1, encode_bc_verdict/1, validate_bc_file/1,
         machine/0, timestamp/0, otp_release/0, selftest/0]).

-define(FIELDS, [name, n, wall_ms, ops_sec, ns_per_op, reds_per_op,
                 heap_delta_kb, machine, otp_release, timestamp, context,
                 source, source_ref]).

%% Tier-2 provenance (KD-210 vacuous-gate class): every metric row carries a
%% `source` — closed vocabulary, clause-per-clause below — plus a `source_ref`
%% pointing at the command or path:line that produced the numbers. A row whose
%% source is not `measured` can never encode a PASS-class receipt: encode/1
%% refuses it with {pinned_constant_cannot_pass, _}. Fail closed.
-define(SOURCES, [measured, const, unmeasured]).

%% BC-lane (bench_bc_lane) row schema — closed, like the core schema.
-define(BC_FIELDS, [name, wall_ms, ops_per_sec, ns_per_op, reds_per_op,
                    n, rounds, heap_delta_bytes]).

%% BC-lane fence-verdict row schema — closed.
-define(BC_VERDICT_FIELDS, [fence, ratio, verdict]).

-define(DQ, 34). %% double quote, as integer byte (mangle-proof)

%% ------------------------------------------------------------------
%% Encoding
%% ------------------------------------------------------------------

%% encode(Row) -> binary jsonl line (no trailing \n). Fails hard
%% (error schema_violation) on a row missing any schema field or carrying
%% a non-schema key — the schema is closed.
encode(Row) when is_map(Row) ->
    lists:sort(maps:keys(Row)) =:= lists:sort(?FIELDS) orelse
        erlang:error({schema_violation, maps:keys(Row)}),
    check_source(maps:get(source, Row), maps:get(source_ref, Row)),
    iolist_to_binary(json_object(Row)).

check_source(measured = S, Ref) when is_binary(Ref) -> S;
check_source(unmeasured = S, Ref) when is_binary(Ref) ->
    %% A row not measured at all cannot back a PASS-class receipt.
    erlang:error({pinned_constant_cannot_pass, S});
check_source(const = S, Ref) when is_binary(Ref) ->
    %% A pinned constant cannot back a PASS-class receipt (KD-210).
    erlang:error({pinned_constant_cannot_pass, S});
check_source(S, _) ->
    erlang:error({unknown_source, S}).

encode_rows(Rows) ->
    [[encode(R), $\n] || R <- Rows].

write_rows(Rows, Path) ->
    filelib:ensure_dir(Path),
    ok = file:write_file(Path, encode_rows(Rows)),
    Path.

%% encode_bc(Row) -> binary jsonl line. Closed-schema BC row; fails hard
%% (error {bc_schema_violation, Keys}) on missing/extra keys.
encode_bc(Row) when is_map(Row) ->
    lists:sort(maps:keys(Row)) =:= lists:sort(?BC_FIELDS) orelse
        erlang:error({bc_schema_violation, maps:keys(Row)}),
    iolist_to_binary(json_object_bc(?BC_FIELDS, Row)).

%% encode_bc_verdict(V) -> binary jsonl line for a fence-verdict row.
encode_bc_verdict(V) when is_map(V) ->
    lists:sort(maps:keys(V)) =:= lists:sort(?BC_VERDICT_FIELDS) orelse
        erlang:error({bc_verdict_schema_violation, maps:keys(V)}),
    iolist_to_binary(json_object_bc(?BC_VERDICT_FIELDS, V)).

%% validate_bc_file(Path) -> ok | {fail, Reason}. Every line must be a
%% balanced JSON object carrying all keys of the BC row schema or the BC
%% verdict schema.
validate_bc_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>],
            case Lines of
                [] -> {fail, empty_file};
                _ ->
                    Bad = [L || L <- Lines, not bc_line_ok(L)],
                    case Bad of
                        [] -> ok;
                        _ -> {fail, {bad_lines, length(Bad)}}
                    end
            end;
        {error, E} ->
            {fail, {read_error, E}}
    end.

bc_line_ok(L) ->
    binary:first(L) =:= ${ andalso binary:last(L) =:= $}
        andalso count_char(L, ${) =:= count_char(L, $})
        andalso (bc_fields_ok(?BC_FIELDS, L) orelse
                 bc_fields_ok(?BC_VERDICT_FIELDS, L)).

bc_fields_ok(Fields, L) ->
    [K || K <- Fields, not field_present(K, L)] =:= [].

json_object_bc(Fields, Row) ->
    Pairs = [[comma(I), dq(), key(K), dq(), $:, json_value(maps:get(K, Row))]
             || {I, K} <- indexed(Fields)],
    [${, Pairs, $}].

%% ------------------------------------------------------------------
%% Validation (structural, pure Erlang)
%% ------------------------------------------------------------------

%% validate_file(Path) -> ok | {fail, Reason}. Every line must be a
%% balanced JSON object carrying all 11 schema field names.
validate_file(Path) ->
    case file:read_file(Path) of
        {ok, Bin} ->
            Lines = [L || L <- binary:split(Bin, <<"\n">>, [global]), L =/= <<>>],
            case Lines of
                [] -> {fail, empty_file};
                _ ->
                    Bad = [L || L <- Lines, not line_ok(L)],
                    case Bad of
                        [] -> ok;
                        _ -> {fail, {bad_lines, length(Bad)}}
                    end
            end;
        {error, E} ->
            {fail, {read_error, E}}
    end.

line_ok(L) ->
    binary:first(L) =:= ${ andalso binary:last(L) =:= $}
        andalso count_char(L, ${) =:= count_char(L, $})
        andalso count_char(L, ?DQ) rem 2 =:= 0
        andalso [K || K <- ?FIELDS, not field_present(K, L)] =:= [].

field_present(K, L) ->
    Key = atom_to_binary(K),
    Pat = <<?DQ, Key/binary, ?DQ, $:>>,
    binary:match(L, Pat) =/= nomatch.

count_char(Bin, C) when is_binary(Bin), is_integer(C) ->
    length(binary:matches(Bin, <<C>>)).

%% ------------------------------------------------------------------
%% Environment facts
%% ------------------------------------------------------------------

machine() ->
    {Family, _} = os:type(),
    iolist_to_binary([atom_to_binary(Family), "-",
                      erlang:system_info(system_architecture)]).

timestamp() ->
    iolist_to_binary(
      calendar:system_time_to_rfc3339(erlang:system_time(millisecond),
                                      [{unit, millisecond}, {offset, "Z"}])).

otp_release() ->
    list_to_binary(erlang:system_info(otp_release)).

%% ------------------------------------------------------------------
%% Selftest: good rows encode + roundtrip-validate; bad rows (missing
%% field, extra key, non-numeric value, non-binary name) are refused.
%% Exit 0 PASS / 1 FAIL (fail-closed).
%% ------------------------------------------------------------------

selftest() ->
    Good = row(<<"selftest-good">>),
    BadMissing = maps:remove(context, row(<<"selftest-missing-context">>)),
    BadExtra = maps:merge(row(<<"selftest-extra">>), #{extra => 1}),
    BadNonNum = maps:merge(row(<<"selftest-nan">>), #{wall_ms => not_a_number}),
    BadName = (maps:merge(row(<<"selftest-name">>), #{name => not_a_binary})),
    ConstRow = maps:merge(row(<<"selftest-const">>),
                          #{source => const,
                            source_ref => <<"bench:echo 42">>}),
    UnmeasuredRow = maps:merge(row(<<"selftest-unmeasured">>),
                               #{source => unmeasured,
                                 source_ref => <<"bench:skipped">>}),
    BadSource = maps:merge(row(<<"selftest-bad-source">>),
                           #{source => fabricated}),
    BadRef = maps:merge(row(<<"selftest-bad-ref">>),
                        #{source_ref => not_a_binary}),
    Results =
        [{good_encodes,
          try is_binary(encode(Good)) catch _:_ -> false end},
         {good_roundtrip_validates,
          try roundtrip(Good), true catch _:_ -> false end},
         {missing_field_refused,
          try encode(BadMissing), false catch _:_ -> true end},
         {extra_key_refused,
          try encode(BadExtra), false catch _:_ -> true end},
         {non_numeric_refused,
          try encode(BadNonNum), false catch _:_ -> true end},
         {non_binary_name_refused,
          try encode(BadName), false catch _:_ -> true end},
         {pinned_const_row_refused_as_pass,
          try encode(ConstRow), false catch error:{pinned_constant_cannot_pass, const} -> true;
              _:_ -> false end},
         {unmeasured_row_refused_as_pass,
          try encode(UnmeasuredRow), false
          catch error:{pinned_constant_cannot_pass, unmeasured} -> true;
              _:_ -> false end},
         {unknown_source_refused,
          try encode(BadSource), false catch error:{unknown_source, fabricated} -> true;
              _:_ -> false end},
         {non_binary_source_ref_refused,
          try encode(BadRef), false catch _:_ -> true end}],
    case [K || {K, false} <- Results] of
        [] ->
            io:format("RECEIPT-SCHEMA PASS ~s~n",
                      [string:join([atom_to_list(K) || {K, true} <- Results], " ")]),
            halt(0);
        Failed ->
            io:format("RECEIPT-SCHEMA FAIL ~p~n", [Failed]),
            halt(1)
    end.

roundtrip(Row) ->
    Dir = filename:join("/tmp", "court_receipt_selftest"),
    filelib:ensure_dir(Dir ++ "/x"),
    Path = filename:join(Dir, integer_to_list(erlang:unique_integer([positive]))
                             ++ ".jsonl"),
    ok = file:write_file(Path, encode_rows([Row])),
    R = validate_file(Path),
    _ = file:delete(Path),
    case R of
        ok -> ok;
        {fail, Reason} -> erlang:error({roundtrip, Reason})
    end.

%% ------------------------------------------------------------------
%% JSON encoding internals
%% ------------------------------------------------------------------

json_object(Row) ->
    Pairs = [[comma(I), dq(), key(K), dq(), $:, json_value(maps:get(K, Row))]
             || {I, K} <- indexed(?FIELDS)],
    [${, Pairs, $}].

comma(1) -> <<>>;
comma(_) -> <<",">>.

dq() -> <<?DQ>>.

key(K) -> atom_to_binary(K).

json_value(B) when is_binary(B) -> [dq(), B, dq()];
json_value(S) when S =:= measured orelse S =:= const orelse S =:= unmeasured ->
    [dq(), atom_to_binary(S), dq()];
json_value(I) when is_integer(I) -> integer_to_binary(I);
json_value(F) when is_float(F) -> fmt_float(F).

fmt_float(F) ->
    S = iolist_to_binary(io_lib:format("~.6f", [F])),
    Trim = re:replace(S, <<"(\.[0-9]*[1-9])0+\$">>, <<"\\1">>,
                      [{return, binary}]),
    re:replace(Trim, <<"\.000\$">>, <<>>, [{return, binary}]).

indexed(List) ->
    lists:zip(lists:seq(1, length(List)), List).

row(Name) ->
    #{name => Name, n => 10, wall_ms => 1.5, ops_sec => 6666.666667,
      ns_per_op => 150000.0, reds_per_op => 12.5, heap_delta_kb => 2.0,
      machine => machine(), otp_release => otp_release(),
      timestamp => timestamp(), context => <<"solo">>,
      source => measured, source_ref => <<"bench:measured">>}.
