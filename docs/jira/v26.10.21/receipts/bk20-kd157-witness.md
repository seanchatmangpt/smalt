# BK-20 — KD-157 Witness: ARM RG DELETE under transport retry

**Standing:** ALIVE (close-condition arm a — HTTP/2 twin session stability at c=128 witnessed; retry rate 0.0%)

Context: solo

Date: 2026-10-22 (lane BK-20, v26.10.21)

## Divergence (register row KD-157)

A response-lost RG DELETE (`ERR_HTTP2_SESSION_ERROR`) that already executed
server-side gets retried and answers 404 — the retry observes the DELETE's own
success as a missing resource (T21 ramp stampede). Close condition (register):
**HTTP/2 twin session stability at c=128 (retry rate ~19% → ~0), or a typed
pinion that DELETE-retry-404 is client-absorbed idempotency.**

## Witness (close-condition arm a holds)

Real run of the pinned lane harness `scripts/bench/scvd_t21_arm_ramp.mjs`
against the live substrate (beam pid 53160; 9443/9444 LISTEN witnessed) at
c=128, on HEAD 84aa667..dfc42ea tree, no lib/ edits in this lane:

```
$ NODE_TLS_REJECT_UNAUTHORIZED=0 node scripts/bench/scvd_t21_arm_ramp.mjs
2026-10-22T02:36:36.549Z ARM n=512 cycles (3072 reqs) ops/s=13.0 p50=10058.497ms p95=10222.361ms p99=10280.453ms errors=0 wall=39293ms standing=PASS
EXIT=0
```

Result row (`tmp/bench/scvd-arm.jsonl`, newest line):

```json
{"lane":"scvd-t21","surface":"arm","op":"putgetdelete-c128","n":512,"ops_per_sec":13,"p50_ms":10058.497,"p95_ms":10222.361,"p99_ms":10280.453,"errors":0,"wall_ms":39293,"wall_budget_ms":60000,"requests":3072,"transport_retries":0,"delete_retry_404_ok":0,"concurrency":128,"cycles_per_worker":4,"machine":{"cpu":"Apple M3 Max","cores":16,"node":"v26.10.0","endpoint":"https://127.0.0.1:9444"},"standing":"PASS"}
```

**transport_retries = 0 / 3072 requests (0.0%, prior ~19%)** at c=128, 0
errors, wall 39.3s < 60s budget — HTTP/2 twin session stability witnessed.
`delete_retry_404_ok = 0`: the KD-157 absorption did not even need to fire.

## Direct wire face (why the pinion arm is also sound)

KD-15 bearer handshake (tokenless 401 → mint), then over the TLS twin:

```
PUT  resourcegroups/bk20-kd157-1792636511        -> 201
DELETE (1st)                                     -> 202 (long-running delete accepted)
DELETE (retry face, same path)                   -> 404 {"error":{"code":"ResourceGroupNotFound", ...}}
```

The retry observes the first DELETE's own success as 404 — the exact face the
harness's `delete_retry_404_ok` absorbs as idempotent delete-success.

## Adversarial leg (mutations must REFUSE — non-vacuity)

1. Garbled bearer on DELETE → **401**.
2. Tokenless DELETE → **401** + KD-15 challenge header
   `www-authenticate: Bearer authorization="https://127.0.0.1:9443/organizations", resource="https://127.0.0.1:9444", error="invalid_token", error_description="MissingBearerToken"`.
3. Shim court on the harness itself (BASELINE sha256 recorded → SHIM marker
   `SHIM-COURT` — bearer replaced with tampered string → AFTER run at c=8:
   `errors=16 standing=FAIL`, exit **1** → RESTORE byte-exact, `sha256sum -c: OK`).
   A court that would still PASS under a tampered bearer is vacuous; this one
   flips, so the PASS above carries bits.

## Post-state

KD-157 flipped OPEN → CLOSED-SIMULATED via `scripts/kd_flip.py --apply`
(receipt-gated; this receipt postdates all shims — no KD-157 shim exists in
lib/, the harness already carried `# KD-COVERS: KD-157`).

Out-of-scope observation (not a KD-157 item, left untouched): malformed-JSON
PUT body to the ARM RG surface answered 500 (not 400) — pre-existing behavior,
flagged here for triage only.
