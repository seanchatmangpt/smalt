# popcorn_demo testbed witness — PARTIAL_ALIVE

- Standing: PARTIAL_ALIVE
- Date: 20261021T005523Z
- Host legs exit: 0
- Browser witness exit: 0 (skipped: public/out not cooked)

## Host-side legs (mix run, MIX_BUILD_ROOT=_build-lane7)

```
==> file_system
Compiling 7 files (.ex)
Generated file_system app
==> jason
Compiling 10 files (.ex)
Generated jason app
==> popcorn_demo
make: Nothing to be done for `lib'.
===> Analyzing applications...
===> Compiling brotli
==> popcorn
Compiling 20 files (.ex)
Generated popcorn app
==> popcorn_demo
Compiling 16 files (.ex)
    warning: the following clause cannot match because the previous clauses already matched all possible values:

        other ->

    it attempts to match on the result of:

        Popcorn.Fetch.request(req)

    which has the already matched type:

        dynamic(
          ({:error or :ok, term()} and not {:ok, term()}) or
            {:error, :timeout or {:bridge or :fetch, term()}} or
            {:ok, %{body: term(), headers: term(), status: term()}}
        )

    where "other" was given the type:

        # type: dynamic(
          ({:error or :ok, term()} and not {:ok, term()}) or
            {:error, :timeout or {:bridge or :fetch, term()}} or
            {:ok, %{body: term(), headers: term(), status: term()}}
        )
        # from: lib/popcorn_demo/transport.ex:38:9
        other

    type warning found at:
    │
 38 │         other -> {:error, {:fetch_unexpected, other}}
    │               ~
    │
    └─ lib/popcorn_demo/transport.ex:38:15: PopcornDemo.Transport.Fetch.request/1

    warning: the following clause will never match:

        {:skip, reason} ->

    it is expected to match on type:

        dynamic(
          ({:error, {:tcp_refused, binary()}} and not {:ok, :ready} and
             not {:ok, %{..., status: integer()}} and not {:ok, %URI{scheme: binary(), host: binary()}}) or
            ({:error, term()} and not {:ok, :ready} and not {:ok, %{..., status: integer()}}) or
            ({:error, {:tcp_parse, binary()}} and not {:ok, :ready}) or
            ({:error, {binary(), binary()}} and not {:ok, :ready}) or
            ({:error, {binary(), binary()}} and not {:ok, binary()}) or
            ({:error, {binary(), term()}} and not {:ok, binary()})
        )

    type warning found at:
    │
 53 │       {:skip, reason} ->
    │       ~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live_kv.ex:53: PopcornDemo.LiveKV.run/0

    warning: incompatible types in binary construction:

        <<step::binary, ...>>

    got type:

        dynamic(:endpoints or :fetch or :sts or :subscriptions or :tenants)

    but expected type:

        binary()

    where "step" was given the type:

        # type: dynamic(:endpoints or :fetch or :sts or :subscriptions or :tenants)
        # from: lib/popcorn_demo/live.ex:80:7
        {:fail, step, reason}

    type warning found at:
    │
 80 │       {:fail, step, reason} -> {:fail, step <> ":" <> reason}
    │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live.ex:80: PopcornDemo.Live.walk/1

    warning: the following clause will never match:

        {:skip, reason} ->

    it is expected to match on type:

        dynamic(
          ({:error, :timeout or {:bridge or :fetch, term()}} and not {:ok, :ready} and
             not {:ok, %{..., body: term(), status: term()}} and not {:ok, %{..., status: term()}}) or
            ({:error, term()} and not {:ok, :ready} and not {:ok, %{..., status: term()}} and
               not {:ok, %URI{scheme: binary(), host: binary()}}) or
            ({:error, term()} and not {:ok, :ready} and not {:ok, term()} and
               not {:ok, %{..., status: term()}}) or
            ({:error, {:fetch_unexpected, term()}} and not {:ok, :ready} and
               not {:ok, %{..., status: term()}} and not {:ok, %URI{scheme: binary(), host: binary()}}) or
            ({:error, {:httpc, term()}} and not {:ok, :ready} and not {:ok, %{..., status: term()}} and
               not {:ok, %URI{scheme: binary(), host: binary()}}) or
            ({:error, :popcorn_fetch_unavailable} and not {:ok, :ready} and
               not {:ok, %{..., status: term()}}) or
            ({:error, {:fetch_unexpected, term()}} and not {:ok, :ready} and
               not {:ok, %{..., status: term()}}) or
            ({:error, {:httpc, term()}} and not {:ok, :ready} and not {:ok, %{..., status: term()}}) or
            ({:error, {:httpc_refused, binary()}} and not {:ok, :ready} and
               not {:ok, %{..., status: term()}}) or
            ({:error, {binary(), binary()}} and not {:ok, :ready}) or
            ({:error, {binary(), binary()}} and not {:ok, binary()}) or
            ({:error, {binary(), binary()}} and
               not {:ok,
                %{body: term(), headers: term(), status: term()} or %{body: term(), status: term()} or
                  integer()}) or
            ({:error, {term(), binary()}} and
               not {:ok,
                %{body: term(), headers: term(), status: term()} or %{body: term(), status: term()} or
                  integer()}) or ({:error, {{binary(), term()}}} and not {:ok, binary()}) or
            {:error, {term(), term()}}
        )

    type warning found at:
    │
 69 │       {:skip, reason} ->
    │       ~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live_blob.ex:69: PopcornDemo.LiveBlob.run/0

    warning: the following clause will never match:

        {:error, code} ->

    it is expected to match on type:

        dynamic(
          ({:error, :invalid_action, term()} and not {:ok, {:sql_ast, term()}}) or
            ({:error, :invalid_filter, term()} and not {:ok, {:sql_ast, term()}}) or
            ({:ok,
              {:correlation,
               %{..., __struct__: atom()} or nil or empty_list() or non_empty_list(term(), term()) or
                 non_struct_map()} or {:sql_ast, term()} or {true, nil}} and not {:ok, {:sql_ast, term()}})
        )

    type warning found at:
    │
 84 │       {:error, code} -> fail("sb_rule", inspect(code))
    │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/smoke.ex:84: PopcornDemo.Smoke.sb_rule/0

    warning: the following clause will never match:

        {:skip, reason} ->

    it is expected to match on type:

        dynamic(
          ({:error, {:tcp_refused, binary()}} and not {:ok, :ready} and
             not {:ok, %{..., status: integer()}} and not {:ok, %URI{scheme: binary(), host: binary()}}) or
            ({:error, term()} and not {:ok, :ready} and not {:ok, %{..., status: integer()}}) or
            ({:error, {:tcp_parse, binary()}} and not {:ok, :ready}) or
            ({:error, {binary(), binary()}} and
               not {:ok, %{..., id: term(), n: integer(), popreceipt: term()}}) or
            ({:error, {binary(), binary()}} and not {:ok, :ready}) or
            ({:error, {binary(), binary()}} and not {:ok, binary()}) or
            ({:error, {binary(), term()}} and
               not {:ok, %{..., id: term(), n: integer(), popreceipt: term()}}) or
            ({:error, {term(), binary()}} and
               not {:ok, %{..., id: term(), n: integer(), popreceipt: term()}}) or
            ({:error, {{binary(), term()}}} and not {:ok, binary()}) or
            ({:ok, %{body: term(), status: integer()}} and
               not {:ok, %{..., id: term(), n: integer(), popreceipt: term()}}) or
            {:error, {term(), term()}}
        )

    type warning found at:
    │
 57 │       {:skip, reason} ->
    │       ~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live_queue.ex:57: PopcornDemo.LiveQueue.run/0

     warning: this clause of defp normalize_headers/1 is never used (or it will always fail/warn when invoked)
     │
 343 │   defp normalize_headers(_), do: []
     │        ~
     │
     └─ lib/popcorn_demo/live_kv.ex:343:8: PopcornDemo.LiveKV.normalize_headers/1

     warning: this clause of defp normalize_headers/1 is never used (or it will always fail/warn when invoked)
     │
 319 │   defp normalize_headers(_), do: []
     │        ~
     │
     └─ lib/popcorn_demo/live_queue.ex:319:8: PopcornDemo.LiveQueue.normalize_headers/1

     warning: the right-hand side of || will never be executed:

         uri.host || ...

     because the left-hand side always evaluates to:

         binary()

     where "uri" was given the types:

         # type: dynamic(%URI{scheme: binary(), host: binary()})
         # from: lib/popcorn_demo/live_kv.ex:221:23
         %URI{} = uri

         # type: dynamic(%URI{scheme: binary(), host: binary()})
         # from: lib/popcorn_demo/live_kv.ex:221:30
         {:ok, %URI{} = uri} <- loopback_only(url)

         # type: dynamic(%URI{scheme: binary(), host: binary(), port: not nil})
         # from: lib/popcorn_demo/live_kv.ex:222:25
         port_of(uri)

     type warning found at:
     │
 223 │       host = uri.host || "127.0.0.1"
     │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     │
     └─ lib/popcorn_demo/live_kv.ex:223: PopcornDemo.LiveKV.tcp_request/1

     warning: the right-hand side of || will never be executed:

         uri.host || ...

     because the left-hand side always evaluates to:

         binary()

     where "uri" was given the types:

         # type: dynamic(%URI{scheme: binary(), host: binary()})
         # from: lib/popcorn_demo/live_queue.ex:218:23
         %URI{} = uri

         # type: dynamic(%URI{scheme: binary(), host: binary()})
         # from: lib/popcorn_demo/live_queue.ex:218:30
         {:ok, %URI{} = uri} <- loopback_only(url)

         # type: dynamic(%URI{scheme: binary(), host: binary(), port: not nil})
         # from: lib/popcorn_demo/live_queue.ex:219:25
         port_of(uri)

     type warning found at:
     │
 220 │       host = uri.host || "127.0.0.1"
     │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     │
     └─ lib/popcorn_demo/live_queue.ex:220: PopcornDemo.LiveQueue.tcp_request/1

     warning: :public_key.pkix_verify_hostname_match_fun/1 is undefined (module :public_key is not available or is yet to be defined)
     │
 118 │         match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
     │                                ~
     │
     └─ lib/popcorn_demo/live_tls.ex:118:32: PopcornDemo.LiveTls.ssl_opts/1

    warning: Plug.Test.conn/3 is undefined (module Plug.Test is not available or is yet to be defined)
    │
 51 │       Plug.Test.conn(method, path, body)
    │                 ~
    │
    └─ lib/smalt/runtime_contracts/support.ex:51:17: Smalt.RuntimeContracts.Support.dispatch/4

    warning: Plug.Conn.put_req_header/3 is undefined (module Plug.Conn is not available or is yet to be defined)
    │
 55 │         Plug.Conn.put_req_header(acc, String.downcase(to_string(k)), to_string(v))
    │                   ~
    │
    └─ lib/smalt/runtime_contracts/support.ex:55:19: Smalt.RuntimeContracts.Support.dispatch/4

    warning: Smalt.Store.get/2 is undefined (module Smalt.Store is not available or is yet to be defined)
    │
 51 │   def get_rule(store, key), do: Smalt.Store.get(store, key)
    │                                             ~
    │
    └─ lib/smalt/sb_rules.ex:51:45: Smalt.SbRules.get_rule/2

    warning: Smalt.Store.put/3 is undefined (module Smalt.Store is not available or is yet to be defined)
    │
 53 │   def put_rule(store, key, record), do: Smalt.Store.put(store, key, record)
    │                                                     ~
    │
    └─ lib/smalt/sb_rules.ex:53:53: Smalt.SbRules.put_rule/3

    warning: Smalt.Store.delete/2 is undefined (module Smalt.Store is not available or is yet to be defined)
    │
 55 │   def delete_rule(store, key), do: Smalt.Store.delete(store, key)
    │                                                ~
    │
    └─ lib/smalt/sb_rules.ex:55:48: Smalt.SbRules.delete_rule/2

    warning: Smalt.Store.list_prefix/2 is undefined (module Smalt.Store is not available or is yet to be defined)
    │
 58 │   def list_rules(store, prefix), do: Smalt.Store.list_prefix(store, prefix)
    │                                                  ~
    │
    └─ lib/smalt/sb_rules.ex:58:50: Smalt.SbRules.list_rules/2
    └─ lib/smalt/sb_rules.ex:530:24: Smalt.SbRules.fan_out/4
    └─ lib/smalt/sb_rules.ex:536:27: Smalt.SbRules.fan_out/4

     warning: Smalt.Amqp.QueueStore.enqueue/3 is undefined (module Smalt.Amqp.QueueStore is not available or is yet to be defined)
     │
 544 │           Smalt.Amqp.QueueStore.enqueue(queue, msg[:body] || "",
     │                                 ~
     │
     └─ lib/smalt/sb_rules.ex:544:33: Smalt.SbRules.fan_out/4

Generated popcorn_demo app

17:55:26.282 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)

17:55:26.316 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)
[SKIP] containers raised: errors were found at the given arguments:

  * 2nd argument: not a tuple

[SKIP] kv missing-module (lane in flight)

17:55:26.431 [error] beam/beam_load.c(184): Error loading module 'Elixir.PopcornDemo.LiveKv':
  module name in object code is 'Elixir.PopcornDemo.LiveKV'



17:55:26.692 [info] popcorn_demo TLS leg: tls=OK(https-twin,endpoints,tenants,sts,subscriptions=1) via ca=OK
HOST_RECEIPT: live=OK(blob=OK(popcorn/l3rb1792544126281/receipt.txt:61-roundtrip)); containers=SKIP(raised:errors were found at the given arguments:

  * 2nd argument: not a tuple
); kv=SKIP(missing-module); live=OK(matrix=OK(popcorn/smoke:1-matched)); live=OK(queue=OK(popcorn-q:74-bytes-roundtrip)); live=OK(rules=OK(popcorn-r:1-listed)); tls=OK(https-twin,endpoints,tenants,sts,subscriptions=1)
HOST_RECEIPT: live=OK(blob=OK(popcorn/l3rb1792544126281/receipt.txt:61-roundtrip)); containers=SKIP(raised:errors were found at the given arguments:

  * 2nd argument: not a tuple
); kv=SKIP(missing-module); live=OK(matrix=OK(popcorn/smoke:1-matched)); live=OK(queue=OK(popcorn-q:74-bytes-roundtrip)); live=OK(rules=OK(popcorn-r:1-listed)); tls=OK(https-twin,endpoints,tenants,sts,subscriptions=1)
```

## Browser witness (node scripts/browser_smoke.mjs)

```
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:49186
[console] Failed to load resource: the server responded with a status of 404 (Not Found)
[console] [Popcorn] stdout: [22m
17:55:27.683 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)[0m

[console] [Popcorn] stdout: [22m
17:55:27.710 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)[0m

[console] Failed to load resource: the server responded with a status of 409 (Conflict)
[console] Access to fetch at 'http://127.0.0.1:8443/popcorn/l3rb1792544127725?restype=container' from origin 'http://127.0.0.1:49186' has been blocked by CORS policy: No 'Access-Control-Allow-Origin' header is present on the requested resource.
[console] Failed to load resource: net::ERR_FAILED
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); blob=SKIP(cors-preflight-403:create-container); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:1-matched)
```
