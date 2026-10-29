# popcorn_demo testbed witness — SUSPECT

- Standing: SUSPECT
- Date: 20261021T011021Z
- Host legs exit: 1
- Browser witness exit: 0 (skipped: public/out not cooked)

## Host-side legs (mix run, MIX_BUILD_ROOT=_build-lane7)

```
Compiling 13 files (.ex)
     warning: clauses with the same name and arity (number of arguments) should be grouped together, "defp uint/1" was previously defined (lib/popcorn_demo/live_eh.ex:228)
     │
 236 │   defp uint(v), do: {:uint, v}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:236:8

     warning: clauses with the same name and arity (number of arguments) should be grouped together, "defp str8/1" was previously defined (lib/popcorn_demo/live_eh.ex:229)
     │
 238 │   defp str8(s), do: {:str8, s}
     │        ~
     │
     └─ lib/popcorn_demo/live_eh.ex:238:8

     warning: the variable "body_len" is accessed inside size(...) of a bitstring but it was defined outside of the match. You must precede it with the pin operator
     │
 345 │       <<frame_body::binary-size(body_len), rest::binary>> = body
     │                                 ~
     │
     └─ lib/popcorn_demo/live_eh.ex:345:33: PopcornDemo.LiveEh.decode_buf/1

     warning: the variable "size" is accessed inside size(...) of a bitstring but it was defined outside of the match. You must precede it with the pin operator
     │
 364 │     <<list_bytes::binary-size(size - 1), payload::binary>> = list
     │                               ~
     │
     └─ lib/popcorn_demo/live_eh.ex:364:31: PopcornDemo.LiveEh.split_list/1

     warning: the variable "size" is accessed inside size(...) of a bitstring but it was defined outside of the match. You must precede it with the pin operator
     │
 369 │     <<list_bytes::binary-size(size - 4), payload::binary>> = list
     │                               ~
     │
     └─ lib/popcorn_demo/live_eh.ex:369:31: PopcornDemo.LiveEh.split_list/1

     error: cyclic variable definition in patterns:

     [{:ok, %{status: s, body: %{"name" => _}} = res} = res]

     the variable "res" depends on itself through the pattern
     │
 192 │          {:ok, %{status: s, body: %{"name" => _}} = res} = res when s in [200] <-
     │                                                                                ^
     │
     └─ lib/popcorn_demo/live_tags.ex:192:80: PopcornDemo.LiveTags.fetch_tagged_app/0


== Compilation error in file lib/popcorn_demo/live_tags.ex ==
** (CompileError) lib/popcorn_demo/live_tags.ex: cannot compile module PopcornDemo.LiveTags (errors have been logged)
    (stdlib 7.2) maps.erl:894: :maps.fold_1/4
    (stdlib 7.2) lists.erl:2673: :lists.mapfoldl_1/3
    (stdlib 7.2) lists.erl:2674: :lists.mapfoldl_1/3
```

## Browser witness (node scripts/browser_smoke.mjs)

```
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:50725
[console] Failed to load resource: the server responded with a status of 404 (Not Found)
[console] [Popcorn] stdout: [22m
18:10:22.982 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)[0m

[console] [Popcorn] stdout: [22m
18:10:23.008 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)[0m

[console] Failed to load resource: the server responded with a status of 409 (Conflict)
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); blob=OK(popcorn/l3rb1792545023025/receipt.txt:61-roundtrip); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:3-matched)
```
