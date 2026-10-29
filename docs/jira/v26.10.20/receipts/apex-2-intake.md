# APEX-2 — SCVD apex scenario: 500 parallel intake submissions, three-leg gateway

**Standing:** **PARTIAL_ALIVE** — functional composition ALIVE on both backends
(500/500 submissions, zero egress violations, zero CORS, byte-equal GET on
every submission); PRD wall target ≤500ms **measured NOT MET** (1301.76ms
smalt / 6145.71ms Azurite).

## What ran

`node popcorn_demo/azurite-spike/apex_intake.mjs` — 500 parallel intake
submissions, each traversing three legs composed from witnessed seams:

1. **APIM-policy emulation leg** (in-process, mirroring the substrate policy
   arm, not the remote proxy): rate-limit counter (in-memory table, ETS
   mirror), LocalSTS-shaped HS256 JWT mint + shape/sig verification (aud,
   iss, sub, exp, iat), header transform (`x-via: apem-policy-arm`), payload
   schema check (`submissionId`, `kind`, `bytes`).
2. **AppConfig flag resolution** from in-memory table (`apex.intake.enabled`,
   `apex.hot-staging.blocks`), measured per call.
3. **Blob hot staging** (real transport, host-side): 3× Put Block (1KiB each)
   + Put Block List + byte-equal GET, per submission, against the live
   substrate data plane `http://127.0.0.1:8443/popcorn` (SharedKey
   `base64(sha256("popcorn"+"smalt-dev-sb"))`); secondary backend Azurite
   `http://127.0.0.1:10100/devstoreaccount1` (still up).

Egress discipline asserted per operation (loopback-only URL check on every
request); CORS asserted via response-header scan (`access-control-*`) and
preflight-method check.

## Measured table

Machine: `darwin arm64 node v26.10.0` (substrate beam on 8443, Azurite node
on 10100, both live during the run). Run at `2026-10-21T16:54Z`.

| metric | smalt 8443 | Azurite 10100 |
|---|---|---|
| submissions ok | 500/500 | 500/500 |
| wall (500 parallel) | **1301.76 ms** | **6145.71 ms** |
| PRD ≤500ms | **NOT MET** | **NOT MET** |
| ops/sec | 384.1 | 81.4 |
| blob leg p50 / p95 / p99 (ms) | 1222.2 / 1288.8 / 1293.4 | 6074.3 / 6134.2 / 6137.9 |
| policy leg p50 / p99 (ms) | 0.0052 / 0.0171 | 0.0037 / 0.0092 |
| flag leg p50 / p99 (ms) | 0.0000 / 0.0003 (<1ms PASS) | 0.0000 / 0.0002 (<1ms PASS) |
| egress violations | 0 | 0 |
| CORS headers / preflights | 0 / 0 | 0 / 0 |
| byte-equal GET | 500/500 | 500/500 |
| errors | 0 scenario; 1 cleanup divergence (below) | 0 |

Raw: `popcorn_demo/azurite-spike/apex-intake-out.json`.

## Typed findings

- **PRD wall target ≤500ms: measured UNSUPPORTED.** The wall is dominated by
  the blob leg (p50 ≈ wall): 2000 loopback HTTP ops (3 Put Block + Put Block
  List + GET × 500) through one beam. A pipelined-variant experiment (3 Put
  Block per submission issued concurrently) measured *worse* (1808.5ms smalt
  / 8539.1ms Azurite) — server-side serialization dominates; reverted. The
  in-memory legs are sub-µs and contribute nothing to the wall. Meeting 500ms
  would require cutting blob round trips (e.g. 1-block staging or batched
  commit), which changes the scenario's witnessed 3-block shape — left as the
  gap, not papered over.
- **Dollar figures: UNSUPPORTED** per scvd-ledger law — no cost model was
  executed in this lane; no $/submission claim is made.
- **Cleanup divergence (smalt only):** container delete refused
  `409 ContainerLocked` — "container policy enforces immutable WORM
  retention" (HTTP-created containers default immutable with no policy;
  `blob_service.ex` WORM arm). Azurite deletes cleanly. Scenario residue:
  3 `apex2-*` containers (≈1500 × 3KiB blobs) on the smalt blob plane.
  Recorded as a divergence, not a scenario failure.
- **Egress/CORS: zero** on both backends across all ~4000 requests.

## Commands

```
node apex_intake.mjs   # exit 1 (standing FAIL: prd_pass false on both backends)
```

Session-introduced failures: none. Pre-existing substrate behavior observed:
WORM-by-default container immutability (see above).
