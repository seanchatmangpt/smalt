%% smalt_digital_twins.erl — DTMI envelope twins over the ARM store.
%% upsert_twin/4: DTMI envelope -> gl_call Op 1 (sieve classify) ->
%% dt:twin put_cas + journal row. link_twins/5: RDF triple -> Op 1 ->
%% dt:edge put_cas + journal row. query_twins/2: dispatch to the
%% lakehouse Op 15 through smalt_wasm_pool:gl_call/2 (thin adapter;
%% smalt_lakehouse_mount executes). Zero dynamic atoms on wire paths.
-module(smalt_digital_twins).
-export([upsert_twin/4, link_twins/5, query_twins/2]).

%% -- upsert_twin: DTMI envelope -> Op 1 -> dt:twin + journal -------------

upsert_twin(Id, Dtmi, Payload, Opts) when is_binary(Id),
                                          is_binary(Dtmi),
                                          is_binary(Payload) ->
    Envelope = #{<<"id">> => Id,
                 <<"dtmi">> => Dtmi,
                 <<"payload">> => Payload,
                 <<"wall_ms">> => os:system_time(millisecond)},
    EnvBin = term_to_binary(Envelope),
    {ok, {sieved, Class, Digest}} = smalt_wasm_pool:gl_call(1, EnvBin),
    TwinKey = {dt, twin, Id},
    ok = smalt_store:put_cas(TwinKey, Envelope, any),
    {ok, ETag} =
        smalt_journal_sink_compat:put(
          {dt, journal, twin, Id},
          term_to_binary(#{op => upsert_twin,
                           dtmi => Dtmi,
                           digest => Digest,
                           wall_ms => os:system_time(millisecond)})),
    {ok, ETag, #{class => Class, digest => Digest, opts => Opts}}.

%% -- link_twins: RDF triple -> Op 1 -> dt:edge + journal ------------------

link_twins(FromId, Rel, ToId, Props, TxnId) when is_binary(FromId),
                                                 is_binary(Rel),
                                                 is_binary(ToId),
                                                 is_binary(TxnId),
                                                 is_map(Props) ->
    Edge = #{<<"from">> => FromId,
             <<"rel">> => Rel,
             <<"to">> => ToId,
             <<"props">> => Props,
             <<"txn">> => TxnId,
             <<"wall_ms">> => os:system_time(millisecond)},
    EdgeBin = term_to_binary(Edge),
    {ok, {sieved, Class, Digest}} = smalt_wasm_pool:gl_call(1, EdgeBin),
    EdgeKey = {dt, edge, FromId, Rel, ToId},
    ok = smalt_store:put_cas(EdgeKey, Edge, any),
    {ok, ETag} =
        smalt_journal_sink_compat:put(
          {dt, journal, edge, FromId, Rel, ToId},
          term_to_binary(#{op => link_twins,
                           txn => TxnId,
                           digest => Digest,
                           wall_ms => os:system_time(millisecond)})),
    {ok, ETag, #{class => Class, digest => Digest}}.

%% -- query_twins: Op 15 dispatch to the lakehouse -------------------------

query_twins(Query, Opts) ->
    case smalt_wasm_pool:gl_call(
           15, term_to_binary({dt_lakehouse_query, Query, Opts}))
    of
        %% admit wire <<0:8,Result>>; refusal decoded to {refused,...}
        {ok, <<0:8, ResultBin/binary>>} ->
            {ok, binary_to_term(ResultBin)};
        {error, {andon, <<_:8, _:32, Reason/binary>>}} ->
            {refused, Reason};
        {error, {andon, Reason}} ->
            {refused, Reason};
        Other ->
            Other
    end.
