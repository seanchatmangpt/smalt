# KD-CONF lane: KD-147..152 live-wire conformance witness — KV / Cosmos / Queue

- Date: 2026-10-22 (UTC)
- Lane: KD-CONF, repo /Users/sac/smalt, HEAD adc32ec2 base
- **Standing:** CLOSED — with evidence (KD-147, KD-148, KD-149, KD-150, KD-151, KD-152; register rows CLOSED-WITH-EVIDENCE)
- Context: solo

## Scope

Six KD rows on the kv (Key Vault secrets 7.4), cosmos (cosmos_sql), and
queue_storage surfaces were CLOSED-SIMULATED (shim landed, simulated witness from
v26.10.20). This lane re-probed each face with real HTTP through the self-booted
egress router and upgrades all six to CLOSED-WITH-EVIDENCE — no divergences
remain; no code changes were needed.

## Court

`MIX_BUILD_ROOT=_build-kdconf scripts/fast_test.sh test/internal/kd_conf_court_test.exs`
(fresh internal court, ephemeral ports, no mocks, no sleeps):

```
04:00:41.743 info[correlation_id=cos-366090 ] Sent 412 in 187µs
Finished in 0.7 seconds (0.00s async, 0.7s sync)

Result: 5 passed
[04:00:41] wall: 182s (build root: _build-ft-aa3d337e)
```

5 tests / 0 failures, one per KD row (KD-147/148 share one probe).

## Witnessed faces

- **KD-149** — KV secret PUT first create → 201; re-set → 200 (KV secrets 7.4).
- **KD-150** — secret `id` = `https://{host}.vault.azure.net/secrets/{name}/{GUID-version}`.
- **KD-151** — `api-version=2099-01-01` → 400 `InvalidApiVersion`; `7.4` still admitted.
- **KD-147** — cosmos doc body carries exactly `_rid/_self/_ts/_etag` + user props;
  no `_gen`/`_v` on the wire.
- **KD-148** — `_etag` is a quoted GUID; If-Match echo passes CAS (200), stale etag → 412.
- **KD-152** — queue plane `x-ms-request-id` is a dashed-36 RFC 4122 v4 GUID on
  queue create (201) and message put (201).

## Shims (landed v26.10.20/21, all carry `# KD-COVERS`)

- `lib/smalt/egress/KvRoutes.ex:511,590,600,623,648` — KD-149/150/151
- `lib/smalt/egress_router.ex:3828` — KD-147
- `lib/smalt/data_plane/cosmos.ex:2646` — KD-148
- `lib/smalt/data_plane/queue_storage.ex:71` — KD-152

This receipt postdates every shim mtime (newest shim: queue_storage.ex Oct 22 00:01;
receipt written 2026-10-22), satisfying the kd_flip witness-mtime gate.

## Register

All six rows flipped CLOSED-SIMULATED → CLOSED-WITH-EVIDENCE in
`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`, receipt-gated on this file.

## Falsifier

A regression of any face flips the corresponding assertion in
`test/internal/kd_conf_court_test.exs` and exits 1.
