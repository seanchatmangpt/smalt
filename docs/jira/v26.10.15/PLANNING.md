# v26.10.15 Window Planning Summary

Planning lane X-2, 2026-10-15. Base: main @ 518b31a + uncommitted working tree.
The P-0 baseline doc (`00-*.md`) had not landed when this summary was authored; this
doc binds the window objective directly from the witnessed v26.10.14 receipts instead.
Seed docs on disk: 01-04 (full) and 23-26 (stubs); 05 did not land.

## 1. Window objective — six coordination-cost classes

Each lane in `_LANES.md` cites a witnessed-failure receipt. The failures reduce to six
coordination-cost classes with these witnessed costs:

| class | cost class | witnessed cost (receipt) |
|---|---|---|
| C1 | orphaned substrate/beam processes starve queued lanes | 27-min flock starvation, orphaned pid 47479 (dod-01-substrate-lock) |
| C2 | orphaned lane build roots accumulate as dead disk | 61 orphan roots, 33.71 GiB; 50-60s cold compile per lane (dod-06-lane-cleanup) |
| C3 | structural parse failures in lane/test/receipt machinery | court-x2 flake-class failures, index-stale races + hardcoded `today` (dod-07-court-x2, dod-13-receipt-index) |
| C4 | court queue starvation at integration | 3-min court per lane, 10-20 min queues at N lanes (dod-07-court-x2) |
| C5 | cross-lane state clobbers | poisoned tokenless probes, 4/2 front-door port-pin split, boot abort on 9444/9545 (fin-05-auth-mode-pin, fin-11-census-ports) |
| C6 | count/digest restatement drift | hardcoded "35 KD rows" vs actual 51 (dod-10-gap-sync); index restatements drifted within one window (fin-22-final-index) |

## 2. Lane map

Full partition: [`_LANES.md`](_LANES.md) — 27 lanes, owners, justification receipts,
dependency edges, `tests:` blocks in the WO-04 slice-contract grammar. Clusters:

- **A — Substrate daemon** (01-05): lock-per-window daemon, namespace isolation,
  port+lock elimination, auth-mode listeners, client auto-routing.
- **B — Receipts/query** (06-09): telemetry ingestion, query CLI, index sync, drift
  elimination.
- **C — Build cache** (10-12): contract hasher, shared build cache, artifact purge.
- **D — Slice testing** (13-16): slice contracts, integration gate protocol, fast
  pre-flight, mutation gating at integration.
- **E — Superfans + DoD** (17-20): substrate/court/receipts superfans and the DoD
  standing matrix.
- **F — Sharpened list** (21-27): carry-forwards (21 shim court, 22 kd_flip, 27 wave
  telemetry) + stub WOs (23 proxy, 24 SDK docs corpus mining, 25 flake quarantine,
  26 seeded cross-suite regression).

## 3. Session-carried assets already landed (de-risk the window)

- `scripts/substrate.sh` — lock held per-WINDOW, child fd-closed; kills the C1 class at
  its source (dod-01-substrate-lock).
- `test/support/` `ensure_store_up/0` — store restart+wait helper; seam S1 carries it
  forward as infrastructure, hand-rolling is a defect (RESOLUTIONS S1).
- `scripts/shim_court/` — phase-structured shim court harness, distinct from full-court
  protocol (S7); lane 21 maintains, does not re-implement.
- `scripts/kd_flip.py` — receipt-gated KD row flipping (lane 22 carries forward; cite
  `receipts.py standing`).
- `scripts/wave_telemetry.sh` (+ `just wave-report`) — wall-clock JSONL store; makes
  the Measure exit criteria checkable next window (WAVE_TELEMETRY.md, T4).
- receipts.py-class query tooling — T5 law: query, don't restate; kills the C6 class.
- The slice-contract `tests:` grammar (WO-04) — hosts lane test blocks, quarantine tags
  (lane 25), and mutation-gating proofs (lane 16).

## 4. Adoption queue (ERRC wave, v26.10.14)

| item | verdict | note |
|---|---|---|
| bandit-WS for daemon WebSocket | KEEP (hand-rolled) | errc1-ws: 30 Python behavior pins; Elixir side ready but pins are Python-side |
| benchee | ADOPTED | errc2: `{:benchee, "~> 1.3", only: [:dev, :test]}`; hand-rolled loops kept as falsifier records |
| autocannon | ELIMINATE-candidate confirmed | errc3: replaces spike.py flood phase; script retained with dated note (docs/STRESS/SPIKE.md) |
| HDR histogram | ADOPTED | errc4: `hdr-histogram-js` re-emits B-2/B-3 percentiles; installed `--no-save`, package.json untouched |
| pyjwt | ADOPTED | errc5: `LocalSTS` HS256 sign/verify; exact ValueError contract preserved, tests green unchanged |
| stream_data / hypothesis | ADOPTED | errc6: property suites green on subject; no net lib edits |
| recon | ADOPTED | errc7: `{:recon, "~> 2.5", only: :test}`; no BEAM-level leak found — RSS-only evidence retired |
| sobelow | ADOPTED (non-gating) | errc8: 27 low-confidence findings, 0 high/medium; `just sobelow` records, does not gate |

## 5. Execution order and exit criteria

Cluster A first (01 → 02/03/04 → 05 → 17), because T1/T2 client and prefix seams feed
D-15 pre-flight, E-17 superfan, and F-23 proxy. Then B (06 after 27's store; 07/08/09)
and C (10 → 11 → 12) in parallel; D (13 → 14, 15, 16) after C-11 for build-root
interplay; E gates on 17/18/19; F stubs (23-26) must have WOs fully authored before
code (rule 5), carry-forwards (21/22/27) are maintenance-only (rule 4).

Dependency edges are per `_LANES.md`; seam laws T1-T5 (RESOLUTIONS.md) govern the
shared surfaces: substrate client (T1), prefix law (T2), slice grammar (T3), telemetry
store (T4), receipt query layer (T5).

**Define**: the window eliminates the C1-C6 classes at their coordination seams — a
lane's cost signal is a telemetry row, not archaeology; receipts cite query output, not
restated counts.

**Measure (exit criteria)**:
- Zero C1 orphans >5 min (`substrate-status` clean across the window).
- Zero C3 parse failures (slice-contract and receipt-index machinery parse clean).
- Zero C5 clobbers (no cross-lane state collisions witnessed in any lane receipt).
- Instrumented receipts: every v26.10.15 lane receipt carries a wall-clock section
  citing real `wave-telemetry.jsonl` rows.

## See Also

[`_LANES.md`](_LANES.md) · [`RESOLUTIONS.md`](RESOLUTIONS.md) ·
[`WAVE_TELEMETRY.md`](WAVE_TELEMETRY.md) ·
`docs/jira/v26.10.14/receipts/errc1-ws.md` … `errc8-sobelow.md`
