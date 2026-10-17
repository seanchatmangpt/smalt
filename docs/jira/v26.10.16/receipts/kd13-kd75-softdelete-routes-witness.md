# Witness receipt — KD-13 / KD-75 KV soft-delete routes landed

Standing: **PARTIAL** (routes + wire-tier tests landed; the soft-delete cycle
describe has one failing test on a create-precondition, quoted below — not
green, so not PASS)

- Date: 2026-10-17, KD-register lane.
- Landed routes (`lib/smalt/egress_router.ex:723-752`, wave I16/L1 comment
  in source):
  - `DELETE /keys/:name`
  - `GET  /deletedkeys`
  - `GET  /deletedkeys/:name`
  - `POST /deletedkeys/:name/recover`
  - `POST /deletedkeys/:name/purge`

## Test evidence (real output)

```
$ MIX_BUILD_ROOT=_build-laneKD mix test test/egress_dispatch_test.exs
107 tests, 1 failure
```

Failing test (classified, not fixed — coordinator lane owns the edit;
lease: test/egress_dispatch_test.exs is READ-ONLY for this lane):

```
  1) test KV soft-delete routes delete -> get deleted -> recover -> purge cycle (EgressDispatchTest)
     test/egress_dispatch_test.exs:2819
     {"error":{"code":"NotFound","message":"PUT /keys/delkey1/create is not
     implemented on this plane (reserved namespace 'keys'); nothing was stored."}}
     code: assert conn.status in [200, 201], conn.resp_body
```

Classification: the failure is the test's **key-create precondition**
(`PUT /keys/:name/create` not implemented on the KV plane) at line 2821 —
NOT a MissingXMsVersion failure. The route-under-test arms (delete, get
deleted, recover, purge) are downstream of that precondition and therefore
unexercised in this test. The remaining tests in the run pass: paired run
`test/egress_kv_appconfig_test.exs + test/data_plane/blob_hardening_test.exs`
→ `130 tests, 0 failures`; combined `237 tests, 1 failure`.

Close condition unchanged from the register rows: KD-13/KD-75 flip only when
the soft-delete describe is green and a witness receipt postdates the router
shim mtime (kd_flip.py gate).
