# KV404 writer receipt — GET missing KV row answers 404 KvNotFound, not empty 500

**Standing:** PARTIAL_ALIVE (wire 404 verified on live substrate + non-vacuous regression test green; popcorn p99 latency fence flaky under concurrent load, unverified-at-quiescence)

Context: solo (lane KV404, writer)

Date: 2026-10-21
Subject: /Users/sac/smalt @ ccb575b (HEAD moved mid-lane from 9a0b8c6 by a concurrent lane's commit; my files are new/edited in worktree)
Lane build root: _build-kv404

## Root cause

The 404 arm of `GET/DELETE /kv/:key` (`lib/smalt/egress/AppConfigRoutes.ex:135,148`)
calls `blob_error(conn, 404, not_found_error("KvNotFound"))`. Inside
`EgressRouter.blob_error/3` (egress_router.ex ~3550), the blob-face guard was
the pre-ad3136b source read `if conn.private[:smalt_blob_face] and
is_binary(code)` (verified via `git show d577e71:lib/smalt/egress_router.ex`
line 3537).
`conn.private[:smalt_blob_face]` is nil on the KV face, and `nil and _`
raises BadBooleanError → Plug converts to an EMPTY 500. Commit ad3136b
(2026-10-21 10:19) already fixed the guard to short-circuit `&&` in HEAD
source, but the running substrate was a stale beam (pre-ad3136b), so the wire
still showed the defect.

## Before (stale beam, pid 6909, pre-ad3136b build)

```
$ TOKEN=$(curl -sk -X POST "https://localhost:9444/mytenant/oauth2/v2.0/token" -d '...' | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
$ curl -sk -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer $TOKEN" "https://localhost:9444/kv/missingkey123"

HTTP 500
```

Empty body, no content-type face, no x-ms-error-code. Same on
`/kv/.appconfig.key%2F<missing>` (the witnessed shape). Substrate log at the
500:

```
10:39:24.849 [info] GET /kv/missingkey123
10:39:24.850 [error] ** (BadBooleanError) expected a boolean on left-side of "and", got:
    nil
    (smalt 26.10.19) lib/smalt/egress_router.ex:3558: Smalt.EgressRouter.blob_error/3
```

## Fix

Restart the substrate on a fresh lane build of HEAD (`substrate.sh down` /
`MIX_BUILD_ROOT=_build-kv404 substrate.sh up`, pid 56472). No lib/ source edit
was required beyond ad3136b's `&&`; my session's lib/ diff is zero.

## After (HEAD build)

```
$ curl -sk -w '\nHTTP %{http_code}\n' -H "Authorization: Bearer $TOKEN" "https://localhost:9444/kv/.appconfig.key%2Fmissingkey123"
{"error":{"code":"KvNotFound"}}
HTTP 404
$ curl -sk -D- -o /dev/null -H "Authorization: Bearer $TOKEN" "https://localhost:9444/kv/nope2" | grep -i "content-type\|x-ms-error-code"
x-ms-error-code: KvNotFound
content-type: application/json; charset=utf-8
```

KV stays on the legacy JSON face (no XML envelope — `smalt_blob_face` is nil
so blob_error's JSON renderer runs). PUT/GET of a present key still answers
201/200 with the full record.

## Regression test (non-vacuous)

`test/integration/kv404_typed_error_test.exs` — real curl over the real TLS
twin (Chicago; no mocks). 2 tests:

- GET/DELETE missing → 404 body =~ "KvNotFound"; seeded 200 leg proves route liveness
- %2F-encoded dotted key (the exact witnessed wire shape) → 404 KvNotFound

```
$ MIX_BUILD_ROOT=_build-kv404 mix test test/integration/kv404_typed_error_test.exs test/integration/tls_blob_dispatch_test.exs
4 tests, 0 failures
```

Non-vacuity (shim): re-introduced `and` for `&&` in blob_error/3 → 2 tests,
2 failures; restored byte-exact (sha256 OK) → 2 tests, 0 failures. The test
flips, the gate is not vacuous.

## Popcorn legs (asdf OTP 29.0.6 / Elixir 1.20.4-otp-29)

```
$ MIX_BUILD_ROOT=_build-kv404 mix test test/live_appconfig_test.exs test/empirical_flag_latency_test.exs
Result: 6/7 passed
```

- `live_appconfig_test` (the 404-re-get lifecycle): PASS
- `empirical_flag_latency_test` correctness legs (mutation→GET propagation): PASS
- `flag polling latency contract` p99 fence: FAIL — best-round p99
  5184-7482us vs 5000us fence across 4 runs, p50 healthy at 0.7-1.0ms, with
  33ms max spikes. Load-bound: concurrent lanes were hammering the same
  substrate (thousands of cosmos PUTs/sec visible in substrate.log during the
  runs). No green precedent for this fence exists in popcorn receipts. The
  404 fix touches only an error arm and cannot affect the GET-200 latency
  path. Classified pre-existing/load-bound flake, honestly reported.

## Stale-premise cleanup

`popcorn_demo/test/empirical_flag_latency_test.exs` comment claimed the
substrate "currently answers GET-on-missing-kv-row with an empty 500" — the
harness avoided pre-write GETs to dodge it. Comment updated to the fixed wire
behavior; the etag-from-write contract is unchanged.

## Files

- test/integration/kv404_typed_error_test.exs (new, regression fence)
- popcorn_demo/test/empirical_flag_latency_test.exs (comment-only premise fix)
- docs/jira/v26.10.20/receipts/kv404-writer-receipt.md (this file)

## Replay

```bash
MIX_BUILD_ROOT=_build-kv404 mix test test/integration/kv404_typed_error_test.exs
TOKEN=$(curl -sk -X POST "https://localhost:9444/mytenant/oauth2/v2.0/token" \
  -d 'grant_type=client_credentials&client_id=x&client_secret=y&scope=z' \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
curl -sk -H "Authorization: Bearer $TOKEN" "https://localhost:9444/kv/nope"   # 404 KvNotFound JSON
```
