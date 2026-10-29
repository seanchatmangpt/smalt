# Y4 — Sync-Fault Witness (PRD Phase 4, real BFF boundary)

- Date: 2026-10-21
- Subject: `/Users/sac/smalt/workspace/scripts/sync_fault_probe.mjs` against the live
  BFF route `/Users/sac/smalt/workspace/app/api/sync/state/route.ts`
  (`POST http://127.0.0.1:3100/api/sync/state`, Next dev on :3100) with the real
  smalt substrate (data plane :8443, ARM/STS :9443) in :enforce mode.
- Method: real HTTP only, no mocks, no test framework. All HTTP rides
  `smaltFetch` (lib/smalt.ts, compiled to a temp dir — same pattern as
  `scripts/enclave-loop.mjs`), so `assertLocalUrl` runs on every request.
  Readiness is a bounded poll on a real observable — no fixed sleeps.
- Standing: **PASS** — all three behaviors hold as specified.

## Leg 1 — Simulated disconnection (8 concurrent clients, one doc)

Seed doc created once (no baseVersion -> create path), etag captured. Then 8
concurrent clients POSTed batches `[{ id, data: {client: k}, baseVersion }]`
with DIFFERENT payloads and the SAME baseVersion in one `Promise.all`.

Observed (run 1, pid 80823):

```
[PASS] leg1-seed — doc=y4-fault-l1-80823-1792570398961 etag="3b3cf02cc8e139caa7bf6145f8df91580da23a598e2bc6725e13cf7612aaa422"
[PASS] leg1-concurrent — 1 applied (client 0), 7 version_conflict
[PASS] leg1-final-state — stored doc == winner payload (client 0)
```

Exactly one applied, seven typed `version_conflict` rows (each carrying the
server's current etag), zero errors. Corruption check read the STORED doc
directly off the cosmos face (:8443, freshly minted bearer): it matches the
single winner's payload byte-for-byte on `kind`/`client`/`rev`.

## Leg 2 — Offline staging

Five mutations staged client-side (nothing posted), then the full batch posted
once; the BFF applies entries sequentially in batch order.

```
[PASS] leg2-batch — applied=5 conflicts=0 errors=[]
[PASS] leg2-final-state — final server state == staged mutation #5
```

All 5 applied in order; direct read of the stored doc shows mutation #5
(`step: 5`) as the final state.

## Leg 3 — Repeat run

Doc seeded, then the byte-identical batch (same payload, same baseVersion =
seed etag) posted twice sequentially. Pass 1 applied (etag rotated); pass 2's
baseVersion is now stale -> typed conflict per contract. A ghost-id entry with
a baseVersion against a nonexistent doc -> typed `doc_not_found` (404-class).

```
[PASS] leg3-pass1 — applied, etag rotated "a2e734f3…d41" -> "814bdb76…864"
[PASS] leg3-replay-conflict — typed version_conflict, currentEtag="814bdb76f5b3c107f99e99c16cad5eea047c62f4e0f30689d3679e1c6f78db64"
[PASS] leg3-doc-not-found — typed doc_not_found

# SUMMARY: 9/9 PASS, 0 FAIL
EXIT=0
```

Two consecutive full runs: 9/9 PASS, exit 0 both times (first run pid 79949
had 8/9 — a probe-side leg-3 design bug fixed below, not a server defect).

## Design note (recorded honestly)

The initial leg-3 shape (create in pass 1, replay in pass 2 with pass 1's
etag) legitimately APPLIES on pass 2 — the baseVersion is still current, so
per the documented contract there is nothing to conflict. The probe was
corrected to seed first and run two identical passes carrying the same
pre-pass baseVersion, which is the actual stale-replay scenario. Server
behavior was correct on every observation, including the "failing" one.

## Gates

- `just ws-lint` — 0 errors (28 pre-existing warnings, none in this probe).
  Fixed: probe initially used raw `fetch` with template-literal URLs (air-gap
  lint error) — rewritten onto `smaltFetch`; lint then clean.
- `just ws-build` — exit 0 (`/tmp/y4-ws-build.log`).
- Probe exits: 0, 0 (two full green runs); one intermediate exit 1 during the
  leg-3 redesign, disclosed above.

## Replay

```bash
cd /Users/sac/smalt/workspace && node scripts/sync_fault_probe.mjs   # exit 0 = PASS
```
