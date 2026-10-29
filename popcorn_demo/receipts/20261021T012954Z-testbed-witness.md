# popcorn_demo testbed witness — ALIVE

- Standing: ALIVE
- Date: 20261021T012954Z
- Host legs exit: 0
- Browser witness exit: 0 (skipped: public/out not cooked)

## Host-side legs (mix run, MIX_BUILD_ROOT=_build-lane7)

```
Compiling 17 files (.ex)
     warning: clauses with the same name and arity (number of arguments) should be grouped together, "defp uint/1" was previously defined (lib/popcorn_demo/live_eh.ex:231)
     │
 239 │   defp uint(v), do: {:uint, v}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:239:8

     warning: clauses with the same name and arity (number of arguments) should be grouped together, "defp str8/1" was previously defined (lib/popcorn_demo/live_eh.ex:232)
     │
 242 │   defp str8(s), do: {:str8, s}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:242:8

     warning: the variable "body_len" is accessed inside size(...) of a bitstring but it was defined outside of the match. You must precede it with the pin operator
     │
 378 │       <<frame_body::binary-size(body_len), rest::binary>> = body
     │                                 ~
     │
     └─ lib/popcorn_demo/live_eh.ex:378:33: PopcornDemo.LiveEh.decode_buf/1

     warning: the variable "size" is accessed inside size(...) of a bitstring but it was defined outside of the match. You must precede it with the pin operator
     │
 401 │     <<list_bytes::binary-size(size - 1), payload::binary>> = list
     │                               ~
     │
     └─ lib/popcorn_demo/live_eh.ex:401:31: PopcornDemo.LiveEh.split_list/1

     warning: the variable "size" is accessed inside size(...) of a bitstring but it was defined outside of the match. You must precede it with the pin operator
     │
 406 │     <<list_bytes::binary-size(size - 4), payload::binary>> = list
     │                               ~
     │
     └─ lib/popcorn_demo/live_eh.ex:406:31: PopcornDemo.LiveEh.split_list/1

     warning: function module_for_file/1 is unused
     │
 156 │   defp module_for_file(path) do
     │        ~
     │
     └─ lib/popcorn_demo/application.ex:156:8: PopcornDemo.Application (module)

     warning: this clause for bool/1 cannot match because a previous clause at line 233 always matches
     │
 237 │   defp bool(v), do: {:bool, v}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:237:8

     warning: this clause for uint/1 cannot match because a previous clause at line 231 always matches
     │
 239 │   defp uint(v), do: {:uint, v}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:239:8

     warning: this clause for str8/1 cannot match because a previous clause at line 232 always matches
     │
 242 │   defp str8(s), do: {:str8, s}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:242:8

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

     warning: this clause of defp slice/1 is never used (or it will always fail/warn when invoked)
     │
 154 │   defp slice(other), do: other |> inspect() |> String.slice(0, 80)
     │        ~
     │
     └─ lib/popcorn_demo/application.ex:154:8: PopcornDemo.Application.slice/1

    warning: the following clause will never match:

        {:skip, reason} ->

    it is expected to match on type:

        dynamic(
          ({:error, {binary(), binary()}} and not {:ok, binary()}) or
            ({:error, {binary(), binary()}} and not {:ok, integer()}) or {:error, {binary(), term()}}
        )

    type warning found at:
    │
 53 │       {:skip, reason} ->
    │       ~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live_rg.ex:53: PopcornDemo.LiveRg.run/0

     warning: the following clause is redundant:

         defp fragment(label, {:error, {step, reason}}) when is_binary(step) and is_binary(reason)

     it has type:

         dynamic(), dynamic({:error, {binary(), binary()}})

     previous clauses have already matched on the following types:

         term(), binary()
         term(), {:ok, binary()}
         term(), {:error, binary()}
         term(), {:skip, binary()}
         term(), {:skip, {term(), binary()}}
         term(), {:error, {term(), binary()}}

     │
 182 │   defp fragment(label, {:error, {step, reason}}) when is_binary(step) and is_binary(reason) do
     │        ~
     │
     └─ lib/popcorn_demo/application.ex:182:8: PopcornDemo.Application.fragment/2

    warning: incompatible types in binary construction:

        <<step::binary, ...>>

    got type:

        dynamic(:endpoints or :fetch or :sts or :subscriptions or :tenants)

    but expected type:

        binary()

    where "step" was given the type:

        # type: dynamic(:endpoints or :fetch or :sts or :subscriptions or :tenants)
        # from: lib/popcorn_demo/live.ex:71:7
        {:fail, step, reason}

    type warning found at:
    │
 71 │       {:fail, step, reason} -> {:fail, step <> ":" <> reason}
    │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live.ex:71: PopcornDemo.Live.walk/1

     warning: the following clause is redundant:

         defp bool(v)

     it has type:

         dynamic()

     previous clauses have already matched on the following types:

         term()

     │
 237 │   defp bool(v), do: {:bool, v}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:237:8: PopcornDemo.LiveEh.bool/1

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
 74 │       {:skip, reason} ->
    │       ~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live_blob.ex:74: PopcornDemo.LiveBlob.run/0

     warning: the following clause is redundant:

         defp uint(v)

     it has type:

         dynamic()

     previous clauses have already matched on the following types:

         term()

     │
 239 │   defp uint(v), do: {:uint, v}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:239:8: PopcornDemo.LiveEh.uint/1

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
 116 │       {:skip, reason} ->
     │       ~~~~~~~~~~~~~~~~~~
     │
     └─ lib/popcorn_demo/live_blob.ex:116: PopcornDemo.LiveBlob.staged_roundtrip/1

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

     warning: the following clause is redundant:

         defp str8(s)

     it has type:

         dynamic()

     previous clauses have already matched on the following types:

         term()

     │
 242 │   defp str8(s), do: {:str8, s}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:242:8: PopcornDemo.LiveEh.str8/1

     warning: this clause of defp normalize_headers/1 is never used (or it will always fail/warn when invoked)
     │
 319 │   defp normalize_headers(_), do: []
     │        ~
     │
     └─ lib/popcorn_demo/live_queue.ex:319:8: PopcornDemo.LiveQueue.normalize_headers/1

     warning: the following clause will never match:

         {:skip, reason} ->

     it is expected to match on type:

         dynamic(
           ({:error, {binary(), binary()}} and not {:ok, binary()}) or
             ({:error, {{binary(), term()}}} and not {:ok, binary()}) or {:error, {binary(), term()}}
         )

     type warning found at:
     │
 452 │           {:skip, reason} -> {:skip, "queue=SKIP(#{reason})"}
     │           ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     │
     └─ lib/popcorn_demo/live_queue.ex:452: PopcornDemo.LiveQueue.with_queue/2

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
 125 │         match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
     │                                ~
     │
     └─ lib/popcorn_demo/live_tls.ex:125:32: PopcornDemo.LiveTls.ssl_opts/1

     warning: :public_key.pem_encode/1 is undefined (module :public_key is not available or is yet to be defined)
     │
 191 │               pem = :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
     │                                 ~
     │
     └─ lib/popcorn_demo/live_certs.ex:191:33: PopcornDemo.LiveCerts.create_cert/1

     warning: this clause of defp normalize_headers/1 is never used (or it will always fail/warn when invoked)
     │
 502 │   defp normalize_headers(_), do: []
     │        ~
     │
     └─ lib/popcorn_demo/live_certs.ex:502:8: PopcornDemo.LiveCerts.normalize_headers/1

     warning: the right-hand side of || will never be executed:

         uri.host || ...

     because the left-hand side always evaluates to:

         binary()

     where "uri" was given the types:

         # type: dynamic(%URI{scheme: binary(), host: binary()})
         # from: lib/popcorn_demo/live_certs.ex:376:23
         %URI{} = uri

         # type: dynamic(%URI{scheme: binary(), host: binary()})
         # from: lib/popcorn_demo/live_certs.ex:376:30
         {:ok, %URI{} = uri} <- loopback_only(url)

         # type: dynamic(%URI{scheme: binary(), host: binary(), port: not nil})
         # from: lib/popcorn_demo/live_certs.ex:377:25
         port_of(uri)

     type warning found at:
     │
 378 │       host = uri.host || "127.0.0.1"
     │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
     │
     └─ lib/popcorn_demo/live_certs.ex:378: PopcornDemo.LiveCerts.tcp_request/1

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

     warning: this clause of defp normalize_headers/1 is never used (or it will always fail/warn when invoked)
     │
 343 │   defp normalize_headers(_), do: []
     │        ~
     │
     └─ lib/popcorn_demo/live_kv.ex:343:8: PopcornDemo.LiveKV.normalize_headers/1

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

     warning: Smalt.Store.list_prefix/2 is undefined (module Smalt.Store is not available or is yet to be defined)
     │
 530 │     subs = Smalt.Store.list_prefix(:smalt_resources, subs_prefix)
     │                        ~
     │
     └─ lib/smalt/sb_rules.ex:530:24: Smalt.SbRules.fan_out/4

     warning: Smalt.Store.list_prefix/2 is undefined (module Smalt.Store is not available or is yet to be defined)
     │
 536 │       rules = Smalt.Store.list_prefix(:smalt_sb_rules, rules_prefix)
     │                           ~
     │
     └─ lib/smalt/sb_rules.ex:536:27: Smalt.SbRules.fan_out/4

     warning: Smalt.Amqp.QueueStore.enqueue/3 is undefined (module Smalt.Amqp.QueueStore is not available or is yet to be defined)
     │
 544 │           Smalt.Amqp.QueueStore.enqueue(queue, msg[:body] || "",
     │                                 ~
     │
     └─ lib/smalt/sb_rules.ex:544:33: Smalt.SbRules.fan_out/4

Generated popcorn_demo app

18:29:55.506 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)

18:29:55.527 [error] beam/beam_load.c(184): Error loading module 'Elixir.PopcornDemo.LiveCAS':
  module name in object code is 'Elixir.PopcornDemo.LiveCas'



18:29:55.543 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)

18:29:55.770 [info] popcorn_demo TLS leg: tls=OK(https-twin,endpoints,tenants,sts,subscriptions=1) via ca=OK

18:29:55.966 [info] popcorn_demo TLS leg: tls=OK(https-twin,endpoints,tenants,sts,subscriptions=1) via ca=OK
HOST_RECEIPT: blob=OK(popcorn/l3rb1792546195502-521/receipt.txt:61-roundtrip); cas=OK(insert,etag,fresh-200,stale-412,delete-204,gone-404); certs=OK(popcorn-cert:purge); containers=OK(2-listed); eg=OK(pegl31792546195729:bearer-topic-publish-readback-kd101refusal); eh=OK(popcorn-eh/0:w27-evt-1792546195737-roundtrip-50-events-scanned); kv=OK(popcorn-secret:30-bytes-lifecycle); lifecycle=OK(create:get:delete:get404:l5k1792546195754-7109); matrix=OK(popcorn/smoke:3-matched); mcp=OK(32-tools); param=OK(1-matched-params); policy=OK(5-faces-1-defs); queue=OK(popcorn-q:74-bytes-roundtrip); rg=OK(5-rows); rules=OK(popcorn-r:1-listed); tags=OK(2-tags-roundtrip); tls=OK(https-twin,endpoints,tenants,sts,subscriptions=1)
```

## Browser witness (node scripts/browser_smoke.mjs)

```
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:58642
[console] Failed to load resource: the server responded with a status of 404 (Not Found)
[console] [Popcorn] stdout: [22m
18:29:56.830 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)[0m

[console] [Popcorn] stdout: [22m
18:29:56.864 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)[0m

[console] Failed to load resource: the server responded with a status of 409 (Conflict)
[console] [Popcorn] stdout: [22m
18:29:56.905 [info] popcorn_demo TLS leg: tls=SKIP(ca-missing:/Users/sac/smalt/.smalt/tls/ca-cert.pem) via ca=not-ok[0m

[console] Failed to load resource: the server responded with a status of 409 (Conflict)
[console] Failed to load resource: the server responded with a status of 409 (Conflict)
[console] BROWSER_LEG_ROW {"lane":"browser-legs","boot_ms":403.01,"legs_rendered":20,"ts":"2026-10-21T01:29:57.014Z","poll_deltas_ms":[203.2,199.73]}
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); blob=OK(popcorn/l3rb1792546196881-110/receipt.txt:61-roundtrip); certs=SKIP(data-plane-8443-unreachable::eprotonosupport); containers=SKIP(wasm-transport:no match of right hand side value:

    {:error, {:inets, {~c"no such file or di); eg=SKIP(wasm-transport:http); eh=SKIP(eh-plane-down(5673-connect-:eprotonosupport); run 9>&- just substrate-up); kv=SKIP(wasm-transport:no with clause matching:

    {:error, {:tcp_connect, :eprotonosupport}}
); lifecycle=SKIP(wasm-transport:no match of right hand side value:

    {:error, {:inets, {~c"no such file or di); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:3-matched); mcp=SKIP(wasm-transport:function :httpc.request/4 is undefined (module :httpc is not available)); param=OK(1-matched-params); policy=SKIP(wasm-transport:function :httpc.request/4 is undefined (module :httpc is not available)); queue=SKIP(wasm-transport:no with clause matching:

    {:error, {:tcp_connect, :eprotonosupport}}
); rg=SKIP(wasm-transport:function :httpc.request/4 is undefined (module :httpc is not available)); rules=SKIP(wasm-transport:no match of right hand side value:

    {:error, {:inets, {~c"no such file or di); tags=SKIP(wasm-transport:no match of right hand side value:

    {:error, {:inets, {~c"no such file or di); tls=SKIP(ca-missing:/Users/sac/smalt/.smalt/tls/ca-cert.pem)
```
