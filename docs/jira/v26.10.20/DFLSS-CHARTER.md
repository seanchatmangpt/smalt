# DFLSS-26.10.21-SMALT — DMADV Charter (v26.10.20 window)

Standing: **PARTIAL_ALIVE** — structure per the operator's DFLSS-26.10.21-SMALT charter
business case/FMEA; every CTQ cell below carries its on-disk measured standing. All
aspirational charter numbers are marked **OPERATOR-ASSERTED** (not repo-measured) per the
no-overclaiming law. Compiled 2026-10-21 from disk evidence only.

## 1. Define

- **Project**: smalt loopback cloud-edge emulator as a displacement surface for Azure
  dev/test spend ("popcorn" family) and its migration tooling (`smalt-cli migrate`).
- **Method**: DMADV (Define / Measure / Analyze / Design / Verify).
- **Business case (OPERATOR-ASSERTED)**: baseline Azure dev/test spend of
  $660K-$1.2M/yr. **Not repo-measured** — no on-disk inventory, invoice, or rate-sheet
  evidence exists for any enterprise baseline; the largest measured on-disk anchor is the
  COST-4 50-resource fleet model at ~$246/mo ≈ ~$2,955/yr at list (SCENARIO mix). The gap
  between operator baseline and measured anchor is the charter's own top risk; closing it
  requires U1 (real-estate scan) of the COST-4 receipt.
- **Goal statement**: at-parity dev/test substitution inside the measured envelope, with
  every out-of-envelope claim scoped, typed, and receipted.
- **In scope**: data-plane surfaces (cosmos/blob/KV/SB/EH/ARM/App Config), the TLS twin,
  smalt-migrate rehearsal, bench lanes, and the value-displacement model.
- **Out of scope**: production workloads, EA/reserved pricing (COST-4 U5), serverless
  Cosmos purchase option (COST-4 U2), cross-region/inter-AZ egress channels.

## 2. Measure — measured anchors (all re-read from on-disk receipts/jsonl, 2026-10-21)

| id | anchor | value | source |
|---|---|---|---|
| M1 | Serial latency floor (kv-get p50) | 0.519 ms | `receipts/scvd-t23-serial-floor-profile.md` (ALIVE, measured-only) |
| M2 | Serial floor, cosmos point-read / blob GET p50 | 0.687 / 1.369 ms | T23 same table |
| M3 | Concurrency wall | L8192 (typed, `typed_fail_512`); 0 errors through ramp-4096 | `receipts/scvd-wave-summary.md` T3 + `tmp/bench/scvd-tier3.jsonl` |
| M4 | In-browser ramp(256) | all 256 actors `:verified`, 0 breaches | `receipts/scvd-browser-ramp-witness.md` |
| M5 | In-browser c128 determinism | `w8/l120/committed8` identical across 3 runs | same receipt |
| M6 | Tail-invariance fence v2 | INVARIANCE-HOLDS (F1/F2/F3 conjunctive), 7/7 at 9-run re-measure | `receipts/scvd-wave-summary.md` T4 + `scvd-wrap.md` §w15c-tail9 |
| M7 | Soak RSS (beam) | peak 1,221,520 KB ≈ 1.16 GiB; end 904,288 KB; start 621,536 KB | `tmp/bench/scvd-soak.jsonl` (2 rows, verdict FAIL on drift, errors 0) |
| M8 | Displacement (measured ledger) | apex2 $0.0133, apex4 $5.8413, witness-all $5.84; floors dominate | `popcorn_demo/bench/displacement-ledger.md` (COST-2, COMPUTED-FROM-PUBLISHED-RATES) |
| M9 | SB workload, measured | 1,024 ops, 0 errors, bills $0.00 ops; $9.81/mo is pure floor attribution | COST-4 §6 (COST-5 measurement) |
| M10 | Egress | $0.00 measured (4.3 MB, inside free tier); 500 GB rehearsal = $32 SCENARIO | `receipts/cost3-egress-quantification.md` |

## 3. Analyze

- **Floors dominate the bill**: a Cosmos dev/test account bills $5.84/mo at 16 ops or
  1,024 writes alike (two measured ledger rows land on it); KV and blob carry no base
  floor. Displacement scales with fleet size, not usage — the honest chain is floors ×
  fleet size (COST-2/4).
- **Parity is envelope-scoped**: measured envelope ≤1,024-op bursts, ramps 0-error to
  L4096, typed wall at L8192 (M3); beyond the wall the "at parity" claim does not hold
  and is scoped down, not eliminated (`receipts/scvd-value-discovery.md`).
- **Fence-definition risk surfaced and retired**: the T4 v1 scalar p99 ratio measured
  queueing depth, not regression; fence v2 (F1 throughput floor / F2 depth envelope /
  F3 zero errors) is the verdict basis (M6). Charter lesson: CTQ fences must be
  sleep-free and depth-aware by construction.
- **Backpressure MEDs**: two HIGH unbounded accumulators on EventGrid, implicit 5 s
  `GenServer.call` timeouts on Store/EventGrid/EventHubs (MED) —
  `receipts/scvd-backpressure-audit.md`. Typed call timeouts + AMQP conn cap landed in
  the latest checkpoint commit (5b8ec75); closure receipts pending at charter time.

## 4. CTQ table (measured standing, not aspiration)

| CTQ | characteristic | target | measured standing (as of 2026-10-21) | status |
|---|---|---|---|---|
| CTQ-1 | Local displacement cost | **$0.00/mo** local compute | MEASURED $0.00 local cost per ledger row (M8); floors-dominate chain confirmed by measured SB workload (M9); egress $0.00 measured, $32/500 GB SCENARIO (M10). Anchored to COST-2/COST-4, standing COMPUTED-FROM-PUBLISHED-RATES | **MEASURED — HOLDS** |
| CTQ-2 | Latency | serial p50 ≤ 1.5 ms working-SDK path | MEASURED: kv 0.519 / cosmos 0.687 / blob 1.369 ms p50 (M1/M2, T23 ALIVE); envelope: ramps 0-error to L4096, typed wall L8192 (M3); tail-invariance fence v2 HOLDS 7/7 (M6). **UPDATED (T25, `tmp/bench/ctq2-txn.jsonl`): transaction gate PASS — 100 txns 0 errors; cold p99 25.962 ms vs 500 ms budget (wide margin); warm p99 9.931 ms vs 15 ms budget — warm margin is THIN (66% of budget, single-lane n=50 on M3 Max), fence-sensitive; txn shape cosmos-CAS-put+kv-set+blob-put+sb-send+cosmos-read-back** | **MEASURED — HOLDS inside envelope** |
| CTQ-3 | Concurrency soundness | deterministic under contention, typed walls, chaos recovery | MEASURED partially: in-browser ramp(256) verified, c128 determinism 3/3 identical (M4/M5); T5 chaos recovery PASS on run 2, run-1 cert-verify recovery failure recorded. **PENDING-POWL**: POWL2 gate work in flight — no on-disk receipt yet; c256 host-side determinism fence not yet authored (the 256-actor witness is in-browser only) | **PARTIAL — PENDING-POWL** |
| CTQ-4 | Memory | bounded RSS under sustained soak | PARTIALLY MEASURED: `scvd-soak.jsonl` records beam_rss_peak 1,221,520 KB (≈1.16 GiB), end 904,288 KB — real RSS columns exist, but both soak rows verdict FAIL on throughput drift (-41%/+25%), so the RSS figure is a real measurement under a FAILING soak, not a passing-budget witness. **UPDATED (T28, `tmp/bench/ctq4-memory.jsonl`): browser side WITNESSED — JS heap peak 3.65 MiB across 3 headless-Chromium runs (11.6% of the 32 MiB arena budget; scope = main-thread JS heap only); whole-page `measureUserAgentSpecificMemory` 87.4 MiB under COOP/COEP recorded as context (includes browser+worker overhead, not 1:1 vs arena budget); WASM linear arena directly UNMEASURABLE (typed): Popcorn exposes no WebAssembly.Memory handle on window and beam.emu.mjs worker evaluate times out — close condition is Popcorn-side instrumentation exposing the worker's WebAssembly.Memory. Host beam RSS 763.8–3322.0 MB sampled during tier1 ramp recorded as context only — the 32 MiB budget binds the client WASM arena, NOT the host beam.** Measurement still needed to close: a soak run with drift inside fence; V3 unchanged | **PARTIAL — browser heap witnessed, arena UNMEASURABLE (typed), soak PASS row + RSS budget fence still pending** |

## 5. Design

- Envelope-first design law: every performance/cost claim carries its measured envelope;
  out-of-envelope behavior is typed (wall levels, refusal classes), never silent.
- Generated-artifact law: CTQ status regenerates from receipts, never hand-edited — this
  charter's §4 is the hand-compiled snapshot; the receipts directory is ground truth.
- Fence law: every CTQ target must eventually attach to a fail-closed fence with a
  non-vacuity court (pattern: T4 fence v2, sleep-gate, shim courts).

## 6. Verify — open verification debts

| # | debt | closes when |
|---|---|---|
| V1 | POWL2 gate receipt (CTQ-3) | POWL2 gate lands with a witnessed court receipt |
| V2 | c256 host-side determinism fence | fence authored + witnessed under `tmp/bench/` with a PASS row |
| V3 | Soak PASS row with RSS budget (CTQ-4) | soak row verdict PASS with drift inside fence and an explicit RSS budget line |
| V4 | Backpressure MED closure receipts | typed-timeout/conn-cap fixes get witness receipts postdating `scvd-backpressure-audit.md` |
| V5 | Operator baseline evidence | real estate scan / rate sheet closes COST-4 U1/U5; until then the $660K-$1.2M figure stays OPERATOR-ASSERTED |

## 7. FMEA (summary, faithful to the operator charter)

Ranked risk items, RPN-ordered; failure modes with no on-disk measurement carry the
measurement that would move them (per no-overclaiming):

1. **Baseline overclaim (highest RPN)** — quoting $660K-$1.2M without U1/U5 evidence
   converts the charter into unreceipted assertion. Detection: receipt-index/skeptic
   review. Mitigation: OPERATOR-ASSERTED marking (done here) + V5.
2. **Envelope escape** — an "at parity" claim quoted without its L4096/L8192 wall.
   Mitigation: CTQ-2/3 statuses carry envelopes inline; COST-4 U6 names the
   wall-as-boundary measurement.
3. **Fence rot** — scalar latency fences re-measuring queueing depth (T4 v1 lesson).
   Mitigation: conjunctive fences (F1/F2/F3 pattern), non-vacuity courts.
4. **Mock laundering** — a simulated displacement figure mistaken for a measured ledger
   row. Mitigation: standing vocabulary (COMPUTED-FROM-PUBLISHED-RATES vs MEASURED vs
   SCENARIO) on every dollar line, as in COST-2/4.
5. **Unbounded accumulators** — EventGrid HIGHs / implicit call timeouts.
   Mitigation: backpressure audit + typed timeouts + AMQP conn cap (V4 closes).
6. **Soak drift masked by averages** — a FAIL drift row averages into a healthy p50.
   Mitigation: rate_first10s/last10s drift columns in soak jsonl (already present).

---
*Addendum (BK-BMIR2, 2026-10-22): the `tmp/bench/ctq2-bshape.jsonl`, `tmp/bench/ctq4-memory.jsonl`, `tmp/bench/scvd-soak.jsonl`, `tmp/bench/scvd-tier3.jsonl` evidence cited above now has tracked byte-identical mirrors at `docs/jira/v26.10.20/bench/` (ctq2-bshape, ctq4-memory, scvd-tier3; scvd-soak pending-with-owner — not yet snapshotted); paired-sha256-verified, provenance `docs/jira/v26.10.20/bench/PROVENANCE.md`.*

*Addendum (BK-BMIR3, 2026-10-22): the residual `tmp/bench/ctq2-txn.jsonl` and `tmp/bench/scvd-soak.jsonl` evidence cited above (typed pending-with-owner by BK-BMIR2) now also has tracked byte-identical mirrors at `docs/jira/v26.10.20/bench/ctq2-txn.jsonl` and `docs/jira/v26.10.20/bench/scvd-soak.jsonl`; paired-sha256-verified, provenance `docs/jira/v26.10.20/bench/PROVENANCE.md` (wave 3).*
