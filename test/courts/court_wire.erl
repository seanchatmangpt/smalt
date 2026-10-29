%% =============================================================================
%% ECOURT wire fence — PURE ERLANG cross-language falsification court.
%%
%% Zero Elixir helpers, zero JSON/XML libs. Attacks the live smalt substrate
%% over raw :gen_tcp / :ssl with bit-syntax frame building + binary pattern
%% matching. If the Elixir SUT's wire shapes drift, this court catches what
%% Elixir-authored tests mirror.
%%
%% Legs:
%%   1. AMQP 5672   : SASL ANONYMOUS handshake, sasl-outcome 0x44, CBS
%%                    put-token with a REAL HMAC-SHA256 SAS token (per-host
%%                    dev key), queue attach+transfer, disposition accepted.
%%   2. Cosmos REST : raw HTTP/1.1 over TLS 9444, STS form POST, db/coll/doc
%%                    create + read, id/_etag markers asserted via binary
%%                    match.
%%   3. Blob XML    : raw PUT/GET/DELETE over 9444, StorageError XML envelope
%%                    bytes + x-ms-error-code header bytes on the 404.
%%   4. APIM plane  : typed refusals through the /apim-gw namespace (typed
%%                    404 RouteNotFound envelope; 429/401 sub-leg loud SKIP
%%                    when the route family is default-off on the substrate).
%%
%% Any violation: erlang:error({fence_violation, ...}) — the court fails
%% loudly, it never fakes a pass. Substrate down: loud SKIP (exit 3).
%%
%% Runner: scripts/courts/court_wire.sh
%% =============================================================================
-module(court_wire).

-export([main/1, main/0, frame/3, desc/2, enc_str/1, enc_sym/1, enc_bin/1, enc_map/1]).

-define(HOST, "127.0.0.1").
-define(AMQP_PORT, 5672).
-define(TLS_PORT, 9444).
-define(TIMEOUT, 15000).
%% CA path: env-derived by the runner (scripts/courts/court_wire.sh); repo-relative fallback.
-define(CA_FILE, case os:getenv("SMALT_CA_FILE") of false -> ".smalt/tls/ca-cert.pem"; P -> P end).

main(_) -> main().

main() ->
    application:ensure_all_started(ssl),
    application:ensure_all_started(crypto),
    Uniq = integer_to_list(erlang:unique_integer([positive])),
    case os:getenv("SMALT_SB_SHARED_KEY") of
        false -> erlang:error({fence_config, smalt_sb_shared_key_unset});
        KeyBin -> run_all(KeyBin, Uniq)
    end.

run_all(KeyBin, Uniq) ->
    R1 = leg_amqp(KeyBin, ["ecourt-q-", Uniq]),
    R2 = leg_cosmos(["ecourt-d-", Uniq], Uniq),
    R3 = leg_blob(["ecourt-b-", Uniq], Uniq),
    R4 = leg_apim(Uniq),
    Results = R1 ++ R2 ++ R3 ++ R4,
    io:format("~n=== ECOURT WIRE FENCE VERDICT ===~n"),
    lists:foreach(
      fun({Leg, Name, St}) -> io:format("  [~s] ~s~n", [St, Leg ++ ":" ++ Name])
      end, Results),
    Sts = [S || {_, _, S} <- Results],
    case lists:member("FAIL", Sts) of
        true -> io:format("ECOURT: FENCE VIOLATION~n"), halt(1);
        false ->
            case lists:member("SKIP", Sts) of
                true -> io:format("ECOURT: PASS WITH LOUD SKIP~n"), halt(0);
                false -> io:format("ECOURT: ALL LEGS PASS~n"), halt(0)
            end
    end.

%% =============================================================================
%% LEG 1 — AMQP raw wire (5672)
%% =============================================================================
leg_amqp(KeyBin, QueueIo) ->
    Q = iolist_to_binary(QueueIo),
    io:format("~n[leg1] AMQP raw wire :5672 queue=~s~n", [Q]),
    {ok, Sock} = gen_tcp:connect(?HOST, ?AMQP_PORT,
                                 [binary, {packet, raw}, {active, false}],
                                 ?TIMEOUT),
    %% -- protocol header (SASL layer): byte-exact echo required --
    ok = gen_tcp:send(Sock, <<"AMQP", 3, 1, 0, 0>>),
    {Hdr, B0} = recv_exact(Sock, 8, <<>>),
    assert_bin(<<"AMQP", 3, 1, 0, 0>>, Hdr, amqp_sasl_header_echo),
    %% -- server-mechanisms frame: must offer ANONYMOUS --
    {16#01, MechBody, B1} = recv_frame(Sock, B0),
    assert_contains(<<"ANONYMOUS">>, MechBody, amqp_sasl_mechanisms_anonymous),
    %% -- sasl-init (descriptor 0x41): mechanism=ANONYMOUS, null, null --
    SaslInit = frame(16#01, 0,
                     desc(16#41, [enc_sym(<<"ANONYMOUS">>),
                                  <<16#40>>,    %% initial-response: null
                                  <<16#40>>])), %% hostname: null
    ok = gen_tcp:send(Sock, SaslInit),
    {16#01, OutcomeBody, B1} = recv_frame(Sock, B1),
    %% sasl-outcome descriptor 0x44 (pinned by real-SDK census) + code 0
    assert_prefix(<<0, 16#53, 16#44>>, OutcomeBody, amqp_sasl_outcome_descriptor_0x44),
    assert_sasl_outcome_zero(OutcomeBody),
    io:format("  [leg1] SASL ANONYMOUS handshake OK (outcome 0x44 code 0)~n"),

    %% -- AMQP layer: header + open + begin --
    ok = gen_tcp:send(Sock, <<"AMQP", 0, 1, 0, 0>>),
    {Hdr2, B0b} = recv_exact(Sock, 8, B1),
    assert_bin(<<"AMQP", 0, 1, 0, 0>>, Hdr2, amqp_header_echo),
    Open = frame(16#00, 0,
                 desc(16#10, [enc_str(<<"ecourt-fence">>),    %% container-id
                              <<16#40>>,                       %% hostname
                              <<16#70, 0, 1, 0, 0>>,           %% max-frame-size 65536
                              <<16#40>>, <<16#40>>, <<16#40>>,
                              <<16#40>>, <<16#40>>, <<16#40>>,
                              <<16#40>>])),
    Begin = frame(16#00, 0,
                  desc(16#11, [<<16#40>>,                      %% remote-channel
                               <<16#52, 0>>,                   %% next-outgoing-id 0
                               <<16#70, 0, 1, 16#86, 16#A0>>,  %% incoming-window 100000
                               <<16#70, 0, 1, 16#86, 16#A0>>,  %% outgoing-window
                               <<16#40>>])),                   %% handle-max
    ok = gen_tcp:send(Sock, [Open, Begin]),
    {16#00, OpenBody, B3} = recv_frame(Sock, B0b),
    assert_prefix(<<0, 16#53, 16#10>>, OpenBody, amqp_open_descriptor),
    assert_contains(<<"smalt-local">>, OpenBody, amqp_open_container_id),
    {16#00, BeginBody, B4} = recv_frame(Sock, B3),
    assert_prefix(<<0, 16#53, 16#11>>, BeginBody, amqp_begin_descriptor),

    %% -- attach CBS sender (handle 0) + CBS receiver (handle 1) + flow --
    AttS = frame(16#00, 0, attach_frame(0, false, none, <<"$cbs">>)),
    AttR = frame(16#00, 0, attach_frame(1, true, <<"$cbs">>, none)),
    Flow1 = frame(16#00, 0, flow_frame(1, 200)),
    ok = gen_tcp:send(Sock, [AttS, AttR, Flow1]),
    B5 = drain_to_attach_acks(Sock, 2, B4),

    %% -- CBS put-token: REAL SAS token, HMAC-SHA256 over sr with dev key --
    Token = sas_token(KeyBin, <<"sb://127.0.0.1:5672">>),
    %% symbol KEYS + string VALUES (real-SDK shape; the substrate's
    %% normalize_keys converts symbol keys only — a symbol VALUE decodes as
    %% {:symbol, _} and fails the plain-binary check_operation/2 compare).
    %% NOTE: desc_val, NOT desc — the section value IS the map; desc/2 would
    %% wrap it in a bogus list32 (fields = the map's own encoding bytes).
    AppProps = desc_val(16#74, enc_map([{s, <<"operation">>, b, <<"put-token">>},
                                    {s, <<"type">>,
                                     b, <<"servicebus.windows.net:sastoken">>},
                                    {s, <<"name">>, b, <<"sb://127.0.0.1:5672">>}])),
    BodyVal = desc_val(16#77, enc_str(Token)),
    DelId = erlang:unique_integer([positive]) rem 1000,
    Transfer = frame(16#00, 0,
                     [desc(16#14, [<<16#52, 0>>,                       %% handle 0
                                   <<16#70, DelId:32/signed-integer>>, %% delivery-id
                                   enc_bin(<<"ecourt-cbs-1">>),        %% delivery-tag
                                   <<16#70, 0, 0, 0, 0>>,              %% message-format 0
                                   <<16#41>>]),                        %% settled true
                      %% payload rides the same frame body after the fields
                      AppProps, BodyVal]),
    ok = gen_tcp:send(Sock, Transfer),
    CbsPayload = recv_transfer_payload(Sock, 1, B5),
    assert_contains(<<"status-code">>, CbsPayload, cbs_reply_statuscode_marker),
    %% server emits status-code as uint32 0x70 (accept smalluint/ubyte too)
    assert_status_200(CbsPayload),
    assert_not_contains(<<"INVALID_LOCAL_SAS">>, CbsPayload, cbs_no_invalid_sas),
    assert_not_contains(<<"UNSUPPORTED_CBS_REQUEST">>, CbsPayload, cbs_no_unsupported),
    assert_not_contains(<<"CLAIM_CAPACITY">>, CbsPayload, cbs_no_capacity),
    io:format("  [leg1] CBS put-token verified (statusCode 200)~n"),

    %% -- queue-scoped put-token (claim keyed by "endpoint/<entity>";
    %%    namespace-only claims do not authorize the entity attach) --
    QAud = [<<"sb://127.0.0.1:5672/">>, Q],
    TokenQ = sas_token(KeyBin, iolist_to_binary(QAud)),
    AppPropsQ = desc_val(16#74, enc_map([{s, <<"operation">>, b, <<"put-token">>},
                                         {s, <<"type">>,
                                          b, <<"servicebus.windows.net:sastoken">>},
                                         {s, <<"name">>, b, iolist_to_binary(QAud)}])),
    BodyValQ = desc_val(16#77, enc_str(TokenQ)),
    QXferCbs = frame(16#00, 0,
                     [desc(16#14, [<<16#52, 0>>,
                                   <<16#70, (DelId + 1):32/signed-integer>>,
                                   enc_bin(<<"ecourt-cbs-2">>),
                                   <<16#70, 0, 0, 0, 0>>,
                                   <<16#41>>]),
                      AppPropsQ, BodyValQ]),
    ok = gen_tcp:send(Sock, QXferCbs),
    CbsPayloadQ = recv_transfer_payload(Sock, 1, <<>>),
    assert_contains(<<"status-code">>, CbsPayloadQ, cbs_reply_statuscode_marker),
    assert_status_200(CbsPayloadQ),
    io:format("  [leg1] queue-scoped CBS put-token verified (statusCode 200)~n"),

    %% -- queue attach + transfer + disposition accepted --
    AttQ = frame(16#00, 0, attach_frame(2, false, none, Q)),
    ok = gen_tcp:send(Sock, AttQ),
    %% payload buffer is drained; the attach ack starts a fresh read window
    drain_to_attach_acks(Sock, 1, <<>>),
    QDelId = erlang:unique_integer([positive]) rem 1000,
    QXfer = frame(16#00, 0,
                  [desc(16#14, [<<16#52, 2>>,
                                <<16#70, QDelId:32/signed-integer>>,
                                enc_bin(<<"ecourt-qtag-1">>),
                                <<16#70, 0, 0, 0, 0>>,
                                <<16#40>>]),  %% unsettled: server must settle
                   desc_val(16#77, enc_str(<<"ecourt-payload-1">>))]),
    ok = gen_tcp:send(Sock, QXfer),
    Disp = recv_disposition(Sock, <<>>),
    %% AMQP performative codes: disposition=0x15 (detach is 0x16 — the
    %% byte-observed detach w/ unauthorized-access is what the pre-fix court
    %% was mislabeling), end=0x17, close=0x18
    assert_prefix(<<0, 16#53, 16#15>>, Disp, queue_disposition_descriptor),
    assert_contains(<<0, 16#53, 16#24>>, Disp, queue_disposition_accepted),

    %% -- clean close --
    End = frame(16#00, 0, desc(16#17, [<<16#40>>])),
    Close = frame(16#00, 0, desc(16#19, [<<16#40>>])),
    gen_tcp:send(Sock, [End, Close]),
    gen_tcp:close(Sock),
    io:format("  [leg1] queue attach+transfer+disposition accepted OK~n"),
    [{"amqp", "sasl+cbs+queue", "PASS"}].

%% -- AMQP wire helpers (bit syntax only) --------------------------------------

frame(Type, Ch, BodyIo) ->
    Size = 8 + iolist_size(BodyIo),
    [<<Size:32, 2, Type, Ch:16>>, BodyIo].

%% described value whose body is a RAW encoded value (map body of
%% application-properties, string body of amqp-value) — NOT a field list
desc_val(Desc, ValueIo) ->
    [<<0, 16#53, Desc>>, ValueIo].

%% described performative: constructor 0x00 + smallulong descriptor + list32 fields
desc(Desc, Fields) when is_list(Fields) ->
    %% compound size INCLUDES the count field (AMQP §1.6 list32: size covers
    %% count + elements — byte-proven against the substrate's own mechanisms
    %% frame, C0 0F = 1(count) + 14(element ctor+size+body))
    Sz = 4 + iolist_size(Fields),
    N = length(Fields),
    [<<0, 16#53, Desc>>, <<16#D0, Sz:32, N:32>>, Fields].

enc_str(B) when is_binary(B) -> [<<16#A1, (byte_size(B))>>, B].
enc_sym(B) when is_binary(B) -> [<<16#A3, (byte_size(B))>>, B].
enc_bin(B) when is_binary(B) -> [<<16#A0, (byte_size(B))>>, B].

enc_map(Pairs) ->
    Flat = lists:foldr(fun({Kt, K, Vt, V}, Acc) ->
                               [val(Kt, K), val(Vt, V) | Acc]
                       end, [], Pairs),
    Sz = 4 + iolist_size(Flat),
    N = length(Pairs) * 2,
    [<<16#D1, Sz:32, N:32>>, Flat].

val(s, B) -> enc_sym(B);   %% map KEYS: symbol (spec + real SDKs)
val(b, B) -> enc_str(B).   %% map VALUES: string (substrate compares binaries)

attach_frame(Handle, RoleReceiver, Source, Target) ->
    Src = addr_field(16#28, Source),
    Tgt = addr_field(16#29, Target),
    RoleByte = case RoleReceiver of true -> <<16#41>>; false -> <<16#42>> end,
    %% 14-field attach (py-court pinion): snd/rcv-settle-mode BEFORE
    %% source/target — positional decode punishes skipped mid-list fields.
    desc(16#12, [enc_str(<<"ecourt-l", (integer_to_binary(Handle))/binary>>),
                 <<16#52, Handle>>,
                 RoleByte,
                 <<16#40>>,    %% snd-settle-mode (default mixed)
                 <<16#40>>,    %% rcv-settle-mode (default mode-first)
                 Src, Tgt,
                 <<16#40>>,    %% unsettled
                 <<16#40>>,    %% incomplete-unsettled
                 <<16#40>>,    %% initial-delivery-count
                 <<16#40>>,    %% max-message-size
                 <<16#40>>,    %% offered-capabilities
                 <<16#40>>,    %% desired-capabilities
                 <<16#40>>]).  %% properties

addr_field(_Desc, none) -> <<16#40>>;
addr_field(Desc, Addr) ->
    desc(Desc, [enc_str(iolist_to_binary(Addr))]).

flow_frame(Handle, Credit) ->
    desc(16#13, [<<16#52, Handle>>,            %% handle
                 <<16#52, 0>>,                 %% delivery-count
                 <<16#70, 0, 0, 0, Credit>>,   %% credit
                 <<16#42>>,                    %% drain false
                 <<16#42>>,                    %% echo false
                 <<16#40>>, <<16#40>>]).

%% Read one frame; return {PerfType, Body} where Body includes any payload.
recv_frame(Sock) -> recv_frame(Sock, <<>>).

recv_frame(Sock, Buf) ->
    case need(Buf) of
        0 ->
            <<Size:32, Doff, T, _Ch:16, Rest/binary>> = Buf,
            Doff =:= 2 orelse
                erlang:error({fence_violation, {amqp_extended_doff, Doff}}),
            BodyLen = Size - 8,
            case Rest of
                <<B:BodyLen/binary, Tail/binary>> -> {T, B, Tail};
                _ -> recv_frame(Sock, more(Sock, Buf))
            end;
        _ ->
            recv_frame(Sock, more(Sock, Buf))
    end.

recv_exact(Sock, N, Buf) when byte_size(Buf) >= N ->
    <<Out:N/binary, Rest/binary>> = Buf,
    {Out, Rest};
recv_exact(Sock, N, Buf) ->
    case gen_tcp:recv(Sock, 0, ?TIMEOUT) of
        {ok, Data} -> recv_exact(Sock, N, <<Buf/binary, Data/binary>>);
        {error, R} -> erlang:error({fence_violation, {amqp_recv_exact, R}})
    end.

more(Sock, Buf) ->
    case gen_tcp:recv(Sock, 0, ?TIMEOUT) of
        {ok, Data} -> <<Buf/binary, Data/binary>>;
        {error, R} -> erlang:error({fence_violation, {amqp_recv, R}})
    end.

need(Buf) when byte_size(Buf) < 4 -> 8;
need(Buf) ->
    <<Size:32, _/binary>> = Buf,
    case Size - byte_size(Buf) of
        N when N > 0 -> N;
        _ -> 0
    end.

%% Drain flow/attach frames until Count attach acks (0x12) observed.
drain_to_attach_acks(_Sock, 0, Buf) -> Buf;
drain_to_attach_acks(Sock, Count, Buf) ->
    {T, B, Tail} = recv_frame(Sock, Buf),
    case B of
        <<0, 16#53, 16#12, _/binary>> ->
            true = (T =:= 16#00) orelse erlang:error({fence_violation,
                                                      {attach_wrong_frame_type, T}}),
            drain_to_attach_acks(Sock, Count - 1, Tail);
        <<0, 16#53, 16#13, _/binary>> ->
            drain_to_attach_acks(Sock, Count, Tail);
        Other ->
            erlang:error({fence_violation, {amqp_expected_attach_ack, Other}})
    end.

%% Read until a transfer (0x14) on Handle; return its payload bytes.
recv_transfer_payload(Sock, Handle, Buf) ->
    {16#00, B, Tail} = recv_frame(Sock, Buf),
    case B of
        <<0, 16#53, 16#14, 16#D0, Sz:32, _N:32, Fields0:Sz/binary, Payload/binary>> ->
            Handle = handle_field(Fields0),
            Payload;
        <<0, 16#53, 16#14, 16#C0, Sz, _N, Fields0:Sz/binary, Payload/binary>> ->
            Handle = handle_field(Fields0),
            Payload;
        <<0, 16#53, 16#14, _/binary>> ->
            erlang:error({fence_violation, {transfer_malformed_list, B}});
        <<0, 16#53, 16#13, _/binary>> ->
            recv_transfer_payload(Sock, Handle, Tail);
        <<0, 16#53, 16#16, _/binary>> ->
            recv_transfer_payload(Sock, Handle, Tail);
        Other ->
            erlang:error({fence_violation, {cbs_expected_transfer, Other}})
    end.

%% First field of the transfer list32 = handle (smalluint 0x52 or uint 0x70).
handle_field(<<16#52, H, _/binary>>) -> H;
handle_field(<<16#70, H:32, _/binary>>) -> H;
handle_field(Other) -> erlang:error({fence_violation, {transfer_handle_encoding, Other}}).

%% Read until a disposition (0x15); a DETACH (0x16) is a fence violation —
%% it is the server's typed link-level refusal and must never be skipped.
recv_disposition(Sock, Buf) ->
    {16#00, B, Tail} = recv_frame(Sock, Buf),
    case B of
        <<0, 16#53, 16#16, _/binary>> ->
            erlang:error({fence_violation, {amqp_unexpected_detach, B}});
        <<0, 16#53, 16#15, _/binary>> -> B;
        <<0, 16#53, 16#13, _/binary>> -> recv_disposition(Sock, Tail);
        _ -> recv_disposition(Sock, Tail)
    end.

%% fields after the 0x44 descriptor: outcome code must encode ZERO in any
%% legal constructor form (0x50 ubyte 0 / 0x52 smalluint 0 / 0x43 ulong-0 /
%% 0x40 null-challenge + code forms). Anything else = refused SASL.
assert_sasl_outcome_zero(Body) ->
    CodeZero = [<<16#50, 0>>, <<16#52, 0>>, <<16#43>>],
    case Body of
        <<0, 16#53, 16#44, Fields/binary>> ->
            case [C || C <- CodeZero, binary:match(Fields, C) =/= nomatch] of
                [] -> erlang:error({fence_violation,
                                    {amqp_sasl_outcome_not_ok, Fields}});
                _ -> ok
            end;
        _ -> erlang:error({fence_violation, {amqp_sasl_outcome_shape, Body}})
    end.

%% percent-encode everything but unreserved chars — the raw base64 '+' would
%% be URI.decode'd to a SPACE server-side (sas_verifier URI.decode(fields.sig))
uri_encode(B) -> << <<(uri_chunk(C))/binary>> || <<C>> <= B >>.

uri_chunk(C) when C >= $A, C =< $Z -> <<C>>;
uri_chunk(C) when C >= $a, C =< $z -> <<C>>;
uri_chunk(C) when C >= $0, C =< $9 -> <<C>>;
uri_chunk(C) when C =:= $-; C =:= $.; C =:= $_; C =:= $~ -> <<C>>;
uri_chunk(C) -> iolist_to_binary(io_lib:format("%~2.16.0b", [C])).

%% status-code must encode 200 in a legal uint constructor form (0x70 uint32 /
%% 0x52 smalluint / 0x50 ubyte); 0x190 = 200
assert_status_200(Body) ->
    Code200 = [<<16#70, 0, 0, 0, 200>>, <<16#52, 200>>, <<16#50, 200>>],
    case [C || C <- Code200, binary:match(Body, C) =/= nomatch] of
        [] -> erlang:error({fence_violation, {cbs_reply_200_missing, Body}});
        _ -> ok
    end.

%% -- SAS token mint (pure crypto, no external help) ---------------------------

sas_token(KeyB64, Sr) ->
    %% HMAC key = the base64 TEXT (substrate shared_key/0 returns the string)
    Key = KeyB64,
    Se = os:system_time(second) + 900,
    %% string-to-sign = "<sr>\n<se>" (SAS spec; sas_verifier check_signature)
    SeBin = integer_to_binary(Se),
    Mac = crypto:mac(hmac, sha256, Key, <<Sr/binary, "\n", SeBin/binary>>),
    Sig = uri_encode(base64:encode(Mac)),
    Skn = <<"RootManageSharedAccessKey">>,
    <<"SharedAccessSignature sr=", Sr/binary,
      "&sig=", Sig/binary,
      "&se=", SeBin/binary,
      "&skn=", Skn/binary>>.

%% =============================================================================
%% LEG 2 — Cosmos REST raw HTTP/1.1 over TLS 9444
%% =============================================================================
leg_cosmos(DbIo, Uniq) ->
    Db = iolist_to_binary(DbIo),
    Coll = iolist_to_binary(["ecourt-c-", Uniq]),  %% unique per run (409 on reuse)
    DocId = ["ecourt-doc-", Uniq],
    io:format("~n[leg2] Cosmos raw TLS :9444 db=~s~n", [Db]),
    Ssl = tls_conn(),

    %% -- STS: raw form POST, token extracted by binary match (no JSON lib) --
    Form = <<"grant_type=client_credentials&client_id=ecourt"
             "&client_secret=ecourt&scope=https://cosmos.azure.com/.default">>,
    {200, _H, TokenBody} = http(Ssl, <<"POST">>,
                                <<"/dev-tenant/oauth2/v2.0/token">>,
                                [hdr(<<"content-type">>,
                                     <<"application/x-www-form-urlencoded">>)],
                                Form),
    AccessToken = extract_token(TokenBody),
    byte_size(AccessToken) > 100
        orelse erlang:error({fence_violation, {sts_token_too_short, AccessToken}}),
    io:format("  [leg2] STS token minted raw (~p bytes)~n", [byte_size(AccessToken)]),
    Auth = hdr(<<"authorization">>, <<"Bearer ", AccessToken/binary>>),
    V = hdr(<<"x-ms-version">>, <<"2021-12-02">>),
    Json = hdr(<<"content-type">>, <<"application/json">>),

    %% -- create db / coll / doc (Cosmos REST POSTs) --
    {201, _, DbBody} = http(Ssl, <<"POST">>, <<"/dbs">>, [Auth, V, Json],
                            [<<"{\"id\":\"">>, Db, <<"\"}">>]),
    assert_contains(<<"\"_rid\"">>, DbBody, cosmos_db_rid_marker),
    {201, _, CollBody} = http(Ssl, <<"POST">>,
                              [<<"/dbs/">>, Db, <<"/colls">>], [Auth, V, Json],
                              [<<"{\"id\":\"">>, Coll, <<"\"}">>]),
    assert_contains(<<"\"_rid\"">>, CollBody, cosmos_coll_rid_marker),
    {201, _, DocBody} = http(Ssl, <<"POST">>,
                             [<<"/dbs/">>, Db, <<"/colls/">>, Coll, <<"/docs">>],
                             [Auth, V, Json],
                             [<<"{\"id\":\"">>, DocId, <<"\",\"v\":42}">>]),
    %% binary-match the wire bytes for id + _etag markers (no JSON lib)
    assert_contains(<<"\"id\":\"">>, DocBody, cosmos_doc_id_marker),
    assert_contains(<<"\"_etag\":\"\\\"">>, DocBody, cosmos_doc_etag_marker),
    assert_contains(DocId, DocBody, cosmos_doc_id_value),

    %% -- read back: same id, same etag byte-for-byte --
    {200, _, ReadBody} = http(Ssl, <<"GET">>,
                              [<<"/dbs/">>, Db, <<"/colls/">>, Coll,
                               <<"/docs/">>, DocId],
                              [Auth, V], <<>>),
    assert_contains(<<"\"v\":42">>, ReadBody, cosmos_read_v42),
    Etag = extract_etag(DocBody),
    assert_contains(Etag, ReadBody, cosmos_read_same_etag),
    io:format("  [leg2] doc create+read OK (id/etag binary-matched)~n"),

    %% -- missing doc: typed 404 (cosmos face) --
    {404, _, _MissBody} = http(Ssl, <<"GET">>,
                               [<<"/dbs/">>, Db, <<"/colls/">>, Coll,
                                <<"/docs/ecourt-missing">>],
                               [Auth, V], <<>>),
    ssl:close(Ssl),
    io:format("  [leg2] missing-doc 404 OK~n"),
    [{"cosmos", "sts+rest", "PASS"}].

%% =============================================================================
%% LEG 3 — Blob XML face raw over 9444
%% =============================================================================
leg_blob(CIo, Uniq) ->
    Cont = CIo,
    Blob = ["ecourt-blob-", Uniq],
    io:format("~n[leg3] Blob raw TLS :9444 container=~s~n", [Cont]),
    Ssl = tls_conn(),
    {_200, _H, TokenBody} = http(Ssl, <<"POST">>,
                                 <<"/dev-tenant/oauth2/v2.0/token">>,
                                 [hdr(<<"content-type">>,
                                      <<"application/x-www-form-urlencoded">>)],
                                 <<"grant_type=client_credentials&client_id=ecourt"
                                   "&client_secret=ecourt&scope=x">>),
    AccessToken = extract_token(TokenBody),
    Auth = hdr(<<"authorization">>, <<"Bearer ", AccessToken/binary>>),
    V = hdr(<<"x-ms-version">>, <<"2021-12-02">>),

    %% -- create container --
    {201, _, <<>>} = http(Ssl, <<"PUT">>, [<<"/ecacct/">>, Cont,
                                            <<"?restype=container">>],
                          [Auth, V], <<>>),
    io:format("  [leg3] container created (201)~n"),

    %% -- PUT blob --
    Payload = <<"ecourt-blob-payload-1">>,
    {201, _, _PutBody} = http(Ssl, <<"PUT">>, [<<"/ecacct/">>, Cont, <<"/">>, Blob],
                              [Auth, V,
                               hdr(<<"x-ms-blob-type">>, <<"BlockBlob">>)],
                              Payload),
    %% -- GET blob: body byte-exact --
    {200, _, Payload} = http(Ssl, <<"GET">>, [<<"/ecacct/">>, Cont, <<"/">>, Blob],
                             [Auth, V], <<>>),
    io:format("  [leg3] PUT+GET byte-exact OK~n"),

    %% -- DELETE blob: 202 --
    {202, _, _DelBody} = http(Ssl, <<"DELETE">>, [<<"/ecacct/">>, Cont, <<"/">>, Blob],
                              [Auth, V], <<>>),

    %% -- GET deleted blob: 404 + StorageError XML envelope + x-ms-error-code --
    {404, H404, Body404} = http(Ssl, <<"GET">>, [<<"/ecacct/">>, Cont, <<"/">>, Blob],
                                [Auth, V], <<>>),
    assert_header_contains(<<"x-ms-error-code">>, <<"BlobNotFound">>, H404),
    %% envelope bytes: <?xml ...<Error><Code>BlobNotFound</Code>...
    assert_contains(<<"<Error>">>, Body404, blob_xml_error_envelope),
    assert_contains(<<"<Code>BlobNotFound</Code>">>, Body404, blob_xml_code_blobnotfound),
    assert_contains(<<"<?xml">>, Body404, blob_xml_prolog),
    io:format("  [leg3] 404 StorageError XML + x-ms-error-code byte-matched~n"),
    ssl:close(Ssl),
    [{"blob", "xml-face", "PASS"}].

%% =============================================================================
%% LEG 4 — APIM plane typed refusals
%% =============================================================================
leg_apim(Uniq) ->
    io:format("~n[leg4] APIM plane raw TLS :9444~n", []),
    Ssl = tls_conn(),
    Probe = [<<"/apim-gw/ecourt-probe-">>, Uniq],
    {Status, _H, Body} = http(Ssl, <<"GET">>, Probe, [], <<>>),
    case Status of
        404 ->
            %% default-off route family: the namespace must answer the typed
            %% 404 envelope, NEVER a blob-account face (lying-400 regression).
            assert_contains(<<"\"error\"">>, Body, apim_error_object),
            assert_contains(<<"\"code\":\"RouteNotFound\"">>, Body, apim_typed_404),
            assert_contains(<<"no APIM gateway is configured">>, Body,
                            apim_typed_404_message),
            io:format("  [leg4] typed 404 RouteNotFound envelope byte-matched~n"),
            ssl:close(Ssl),
            [{"apim", "typed-404", "PASS"},
             {"apim", "429-401-gateway", "SKIP"}];
        429 ->
            %% a gateway IS wired: rate-limit refusals are wire-witnessable
            assert_contains(<<"TooManyRequests">>, Body, apim_429_code),
            {401, _H1, Body401} = bad_jwt_probe(Ssl),
            assert_contains(<<"\"error\"">>, Body401, apim_401_object),
            ssl:close(Ssl),
            [{"apim", "429-refusal", "PASS"},
             {"apim", "401-refusal", "PASS"}];
        200 ->
            %% gateway wired but not rate-limited yet; drive the 401 face
            {401, _H2, Body401} = bad_jwt_probe(Ssl),
            assert_contains(<<"\"error\"">>, Body401, apim_401_object),
            ssl:close(Ssl),
            [{"apim", "echo-gateway", "PASS"},
             {"apim", "401-refusal", "PASS"},
             {"apim", "429-gateway", "SKIP"}];
        Other ->
            erlang:error({fence_violation, {apim_unexpected_status, Other, Body}})
    end.

bad_jwt_probe(Ssl) ->
    http(Ssl, <<"GET">>, <<"/apim-gw/ecourt-probe">>,
         [hdr(<<"authorization">>, <<"Bearer not-a-real-jwt">>)], <<>>).

%% =============================================================================
%% Raw HTTP/1.1 over TLS (no inets/httpc — raw ssl transport)
%% =============================================================================
tls_conn() ->
    {ok, Ssl} = ssl:connect(?HOST, ?TLS_PORT,
                            [binary, {active, false},
                             {verify, verify_peer},
                             {cacertfile, ?CA_FILE},
                             {depth, 3},
                             {customize_hostname_check,
                              [{match_fun,
                                public_key:pkix_verify_hostname_match_fun(https)}]}],
                            ?TIMEOUT),
    Ssl.

http(Ssl, Method, PathIo, Headers, BodyIo) ->
    Path = iolist_to_binary(PathIo),
    Body = iolist_to_binary(BodyIo),
    Req = [Method, <<" ">>, Path, <<" HTTP/1.1\r\nhost: ">>, ?HOST,
           <<":9444\r\nconnection: keep-alive\r\ncontent-length: ">>,
           integer_to_binary(byte_size(Body)),
           [[<<"\r\n">>, N, <<": ">>, V] || {N, V} <- Headers],
           <<"\r\n\r\n">>, Body],
    ok = ssl:send(Ssl, Req),
    read_response(Ssl, <<>>).

read_response(Ssl, Buf) ->
    case binary:split(Buf, <<"\r\n\r\n">>) of
        [_] -> read_response(Ssl, more_tls(Ssl, Buf));
        [HeadRaw, Rest] ->
            {Status, Headers} = parse_head(HeadRaw),
            case content_length(Headers) of
                missing when Status =:= 204 orelse Status =:= 304 ->
                    {Status, Headers, <<>>};
                missing ->
                    %% read to close or chunked; handle identity+close
                    case transfer_encoding(Headers) of
                        chunked -> read_chunked(Ssl, Rest, Headers, Status);
                        identity -> read_to_end(Ssl, Rest, Headers, Status)
                    end;
                CL ->
                    case Rest of
                        <<Body:CL/binary, _/binary>> -> {Status, Headers, Body};
                        _ -> read_to_length(Ssl, Rest, Headers, Status, CL)
                    end
            end
    end.

read_to_length(Ssl, Buf, H, St, CL) ->
    case Buf of
        <<Body:CL/binary, _/binary>> -> {St, H, Body};
        _ -> read_to_length(Ssl, more_tls(Ssl, Buf), H, St, CL)
    end.

read_to_end(Ssl, Buf, H, St) ->
    case more_tls(Ssl, Buf) of
        B -> read_to_end(Ssl, B, H, St)
    end.

read_chunked(Ssl, Buf, H, St) ->
    case Buf of
        <<"0\r\n", _/binary>> -> {St, H, chunks_done};
        _ ->
            case binary:split(Buf, <<"\r\n">>) of
                [SizeHex, Rest] ->
                    Sz = binary_to_integer(SizeHex, 16),
                    case Rest of
                        <<Chunk:Sz/binary, "\r\n", Tail/binary>> when Sz > 0 ->
                            append_chunk(Ssl, Tail, H, St, Chunk);
                        _ when Sz =:= 0 ->
                            read_chunked(Ssl, Rest, H, St);
                        _ ->
                            read_chunked(Ssl, more_tls(Ssl, Buf), H, St)
                    end;
                _ ->
                    read_chunked(Ssl, more_tls(Ssl, Buf), H, St)
            end
    end.

append_chunk(Ssl, Tail, H, St, Chunk) ->
    case read_chunked(Ssl, Tail, H, St) of
        {St, H, chunks_done} -> {St, H, Chunk};
        {St, H, Rest} -> {St, H, <<Chunk/binary, Rest/binary>>}
    end.


more_tls(Ssl, Buf) ->
    case ssl:recv(Ssl, 0, ?TIMEOUT) of
        {ok, Data} -> <<Buf/binary, Data/binary>>;
        {error, R} -> erlang:error({fence_violation, {tls_recv, R}})
    end.

parse_head(HeadRaw) ->
    Lines = binary:split(HeadRaw, <<"\r\n">>, [global]),
    [<<"HTTP/1.1 ", St:3/binary, _/binary>> | HdrLines] = Lines,
    Status = binary_to_integer(St),
    Headers = [begin
                   [N, V] = binary:split(L, <<": ">>),
                   {lower(N), V}
               end || L <- HdrLines],
    {Status, Headers}.

lower(B) -> << <<(if C >= $A, C =< $Z -> C + 32; true -> C end)>> || <<C>> <= B >>.

content_length(Headers) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, V} -> binary_to_integer(V);
        false -> missing
    end.

transfer_encoding(Headers) ->
    case lists:keyfind(<<"transfer-encoding">>, 1, Headers) of
        {_, <<"chunked">>} -> chunked;
        _ -> identity
    end.

hdr(N, V) -> {N, V}.

%% -- byte-fence assertion primitives ------------------------------------------

assert_bin(Expected, Actual, Name) ->
    case Actual of
        Expected -> ok;
        _ -> erlang:error({fence_violation, {Name, expected, Expected,
                                             got, Actual}})
    end.

assert_prefix(Prefix, Bin, Name) ->
    Sz = byte_size(Prefix),
    case Bin of
        <<Prefix:Sz/binary, _/binary>> -> ok;
        _ -> erlang:error({fence_violation, {Name, expected_prefix, Prefix,
                                             got, Bin}})
    end.

assert_contains(Needle0, Haystack0, Name) ->
    Needle = iolist_to_binary(Needle0),
    Haystack = iolist_to_binary(Haystack0),
    case binary:match(Haystack, Needle) of
        nomatch ->
            erlang:error({fence_violation, {Name, needle_missing, Needle,
                                            haystack, Haystack}});
        _ -> ok
    end.

assert_not_contains(Needle, Haystack, Name) ->
    case binary:match(Haystack, Needle) of
        nomatch -> ok;
        _ -> erlang:error({fence_violation, {Name, needle_present, Needle}})
    end.

assert_header_contains(Name, Value, Headers) ->
    case lists:keyfind(Name, 1, Headers) of
        {_, V} -> assert_bin(Value, V, {header_value, Name});
        false -> erlang:error({fence_violation, {header_missing, Name}})
    end.

%% Extract "access_token":"..." via binary match (no JSON lib).
extract_token(Body) ->
    case binary:split(Body, <<"\"access_token\":\"">>) of
        [_, Rest] ->
            [Tok, _] = binary:split(Rest, <<"\"">>),
            Tok;
        _ -> erlang:error({fence_violation, {sts_no_access_token, Body}})
    end.

%% Extract _etag's quoted value: "_etag":"\"abc\"" -> <<"\"abc\"">>
extract_etag(Body) ->
    case binary:split(Body, <<"\"_etag\":\"">>) of
        [_, Rest] ->
            [Inner, _] = binary:split(Rest, <<"\"">>),
            %% Inner = \"...\" (escaped quotes retained)
            Inner;
        _ -> erlang:error({fence_violation, {cosmos_no_etag, Body}})
    end.
