# popcorn_demo testbed witness — SUSPECT

- Standing: SUSPECT
- Date: 20261021T010334Z
- Host legs exit: 1
- Browser witness exit: 0 (skipped: public/out not cooked)

## Host-side legs (mix run, MIX_BUILD_ROOT=_build-lane7)

```
Compiling 3 files (.ex)
     error: cannot invoke remote function Access.get/2 inside a guard
     │
 177 │         when is_binary(cer) and byte_size(cer) > 0 and rec["id"] != nil ->
     │                                                           ^
     │
     └─ lib/popcorn_demo/live_certs.ex:177:59: PopcornDemo.LiveCerts.create_cert/1


== Compilation error in file lib/popcorn_demo/live_certs.ex ==
** (CompileError) lib/popcorn_demo/live_certs.ex: cannot compile module PopcornDemo.LiveCerts (errors have been logged)
    (elixir 1.20.3) expanding macro: Kernel.and/2
    lib/popcorn_demo/live_certs.ex:177: PopcornDemo.LiveCerts.create_cert/1
```

## Browser witness (node scripts/browser_smoke.mjs)

```
serving /Users/sac/smalt/popcorn_demo/public on 127.0.0.1:60005
[console] Failed to load resource: the server responded with a status of 404 (Not Found)
[console] [Popcorn] stdout: [22m
18:03:35.511 [info] smalt-on-popcorn smoke: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass)[0m

[console] [Popcorn] stdout: [22m
18:03:35.537 [info] popcorn_demo live leg: live=OK(endpoints,tenants,sts,subscriptions=1)[0m

[console] Failed to load resource: the server responded with a status of 409 (Conflict)
SMOKE_RECEIPT: cosmos_sql=OK(where+order+limit correct); sb_rule=OK(sql filter matched); registry=OK(admitted-type + api-version checks pass); blob=OK(popcorn/l3rb1792544615556/receipt.txt:61-roundtrip); live=OK(endpoints,tenants,sts,subscriptions=1); matrix=OK(popcorn/smoke:1-matched)
```
