# popcorn_demo testbed witness — SUSPECT

- Standing: SUSPECT
- Date: 20261020T230052Z
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
===> Failed to restore /Users/sac/smalt/popcorn_demo/deps/brotli/_build/prod/lib/.rebar3/rebar_compiler_erl/source.dag file. Discarding it.

===> Analyzing applications...
===> Compiling brotli
==> popcorn
Compiling 20 files (.ex)
Generated popcorn app
==> popcorn_demo
Compiling 9 files (.ex)
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

    warning: incompatible types in binary construction:

        <<step::binary, ...>>

    got type:

        dynamic(:endpoints or :fetch or :sts or :subscriptions or :tenants)

    but expected type:

        binary()

    where "step" was given the type:

        # type: dynamic(:endpoints or :fetch or :sts or :subscriptions or :tenants)
        # from: lib/popcorn_demo/live.ex:52:7
        {:fail, step, reason}

    type warning found at:
    │
 52 │       {:fail, step, reason} -> {:fail, step <> ":" <> reason}
    │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live.ex:52: PopcornDemo.Live.walk/1

    warning: the following clause will never match:

        {:skip, reason} ->

    it is expected to match on type:

        dynamic(
          ({:error, {:step, binary(), binary()}} and not {:ok, :ready}) or
            ({:error, {:step, binary(), binary()}} and not {:ok, binary()}) or
            ({:error, {:step, binary(), binary()}} and
               not {:ok,
                %{body: term(), headers: term(), status: integer()} or %{body: term(), status: integer()} or
                  integer()}) or
            ({:error, {:step, binary(), term()}} and
               not {:ok,
                %{body: term(), headers: term(), status: integer()} or %{body: term(), status: integer()} or
                  integer()}) or {:error, {:step, binary(), term()}}
        )

    type warning found at:
    │
 53 │       {:skip, reason} -> {:skip, "blob=SKIP(#{reason})"}
    │       ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    │
    └─ lib/popcorn_demo/live_blob.ex:53: PopcornDemo.LiveBlob.run/0

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

    warning: the following clause is redundant:

        {:error, other} ->

    previous clauses have already matched on the following types:

        {:error, {:step, binary(), term()}}

    where "other" was given the type:

        # type: dynamic({:step, binary(), term()})
        # from: lib/popcorn_demo/live_blob.ex
        {:error, other}

    type warning found at:
    │
 55 │       {:error, other} -> {:error, "blob=FAIL(unknown:#{fmt(other)})"}
    │                       ~
    │
    └─ lib/popcorn_demo/live_blob.ex:55:23: PopcornDemo.LiveBlob.run/0

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
         # from: lib/popcorn_demo/live_blob.ex:180:7
         other

     type warning found at:
     │
 180 │       other -> {:error, {:fetch_unexpected, other}}
     │             ~
     │
     └─ lib/popcorn_demo/live_blob.ex:180:13: PopcornDemo.LiveBlob.fetch_request/1

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

16:00:54.750 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)

16:00:54.757 [info] popcorn_demo live leg: live=SKIP(substrate-down)
[SKIP] matrix missing-module (lane in flight)

16:00:54.758 [info] popcorn_demo live leg: live=SKIP(substrate-down)
HOST_RECEIPT: live=SKIP(substrate-down); matrix=SKIP(missing-module); blob=FAIL(health::timeout)
```

## Browser witness (node scripts/browser_smoke.mjs)

```
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:58270
[console] Failed to load resource: the server responded with a status of 404 (Not Found)
[console] [Popcorn] stdout: [22m
16:01:25.654 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)[0m

[console] [Popcorn] stdout: [22m
16:01:25.680 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)[0m

SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); live=OK(endpoints,tenants,sts,subscriptions=1)
```
