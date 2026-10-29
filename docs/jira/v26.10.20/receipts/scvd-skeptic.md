# SCVD-T14 — Skeptic Audit of the SCVD Wave Receipts

**Standing:** **PARTIAL_ALIVE** — every figure below was re-read from on-disk jsonl
at audit time (2026-10-21); the only live re-execution is T1 (reproduced). No
number here is taken from prose without a disk cross-check.

## Reproduction (T1 re-run, this audit)

- Exact command: `NODE_EXTRA_CA_CERTS=/Users/sac/smalt/.smalt/tls/ca-cert.pem node /Users/sac/smalt/tmp/bench/scvd_tier1.mjs`
- Substrate: beam.smp pid 56472 LISTEN 127.0.0.1:9443 (ARM/STS) + 9444 (TLS
  data plane). 9444 returns 401 unauthenticated — live, auth-enforcing. NOT
  restarted (loud-SKIP contract honored; substrate up, so no SKIP).
- Result: 4th row appended to `tmp/bench/scvd-tier1.jsonl`: ops_per_sec 2442.9,
  errors 0, `verdict: PASS` — 1.04x of the best on-disk row (2540.5), within the
  2x reproduction budget. **T1 REPRODUCED.**

## Per-lane verdicts

### T1 — scvd-tier1.jsonl: ALIVE

- 4 rows (3 original + 1 audit re-run), all `verdict: PASS`, errors 0.
  Typed verdict field present (`verdict`), Context present (`machine` object).
- Substrate-side bug disclosed only in a code comment (scvd_tier1.mjs:46-48):
  GET on a non-existent db returns 500 instead of 404, crashing the SDK's
  read-first probe. Appears in NO receipt prose — unwitnessed substrate defect
  observation; should be a KD row.
- Harness fragility: launching without NODE_EXTRA_CA_CERTS crashes with
  RestError UNABLE_TO_VERIFY_LEAF_SIGNATURE. Loud, but does not distinguish
  "substrate down" from "harness env missing" — the T5 run-1 FAIL was exactly
  this.

### T2 — scvd-tier2.jsonl: ALIVE, with a serious receipt-hygiene defect

- 4 rows. One PASS row (n=1024, errors 0, 2245.6 ops/s, wall 456 ms vs 30000 ms
  budget) — typed and self-consistent; this alone supports "T2 PASS", and only
  at n=1024.
- The 3 FAIL rows (n=512): `errors: 512` (every op errored), `standing: "FAIL"`,
  ~2600 "ops/s" in ~190 ms — fail-fast erroring makes the throughput figures on
  these rows meaningless. Two problems:
  1. No typed defect marker. No `defect:` / `classification:` field anywhere in
     the file; on a cold grep, `standing: "FAIL"` reads as substrate failure.
     "Harness-defect" exists only as prose in scvd-wave-summary.md ("harness-defect
     rows, not a surface pass") — no mechanism, no root cause, no closing row.
  2. "Harness-defect" appears only in scvd-wave-summary.md and nowhere in the
     jsonl or INDEX; root cause of the 512/512 errors never stated on disk. The tier2
     harness script is NOT on disk (tmp/bench holds only scvd_tier1.mjs,
     scvd_tier4.mjs, scvd_tier5_chaos.mjs; scripts/bench has scvd_tier12.mjs for
     a different tier), so the rows are UNREPRODUCIBLE and the defect cannot be
     closed. Repair: re-run T2 with the scvd_tier12.mjs harness family, append
     corrected rows, retire the n=512 rows explicitly (typed `defect:` field).
- `machine` Context is a double-encoded JSON string (T2/T3) vs object (T1/T4) —
  typed but schema-inconsistent across the wave.

### T3 — scvd-tier3.jsonl: ALIVE (wall honest)

- 8 rows. Wall at L8192: ramp-512/1024/2048/4096 all errors 0,
  `wall_level: unreached`; ramp-8192 row n=15850, 508.6 ops/s, p50 11.6 s,
  534 errors; closing `wall-summary` row `wall_level: L8192`, typed
  typed_fail_512: true. Typed wall disclosure is the honest form.
- Defect: `machine` string-encoded Context (as T2); harness script absent from
  disk (same unreproducibility as T2); the two stale `wall-summary` rows with
  `typed_fail_512: false` sit alongside the true one — a cold reader could
  pick the wrong summary row unless reading in order.
  typed_fail_512 false-rows pre-date the wall run; they are stale-but-honest
  history, disclosed in scvd-wave-summary.md as such.

### T4 — scvd-tail.jsonl: SUSPECT (typed breach, harness-side fence doubt)

- 10 rows: 9 measurement (c1/c16/c128 x 3 rounds, errors 0) + 1 verdict row.
  Verdict row is typed: `verdict: INVARIANCE-BREACH`, ratio 188.79 vs fence 10.
- Skeptic objection: the fence compares p99 at in-flight depth 128 against p99
  at depth 1 with a single scalar fence of 10. Even a perfect substrate shows
  queueing-scaled tail at depth 128; the same disk shows the substrate holding
  ~2200-2900 ops/s at c128 with 0 errors (T2 n=1024, T1 legs, T5 recovery),
  so a 188x p99 growth is more consistent with a fence-definition artifact than
  a substrate regression. The wave-summary correctly classifies it SUSPECT-class
  standing. Do NOT book it as a substrate failure until a concurrency-aware
  fence (e.g. fence per in-flight depth, or p99-per-op-budget) is defined.
- Harness note: scvd_tier4.mjs:124 exits 0 regardless of verdict
  ("record actual either way"), so automation cannot trip on a breach — the
  breach only exists if a human reads the jsonl.

### T5 — scvd-chaos-conn.jsonl: ALIVE (harness-defect row disclosed, but only in prose)

- 2 rows. Run 1 (17:44:06Z): flood 2000/2000 accepted, `refusal_class:
  accepted-all`, recovery failed 30 attempts, `recovery_error: "unable to verify
  the first certificate…"`, `verdict: FAIL`. Run 2: recovery on attempt 1
  (594 ms total), `verdict: PASS`.
- The FAIL row's root cause (missing NODE_EXTRA_CA_CERTS in the recovery leg —
  harness env defect, not substrate) is disclosed ONLY in the lane receipt
  docs/jira/v26.10.20/receipts/scvd-t5-conn-exhaustion-chaos.md, which states
  "This is a harness environment defect (run 1 did not source the T1 env), not a
  substrate fault; flood leg identical (2000/2000 accepted). Both rows retained
  for honesty." The disclosure exists, is typed nowhere. A grep-verdict "FAIL"
  against the jsonl alone reads as substrate failure.
- Additional observation the lane receipt honestly records: refusal_class
  "accepted-all" at n=2000 means the exhaustion threshold was never reached —
  "chaos PASS" is recovery-pass, not refusal-exercised.
- Context field is `machine: "darwin"` — a single-word string, the thinnest
  Context in the wave and below the standard set by T1/T4.

### T6 / T12 (context rows, cross-checked) — ALIVE as recorded

- scvd-wasm-vs-host.jsonl / scvd-blob.jsonl exist and are typed per-row.
  scvd-wave-summary.md transcribes them faithfully (T12 cold-row 278.3 ops/s
  included; contrary to the dispatch claim of T12 pending/UNWITNESSED).

## Lanes not on disk — UNWITNESSED

- `test/internal/scvd_concurrency_courts.exs` — absent. No gate exists.
- `justfile.d/NN-scvd.just` — absent. No orchestration recipe exists.
- INDEX.md carries ZERO scvd entries — the entire SCVD wave is unindexed;
  scvd-wave-summary.md itself is not in receipts/INDEX.md. Until indexed,
  the wave is unreachable from the receipt index.

## Prose-only claims killed (UNWITNESSED/REFUTED)

- None of the transcribed numbers in scvd-wave-summary.md were found wrong —
  every spot-checked figure matches the jsonl. Killed claims are structural:
- Kill: "T2 PASS" as an unqualified headline — PASS exists only at n=1024; 3
  FAIL rows stand unretired with no typed defect marker and no on-disk harness.
- Kill: "T5 PASS" as an unqualified headline — PASS on run 2 only; run 1 is a
  typed FAIL row, disclosed only in prose, and the flood never forced refusal
  (accepted-all), so exhaustion was never exercised.
- Kill: any reading of the T4 INVARIANCE-BREACH as substrate failure — SUSPECT
  fence-definition artifact is at least as likely; needs a concurrency-aware
  fence before it can be booked.

## Typed-verdict + Context compliance matrix

| Lane | Typed verdict field | Context field | Defect rows typed as defect? |
|---|---|---|---|
| T1 | yes (`verdict`) | object | n/a |
| T2 | yes (`standing`) | string-encoded JSON | NO |
| T3 | typed_fail_512 / wall_level | string-encoded JSON | partial |
| T4 | yes (`verdict`) | object | n/a |
| T5 | yes (`verdict`) | `machine: "darwin"` | NO (prose-only disclosure) |
| courts exs / NN-scvd.just | absent | absent | UNWITNESSED (files missing) |
| INDEX.md | n/a | n/a | wave unindexed |

## Bottom line

The wave is PARTIAL_ALIVE: T1 reproduced within 1.04x (well inside 2x). T3's
L8192 wall is the honest typed ceiling. T4 breach is typed but fence-suspect.
The two systematic hygiene defects to fix before the wave can be called green:
1. Harness-defect FAIL rows (T2 x3, T5 run 1) carry no typed defect marker;
   root causes exist only as prose in lane receipts. Add a typed `defect:`
   field and on-disk harness scripts for T2/T3.
2. The wave is unindexed (INDEX.md has zero scvd rows) and its gates are
   missing (no courts exs, no justfile recipe) — the wave cannot be
   re-admitted by automation.
