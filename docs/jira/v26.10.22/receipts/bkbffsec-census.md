# BK-BFFSEC — BFF route census: no ungated mutating faces beyond KD-171 set

**Standing:** **ALIVE** (census + live probes on a real Next dev server; one new
registered posture KD-173)
Context: solo
Date: 2026-10-22
Repo: /Users/sac/smalt (main)
Lane: BK-BFFSEC
Parent: EXPL7-R1 (`expl7r1-bff-repairs.md`), KD-171

## Census table — workspace/app/api/** (all 5 route files, 9 faces)

| # | Face | Method | Gate | Mutating | KD |
|---|---|---|---|---|---|
| 1 | /api/sync/state | POST | `assertLoopbackCaller` (Host/Origin) | yes (substrate write) | KD-171 |
| 2 | /api/v1/stream main SSE face | GET | none (by design - the app data face) | no (registers a connection) | KD-171 posture class |
| 3 | /api/v1/stream?stats / ?drift | GET | env `SMALT_DEBUG_FACES=1` | no (read counters) | KD-171 |
| 4 | /api/v1/stream (storm abort) | POST | env `SMALT_DEBUG_FACES=1` | yes (one-request DoS face) | KD-171 |
| 5 | /api/v1/ingest | POST | HMAC sig (`x-smalt-signature`, `timingSafeEqual`) | yes (bucket counters) | KD-173 (new) |
| 6 | /api/v1/ingest (debug counters) | GET | env `SMALT_DEBUG_FACES=1` | no | KD-171 |
| 7 | /api/bench/isr-revalidate | POST | env `SMALT_DEBUG_FACES=1` | yes (revalidatePath) | KD-171 |
| 8 | /api/bench/isr-stats | POST | env `SMALT_DEBUG_FACES=1` | yes (reset / stale-report) | KD-171 |
| 9 | /api/bench/isr-stats | GET | none (read-only by design, EXPL7-R1 left it open) | no | - |

Census conclusion: **zero mutating ungated faces** remain beyond the KD-171
set; the only new finding is the ingest POST dev-default HMAC key, registered
as **KD-173** (deliberate dev-default credential, KD-169/171 posture class).

## Live probes (real Next dev server on :3127, no SMALT_DEBUG_FACES, substrate-independent faces)

```
--- 1 sync/state POST non-loopback Host -> gate holds
status=403 {"error":"sync_state_non_loopback","detail":"non-loopback host \"evil.example.com\""}
--- 2 stream storm POST -> env gate holds
status=404 {"error":"not_found"}
--- 3 isr-revalidate POST -> env gate holds
status=404 {"error":"not_found"}
--- 4 isr every mutating face gated
status=404 {"error":"not_found"}
--- 5 ingest POST no signature -> credential gate holds
status=401 {"error":"invalid_signature"}
--- 6 ingest POST default-key sig (SMALT_INGEST_HMAC_KEY unset) -> ACCEPTED (KD-173 evidence)
status=202 {"accepted":true,"bytes":5}
--- 7 isr-stats GET read-only (ungated by design)
status=200 {"eventsPath":"/Users/sac/smalt/workspace/.bench/n6-isr-events.jsonl",...}
--- 8 stream?stats=1 -> env gate holds
status=404 {"error":"not_found"}
```

## KD-173 row

Minted in `docs/jira/v26.10.22/KNOWN_DIVERGENCES.md`: ingest POST's gate
verifies against a public-source key (`n4-dev-key`) when
`SMALT_INGEST_HMAC_KEY` is unset. Deliberate dev-default posture
(KD-169/171 class). Close condition: refuse-boot/503 when unset off the dev
plane, witnessed with a default-key-signature-rejected leg.

## Verification ladder

```
$ just ws-lint
> eslint .
ws-lint exit=0

$ node scripts/e2e-court.mjs   (substrate DOWN)
# PASS=68 FAIL=0 SKIP=2    exit=0   (SKIP: dom-render node + popcorn-iframe no-server-on-3100)
```

## Standing

ALIVE — census complete, every gate witnessed holding live, one new posture
registered (KD-173, OPEN). No route files edited (none required: all faces
already gated or read-only-by-design; no premise-rot comments found —
ingest/stream/isr-stats header prose matches observed behavior). Dev server
stopped.
