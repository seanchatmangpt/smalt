%% BENCH-3 court_bench_cosmos - bulk CAS point ops, raw TLS :9444, pure Erlang.
%% ECOURT pattern: STS form POST -> db/coll/doc create -> N=10000 point-reads
%% in an isolated worker process. Emits tmp/bench/court_bench_cosmos.jsonl.
%% Fence: T43 wire point-read p99 0.813-1.04 ms; parity within 2x => p99 <= 2.08 ms.
%% Substrate down => loud SKIP exit 3; never restarts anything.
-module(bench_cosmos_cas).

-export([main/1, main/0]).

-define(HOST, "127.0.0.1").
-define(TLS_PORT, 9444).
-define(TIMEOUT, 15000).
-define(N, 10000).
-define(CA_FILE, "/Users/sac/smalt/.smalt/tls/ca-cert.pem").
-define(OUT, "/Users/sac/smalt/tmp/bench/court_bench_cosmos.jsonl").

main(_) -> main().

main() ->
    application:ensure_all_started(ssl),
    application:ensure_all_started(crypto),
    Uniq = integer_to_list(erlang:unique_integer([positive])),
    case preflight() of
        skip ->
            io:format("[BENCH-3-SKIP] substrate :9444 not LISTENING - lane never restarts it. 'just substrate-up' then rerun.~n"),
            halt(3);
        {ok, Ssl} ->
            {Token, Db, Coll, Doc} = setup(Ssl, Uniq),
            ssl:close(Ssl),
            Parent = self(),
            Worker = erlang:spawn_link(fun() -> worker(Parent, Token, Db, Coll, Doc) end),
            R0 = reds(Worker),
            T0 = erlang:monotonic_time(millisecond),
            Worker ! go,
            Rows = receive {bench_result, R} -> R
                   after 120000 -> erlang:error(bench_worker_timeout) end,
            T1 = erlang:monotonic_time(millisecond),
            R1 = reds(Worker),
            Wall = T1 - T0,
            Dr = R1 - R0,
            io:format("~n=== BENCH-3 court_bench_cosmos ===~n"),
            lists:foreach(fun print_row/1, Rows),
            io:format("worker reductions: ~p (~p/op), aggregate wall ~p ms~n",
                      [Dr, Dr div ?N, Wall]),
            emit_rows(Rows, Dr, Wall),
            fence(Rows)
    end.

reds(P) ->
    {reductions, R} = erlang:process_info(P, reductions),
    R.

preflight() ->
    Lsof = os:cmd("lsof -nP -iTCP:9444 -sTCP:LISTEN 2>/dev/null"),
    case Lsof =/= [] of
        false -> skip;
        true ->
            try tls_conn() of
                S -> {ok, S}
            catch _:_ -> skip
            end
    end.

%% STS bearer + db/coll/doc create on the setup connection.
setup(Ssl, Uniq) ->
    Form = <<"grant_type=client_credentials&client_id=bench3"
             "&client_secret=bench3&scope=https://cosmos.azure.com/.default">>,
    {200, _, TokenBody} = http(Ssl, <<"POST">>,
                               <<"/dev-tenant/oauth2/v2.0/token">>,
                               [hdr(<<"content-type">>,
                                    <<"application/x-www-form-urlencoded">>)],
                               Form),
    Token = extract_token(TokenBody),
    true = byte_size(Token) > 100 orelse erlang:error({sts_token_too_short, TokenBody}),
    Auth = hdr(<<"authorization">>, <<"Bearer ", Token/binary>>),
    V = hdr(<<"x-ms-version">>, <<"2021-12-02">>),
    J = hdr(<<"content-type">>, <<"application/json">>),
    Db = <<"bench3-d-", (list_to_binary(Uniq))/binary>>,
    Coll = <<"bench3-c-", (list_to_binary(Uniq))/binary>>,
    Doc = <<"bench3-doc-", (list_to_binary(Uniq))/binary>>,
    {201, _, _} = http(Ssl, <<"POST">>, <<"/dbs">>, [Auth, V, J],
                       [<<"{\"id\":\"">>, Db, <<"\"}">>]),
    {201, _, _} = http(Ssl, <<"POST">>, [<<"/dbs/">>, Db, <<"/colls">>],
                       [Auth, V, J], [<<"{\"id\":\"">>, Coll, <<"\"}">>]),
    {201, _, _} = http(Ssl, <<"POST">>,
                       [<<"/dbs/">>, Db, <<"/colls/">>, Coll, <<"/docs">>],
                       [Auth, V, J],
                       [<<"{\"id\":\"">>, Doc, <<"\",\"v\":42}">>]),
    {Token, Db, Coll, Doc}.

worker(Parent, Token, Db, Coll, Doc) ->
    Ssl = tls_conn(),
    Auth = hdr(<<"authorization">>, <<"Bearer ", Token/binary>>),
    V = hdr(<<"x-ms-version">>, <<"2021-12-02">>),
    Path = [<<"/dbs/">>, Db, <<"/colls/">>, Coll, <<"/docs/">>, Doc],
    receive go -> ok end,
    {Lats, Errors} = loop(Ssl, <<"GET">>, Path, [Auth, V], ?N, [], 0),
    Rows = [{<<"point_read">>, ?N, mean_ops(Lats), pctl(Lats, 50),
             pctl(Lats, 95), pctl(Lats, 99), Errors}],
    Parent ! {bench_result, Rows},
    ssl:close(Ssl).

loop(_Ssl, _M, _P, _H, 0, Lats, Errs) ->
    {lists:reverse(Lats), Errs};
loop(Ssl, M, P, H, K, Lats, Errs) ->
    T0 = erlang:monotonic_time(microsecond),
    case catch http(Ssl, M, P, H, <<>>) of
        {200, _, _} ->
            T1 = erlang:monotonic_time(microsecond),
            loop(Ssl, M, P, H, K - 1, [T1 - T0 | Lats], Errs);
        _Other ->
            T1 = erlang:monotonic_time(microsecond),
            loop(Ssl, M, P, H, K - 1, [T1 - T0 | Lats], Errs + 1)
    end.

mean_ops(Lats) ->
    N = length(Lats),
    case N of
        0 -> 0.0;
        _ -> WallUs = lists:sum(Lats),
             N * 1.0e6 / WallUs
    end.

pctl(Lats, P) ->
    case Lats of
        [] -> 0.0;
        _ ->
            S = lists:sort(Lats),
            Idx = max(1, erlang:ceil(P * length(S) / 100)),
            lists:nth(Idx, S) / 1000.0
    end.

%% -- emit JSONL rows (machine spec injected via BENCH_MACHINE env) --
emit_rows(Rows, Reds, Wall) ->
    Machine = os:getenv("BENCH_MACHINE", "{}"),
    File = ?OUT,
    ok = filelib:ensure_dir(File),
    {ok, Fh} = file:open(File, [append]),
    lists:foreach(
      fun({Op, N, Ops, P50, P95, P99, Errors}) ->
          Row = io_lib:format(
                  "{\"lane\":\"court-bench-cosmos\",\"surface\":\"cosmos-tls-9444\",\"op\":\"~s\",\"n\":~p,\"ops_per_sec\":~.1f,\"p50_ms\":~.3f,\"p95_ms\":~.3f,\"p99_ms\":~.3f,\"errors\":~p,\"machine\":~s,\"worker_reductions\":~p,\"wall_ms\":~p}~n",
                  [Op, N, Ops, P50, P95, P99, Errors, Machine, Reds, Wall]),
          io:put_chars(Fh, Row)
      end, Rows),
    file:close(Fh).

print_row({Op, N, Ops, P50, P95, P99, Errors}) ->
    io:format("  ~s n=~p ops/s=~.1f p50=~.3fms p95=~.3fms p99=~.3fms errors=~p~n",
              [Op, N, Ops, P50, P95, P99, Errors]).

fence(Rows) ->
    Fence = 2.08,   %% 2x T43 wire point-read p99 1.04 ms
    Pass = [P99 || {_, _, _, _, _, P99, 0} <- Rows, P99 =< Fence],
    case Pass of
        [] ->
            io:format("FENCE p99 <= ~.2f ms (2x T43 1.04 ms): FAIL~n", [Fence]),
            halt(1);
        _ ->
            io:format("FENCE p99 <= ~.2f ms (2x T43 1.04 ms): PASS~n", [Fence])
    end.

%% -- raw HTTP/1.1 over TLS (ECOURT pattern, no httpc) --
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
                    read_to_close(Ssl, Rest, Status, Headers);
                CL ->
                    need(Ssl, Rest, CL, Status, Headers)
            end
    end.

read_to_close(Ssl, Buf, Status, Headers) ->
    case headers_contain(Headers, <<"close">>) of
        true -> read_to_eof(Ssl, Buf, Status, Headers);
        false -> read_to_eof(Ssl, Buf, Status, Headers)
    end.

read_to_eof(Ssl, Buf, Status, Headers) ->
    {ok, Data} = ssl:recv(Ssl, 0, ?TIMEOUT),
    read_to_eof(Ssl, <<Buf/binary, Data/binary>>, Status, Headers).

need(Ssl, Buf, CL, Status, Headers) when byte_size(Buf) >= CL ->
    <<Body:CL/binary, _/binary>> = Buf,
    {Status, Headers, Body};
need(Ssl, Buf, CL, Status, Headers) ->
    need(Ssl, more_tls(Ssl, Buf), CL, Status, Headers).

more_tls(Ssl, Buf) ->
    {ok, Data} = ssl:recv(Ssl, 0, ?TIMEOUT),
    <<Buf/binary, Data/binary>>.

parse_head(HeadRaw) ->
    [StatusLine | Hdrs] = binary:split(HeadRaw, <<"\r\n">>, [global]),
    [_Proto, StatusBin | _] = binary:split(StatusLine, <<" ">>, [global]),
    Status = binary_to_integer(StatusBin),
    {Status, [begin [N, V] = binary:split(H, <<": ">>), {lower(N), V} end
              || H <- Hdrs]}.

lower(B) -> list_to_binary(string:lowercase(binary_to_list(B))).

headers_contain(Headers, Needle) ->
    lists:any(fun({_, V}) -> binary:match(V, Needle) =/= nomatch end, Headers).

content_length(Headers) ->
    case lists:keyfind(<<"content-length">>, 1, Headers) of
        {_, V} -> binary_to_integer(V);
        false -> missing
    end.

extract_token(Body) ->
    [_, Rest] = binary:split(Body, <<"\"access_token\":\"">>),
    hd(binary:split(Rest, <<"\"">>)).

hdr(Name, Value) -> {Name, Value}.
