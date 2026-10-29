# kvtestfix — E4KV premise-rot re-author (upsert-200 contract)

Standing: ALIVE
Context: solo
Date: 20261021T224500Z

## Premise rot (from witness-all 20261021T213123Z)

`test/empirical_kv_latency_test.exs` pinned `PUT /kv` + `If-None-Match: *` -> 201-create
(lines 81, 128). T24WIRE (2026-10-21, `lib/smalt/egress/AppConfigRoutes.ex`) flipped /kv PUT
to the registered upsert-200 contract (`@azure/app-configuration` hard-fails on a 201
create). Tests still pinned the old face — test-side premise rot.

## Fix

Re-authored to the registered contract (choice: keep the /kv surface; the 201-holds face
move to /secrets was rejected because this suite's whole latency fence + 404-face contract
is defined on /kv):

- set status pin: `assert set_st in [200, 201]` with typed failure
  `KV-SET-STATUS-FAIL` naming the T24WIRE registered upsert (anything else fails loud).
- docstring + IO.puts labels updated (create-201 -> upsert-200/201-tolerated).
- latency fence untouched (`best-round p99 < 10_000us`), byte-equal value assertion on all
  300 GETs untouched, delete->404 KvNotFound face untouched.
- `kv_put_create` doc comment now cites the T24WIRE divergence.

## Verification

```
MIX_BUILD_ROOT=_build-kvtf asdf exec mix test test/empirical_kv_latency_test.exs
Result: 3 passed
[E4KV get latency] n=100 fresh-conn loopback wire round-trips x 3 rounds (best round fenced)
  set (PUT upsert, status=200) wall=5225us
  round 1: p50=865us  p95=4190us  p99=31608us  max=31608us
  round 2: p50=621us  p95=1089us  p99=5319us  max=5319us
  round 3: p50=634us  p95=4944us  p99=6001us  max=6001us
  fence: best-round p99 < 10000us
[E4KV delete->404] DELETE wall=5208us status=204; re-GET 945us -> 404 KvNotFound
```

Wire answered 200 on the staged PUT — the registered upsert face, confirming the re-authored
pin matches the live substrate.

## Diff scope

Single file: `popcorn_demo/test/empirical_kv_latency_test.exs` (docstring, two set-status
asserts, one IO.puts label, one helper comment). No lib/ edits.

Standing: ALIVE (3/3 pass on the lane build root `_build-kvtf`, asdf toolchain).
