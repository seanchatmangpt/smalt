# v26.10.15 Work Orders — Lane Partition

Release: v26.10.15 · Base: HEAD 518b31a + uncommitted working tree. Planning lane X-2,
2026-10-15. Clusters A-E per the coordinator-approved 20-lane table; cluster F carries the
sharpened-list WOs 21-27. Every lane cites a witnessed-failure justification receipt from
v26.10.14 (`docs/jira/v26.10.14/receipts/`). `tests:` follows the WO-04 slice-contract
grammar (repo-relative paths, optional `:tag`, `none (court-x2 gated)` = explicit declaration).

Writers may not run git state commands; coordinator owns transitions and commits.

## Cluster A — Substrate daemon (seed: 01-substrate-daemon.md)

| # | Lane | WO doc | Justification (v26.10.14 receipt) | Depends on | tests: |
|---|---|---|---|---|---|
| 01 | daemon lifecycle | [01-substrate-daemon.md](01-substrate-daemon.md) | dod-01-substrate-lock (27-min flock starvation; orphaned pid 47479) | — | `test/support/substrate_client.exs`, `test/chaos/port_collision_test.exs:substrate_private`, `test/chaos/crash_isolation_test.exs:substrate_private` |
| 02 | logical tenant isolation | to author (§3 namespacing of seed 01) | dod-01-substrate-lock (cross-lane state collision class) | 01 (Store.namespace consumer) | `test/store/namespace_test.exs` |
| 03 | port+lock elimination | to author (§1/§6 migration of seed 01) | fin-11-census-ports (front-door 4/2 port pin split, boot abort on 9444/9545) | 01 | `test/chaos/port_collision_test.exs`, `test/support/substrate_client.exs` |
| 04 | auth-mode multi-tenancy | to author (§4 listener blocks of seed 01) | fin-05-auth-mode-pin (cross-lane enforce-VM poisoned tokenless probes) | 01 | `test/support/substrate_client.exs`, `test/wire/egress_wire_test.exs` |
| 05 | client auto-routing | to author | fin-05-auth-mode-pin + fin-11-census-ports (lane-side pick-a-block logic is today ad-hoc per harness) | 01, 02 | `test/support/substrate_client.exs` |

## Cluster B — Receipts/query (seed: 02-receipts-query-service.md)

| # | Lane | WO doc | Justification | Depends on | tests: |
|---|---|---|---|---|---|
| 06 | telemetry ingestion | to author | dod-06-lane-cleanup (61 orphan roots — fleet observation had no lane-cost signal); s8-wave-telemetry (bench rows unreadable by waves) | 27 (JSONL store exists) | `scripts/wave_telemetry.sh` (shell court: emit/wrap/report round trip) |
| 07 | receipts query CLI | [02-receipts-query-service.md](02-receipts-query-service.md) | dod-13-receipt-index (index-stale races; hardcoded `today`); fin-15-receipts-refresh | 08 | `test/receipts_query_test.py` (if py test harness exists, else shell court in receipt) |
| 08 | index sync | to author | dod-13-receipt-index (concurrent receipt-index runs rewrite same files) | — | shell court over `receipt_index.py` regenerate idempotence |
| 09 | drift elimination | to author | dod-10-gap-sync (hardcoded "35 KD rows", actually 51 — count-restatement class) | 07 | shell court: `receipts.py gaps --strict` exit 1 on seeded SUSPECT row |

## Cluster C — Build cache (seed: 03-lane-build-cache.md)

| # | Lane | WO doc | Justification | Depends on | tests: |
|---|---|---|---|---|---|
| 10 | contract hasher | to author (spec §3.1 of seed 03) | dod-06-lane-cleanup (33.71 GiB orphaned lease roots) | — | `test/`-free; shell court: touch-only mtime bump → same key, port-env change → different key |
| 11 | shared build cache | [03-lane-build-cache.md](03-lane-build-cache.md) | dod-06-lane-cleanup (33.71 GiB; 50-60s cold compile per lane) | 10 | `test/foo_test.exs`, `test/bar_test.exs` (share/diverge witnesses per seed falsifiers 1-3) |
| 12 | artifact purge | to author (GC §3.4 of seed 03) | fin-20-cleanup + dod-06-lane-cleanup (bulk delete threw away warm trees) | 11 | `just build-cache-gc-dry` witness (old tree DELETE, live-beam tree SKIP) |

## Cluster D — Slice testing (seed: 04-lane-slice-testing.md)

| # | Lane | WO doc | Justification | Depends on | tests: |
|---|---|---|---|---|---|
| 13 | slice contracts | [04-lane-slice-testing.md](04-lane-slice-testing.md) | dod-07-court-x2 (fleet starvation: N lanes × 3-min court, 10-20 min queues) | 11 (build root interplay) | `test/`-free; own court = `just slice` round trip on bad-id/path contract errors |
| 14 | integration gate protocol | to author (§3.4 of seed 04) | dod-07-court-x2 (court-x2 is the real integration truth; lane full-suites bought queue time) | 13 | `none (court-x2 gated)` — this lane owns the coordinator gate protocol, not test files |
| 15 | fast pre-flight | to author | fin-11-census-ports (boot aborted late on collision — pre-flight must be cheap and first) | 01 | `test/support/substrate_client.exs` |
| 16 | mutation gating at integration | to author | 18-mutation-courts (v26.10.14: courts proved non-vacuous post-hoc; slice tier must not weaken this) | 13, 14 | **Constraint**: must prove slice-tier courts do not weaken non-vacuity receipts — deliverable is the proof court itself, `scripts/mutation_court.py` invocation witnessing a slice-green/mergered case |

## Cluster E — Superfans + DoD (new; no seed docs — "to author" for all four)

| # | Lane | WO doc | Justification | Depends on | tests: |
|---|---|---|---|---|---|
| 17 | substrate superfan | to author | fin-11-census-ports + fin-05-auth-mode-pin (substrate state was re-diagnosed ad hoc in ≥4 receipts) | 01, 02, 04 | `test/support/substrate_client.exs` |
| 18 | court superfan | to author | dod-07-court-x2 + 18-mutation-courts (court vocabulary drifted — S7 in v26.10.14) | 14, 16 | shell court over `scripts/court_x2.sh --dry-run` + probe stamps |
| 19 | receipts superfan | to author | dod-13-receipt-index + fin-22-final-index (index restatements drifted within one window) | 07, 08, 09 | shell court: `receipts.py gaps` clean on landing tree |
| 20 | DoD matrix | to author | dod-09-verify-all / fin-14-verify-all (verify-all ran without a per-lane standing matrix) | 17, 18, 19 | `none (court-x2 gated)` — matrix is a projection; gate is the lanes' own courts |

## Cluster F — Sharpened list (carry-forwards + new WOs)

| # | Lane | WO doc | Justification | Depends on | tests: |
|---|---|---|---|---|---|
| 21 | shim court generic | done this window as `scripts/shim_court/` — carry forward as maintained (receipt `docs/jira/v26.10.14/receipts/s6-shim-court-harness.md`) | s6-shim-court-harness (wire-norm divergence class) | — | `scripts/shim_court/*.sh` courts themselves; `none (court-x2 gated)` beyond that |
| 22 | kd auto flip | done as `scripts/kd_flip.py` — carry forward as maintained (receipt s7-kd-flip.md) | fin-09-kd-rows (KD row edits hand-applied, drifted) | 07 (flip must cite `receipts.py standing`) | shell court: kd_flip on seeded row, receipt-gate refusal witness |
| 23 | substrate proxy | [23-substrate-proxy.md](23-substrate-proxy.md) (stub; full authoring = lane 23's job) | dod-01-substrate-lock (full daemon is launchd+identity machinery; interim need is cheaper) | 01 (identity contract), 02 (prefix law) | `test/support/substrate_proxy_test.exs` |
| 24 | sdk docs corpus mining | [24-sdk-docs-corpus-mining.md](24-sdk-docs-corpus-mining.md) (stub) | 14-docs-drift + KD register provenance (divergences found by probes only; SDK parser corpus untouched) | 07 (divergences surfaced feed `receipts.py divergences`) | shell court: one seeded divergence in corpus → mined diff row emitted |
| 25 | flake quarantine | [25-flake-quarantine.md](25-flake-quarantine.md) (stub) | 01-test-isolation (v26.10.14 P0 flake root cause; flakes were triaged ad hoc mid-wave) | 13 (slice contract grammar hosts the tag) | `test/` seeded `:quarantine` round trip: tag → isolated green ×N → promotion |
| 26 | seeded cross-suite regression | [26-seeded-cross-suite-regression.md](26-seeded-cross-suite-regression.md) (stub) | dod-07-court-x2 (gate's own mutation court — must prove gates still catch) | 14, 16 | `none (court-x2 gated)` — the WO IS a test of the gate; its falsifier is the court-x2 red witness |
| 27 | wave telemetry adoption | done as `scripts/wave_telemetry.sh` — carry forward as mandatory lane exit (receipt s8-wave-telemetry.md) | s8-wave-telemetry + dod-06-lane-cleanup (waits were archaeology, not data) | — | `scripts/wave_telemetry.sh report` on the window's JSONL |

## Rules

1. One writer per lane; disjoint files except seams recorded in RESOLUTIONS.md.
2. Slice green ≠ landed: coordinator runs `just court-x2` post-merge (WO 04 §3.4).
3. Seam lanes (per RESOLUTIONS escalation table) additionally run full `test-offline`.
4. Carry-forward lanes (21, 22, 27) do not re-implement; their job is maintenance,
   adoption enforcement, and a v26.10.15 receipt citing the v26.10.14 harness receipt.
5. Stub lanes (23-26) must have their WO fully authored before their lane starts writing code.
