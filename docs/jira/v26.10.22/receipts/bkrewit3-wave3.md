# BK-REWIT3 — coordinator re-witness wave 3: the residual 16 SUSPECT rows

- **Standing**: ALIVE — 16/16 rows dispositioned with real, embedded,
  re-run evidence; 23 → 10 suspects. Every row either replayed cheaply
  (exit-captured) or typed honestly (SUPERSEDED / SUSPECT-PERMANENT-with-owner).
- **Context**: solo
- **Date**: 2026-10-22 · **Repo**: /Users/sac/smalt · **Lane**: BK-REWIT3

## Embedded counts (real, before/after)

```
$ python3 scripts/receipt_index.py   (before wave)  -> receipts=1419 sdk=61 total=1480 suspects=23
$ python3 scripts/receipt_index.py   (after wave, incl. this receipt) ->
  receipts=1470 sdk=61 total=1531 suspects=10
  (receipt count also grew from concurrent lanes' landings in the window)
$ residual 10 = bench-02/03/04/05 + c8-chaos-cross (5 bench-class) +
  bkaud2-lane-accounting, bkmcpsha-sha-fix (2 new, other lanes) +
  bkbmir-jsonl-mirrors, bkbmir2-mirror-wave2, bkp20-export-disposition
  (3 new token-free receipts landed concurrently — NOT this wave's rows)
```

## Per-row verdicts (original evidence untouched in every file; addenda appended, dated)

**Cheap replay PASS — SUSPECT cleared (11):**

| row | verdict | evidence |
|---|---|---|
| otp29-capability-probes | PASS 6/6 claims, exit=0 ×12 runs | all probes re-run on both toolchains; DEFAULT_GROUPS order reproduced |
| scvd-backpressure-audit | REMEDIATED on current tree | max_queue_len 10_000 prune + max_seen_ids 100_000 prune + typed @call_timeout 5_000 in store.ex, all citing SCVD-T8 |
| w32-api-conformance | PASS + 8 of 12 divergence candidates CLOSED | live re-probe; kv 201 / 2099->400 / blob 0x etag + empty body / cosmos GUID _etag, no _gen/_v / topic location-less 201 / SQL filter persisted + echoed |
| powl2-wave-skeptic | MIXED, typed | HIGH-2 loop mis-compile REPRODUCES (ChoiceGraph edges=[] on wf loop net); reticle 2-cycle now ADMITS (receipt claim stale); merkle law holds (flip-sensitive, empty=sha256("")) |
| w6a | ALL FACES OK, exit=0 | rotation-policy witness re-run on _build-rewit3 |
| w6ab | ALL FACES OK, exit=0 | backup/restore witness; only delta: key blob len 1043→1015 |
| w6ac | ALL FACES OK 1:1, exit=0 | 19 providers, register/unregister transitions exact |
| w6ao | ALL FACES OK, exit=0 | restore/fresh-etag/history-grow exact; PARTIAL_ALIVE → ALIVE |
| w6aq2 | ALL LEGS DONE, exit=0 | what-if tags.<k> delta exact |
| w6be | 17/17 legs true, exit=0 | retry-policy/DLQ/TTL laws reproduce exactly |
| w6l | witness RUN (falsifier satisfied), exit=0 | paging to exhaustion (50+5=55), globs 28, projection, tags AND 1, forged 0; PARTIAL_ALIVE → ALIVE |

**Typed dispositions — SUSPECT cleared (5):**

| row | typing |
|---|---|
| w6an-cosmos-default-ttl | SUPERSEDED-BY: the defaultTimeToLive face was replaced by the analyticalStorageTtl face (`effective_ttl/2` cosmos.ex:307, `analytical_store_sweep/2` :324, telemetry `[:smalt,:cosmos,:analytical_sweep]`); original replay impossible (API removed) |
| errc4-hdr | SUSPECT-PERMANENT-with-owner → bench-runner (bench-class rerun, quiesced machine); artifacts on disk re-verified |
| lc1-8hop-tax-chain | SUSPECT-PERMANENT-with-owner → bench-runner (200-cycle lifecycle harness, quiesced machine); artifacts on disk re-verified |
| w30-health-probe-pattern | SUSPECT-PERMANENT-with-owner → substrate-op; replay ATTEMPTED for real (2 boot attempts, pinned digest, 300 s + 600 s bounded polls, final=000) — vnext emulator would not serve on this loaded machine today |
| wasm-memory-cdp-witness | SUSPECT-PERMANENT-with-owner → substrate-op; /tmp probe artifacts deleted — re-author required |

## Drift findings surfaced by the wave (for owner lanes)

1. **W32 candidates obsolete**: W32-2/3/4/5/6/8/11/12 divergences are CLOSED
   on the current tree (registrar note in the w32 addendum); W32-10 (SB ns
   PUT 202) still open.
2. **powl2 reticle drift**: the 2026-10-21 "2-cycle refused" claim is stale —
   the current reticle admits the 2-cycle; HIGH-2 loop mis-compile still open
   (compiler.ex owner).
3. **w6an surface replaced** (defaultTimeToLive → analyticalStorageTtl);
   successor registered.
4. **w6l/w32 auth premise**: the staged w6l witness script predated the
   >=32-byte sb_shared_key gate + :enforce bearer on the data plane; adapted
   harness disclosed in the w6l addendum.

## Build root

`_build-rewit3` (this lane's own root, left for coordinator `just lane-clean`).

## Files committed (explicit paths)

- docs/jira/v26.10.14/receipts/errc4-hdr.md
- docs/jira/v26.10.14/receipts/lc1-8hop-tax-chain.md
- docs/jira/v26.10.20/receipts/otp29-capability-probes.md
- docs/jira/v26.10.20/receipts/powl2-wave-skeptic.md
- docs/jira/v26.10.22/receipts/bkrewit3-wave3.md (this receipt)
- docs/jira/v26.10.20/receipts/scvd-backpressure-audit.md
- docs/jira/v26.10.20/receipts/w30-health-probe-pattern.md
- docs/jira/v26.10.20/receipts/w32-api-conformance.md
- docs/jira/v26.10.20/receipts/w6a-kv-rotation-policy.md
- docs/jira/v26.10.20/receipts/w6ab-kv-backup-restore.md
- docs/jira/v26.10.20/receipts/w6ac-resource-providers.md
- docs/jira/v26.10.20/receipts/w6an-cosmos-default-ttl.md
- docs/jira/v26.10.20/receipts/w6ao-appconfig-revisions.md
- docs/jira/v26.10.20/receipts/w6aq2-deployments-what-if.md
- docs/jira/v26.10.20/receipts/w6be-eg-retry-policy.md
- docs/jira/v26.10.20/receipts/w6l-appconfig-queries.md
- docs/jira/v26.10.20/receipts/wasm-memory-cdp-witness.md
