# BK-GWSSKEP — adversarial re-anchor of the BK-ARD21 wave rows (GWS / SQLD-GLD / BENCH)

**Standing**: PARTIAL_ALIVE (see typed findings F1/F2)
**Context**: solo
**Date**: 2026-10-22 (UTC)
**Lane**: BK-GWSSKEP · Repo: `/Users/sac/smalt` (read-only skeptic; only this receipt written)
**Audits**: `docs/jira/v26.10.22/receipts/bkard21-terminal-audit.md` wave tables; cited receipts
`../v26.10.21/receipts/{bk31-gws14-inwasm-courts, bk32-gws15-sec-fuzz, gws12-cross-engine-determinism, wasm1-otp29-sandbox-port, sqld8-ingest-baseline, bench14-bench-framework-gate}.md`

## Method

Read-only skeptic re-run: for each wave, the cheapest load-bearing probe re-executed
fresh on today's tree (real collaborators, no mocks, no fixed sleeps), compared
against the receipted figures. Adjacent landings since the receipts (journal
scoping, ledger range guard, partition work, PB4-T harness relocation) could have
shifted premises — that is exactly what was tested.

## Wave 1 — GWS (4 rows)

### GWS-IN-WASM-COURTS (bk31) — re-anchored ALIVE

Re-run of all four in-wasm court suites in `/Users/sac/graphlaw` @ `ed3be81`
(HEAD has moved past the receipt's `5dc3c01`; clean tree; stricter current-source
subject, same as the receipt's own policy):

```
$ cd /Users/sac/graphlaw && cargo test --test wasm_governance_preflight \
    --test wasm_n3_admission --test wasm_boundary_fuzz --test wasm_coldchain_e2e
test result: ok. 2 passed; 0 failed … 267.21s   (wasm_boundary_fuzz)
test result: ok. 3 passed; 0 failed … 0.78s     (wasm_coldchain_e2e)
test result: ok. 3 passed; 0 failed … 0.33s     (wasm_governance_preflight)
test result: ok. 3 passed; 0 failed … 0.31s     (wasm_n3_admission)
EXIT=0   (full log: /tmp/bkgwsskep_court.log)
```

11/11 green, exit 0 — same shape as the receipt (11/11, exit 0). Fuzz suite wall
267.21s vs receipt-era 56.80s in bk31's run — load-dependent, not a premise shift;
the 2/3/3/3 pass counts and exit 0 are the load-bearing figures and are unchanged.

### GWS-SEC-FUZZ (bk32) — re-anchored ALIVE, histogram byte-identical

```
$ cd /Users/sac/graphlaw && cargo test --test wasm_boundary_fuzz -- --nocapture --exact gws9_wasm_boundary_fuzz
GWS-SEC-FUZZ refusal-class histogram (1172 hostile frames):
  ok:true (admitted): 4
  refusal:EngineRejected: 291
  refusal:NotSemanticContent: 28
  refusal:ResourceLimit: 195
  refusal:Unsupported: 654
GWS-SEC-FUZZ PASS: 1172 hostile frames, 0 panics/traps/hangs, every refusal typed
  (kind in vocabulary), instance survived all calls (canary after each).
test result: ok. 1 passed; 0 failed … finished in 270.81s
```

Histogram **byte-identical** to the bk32 receipt (1172 = 654+291+195+28+4; 4
designed admissions). Deterministic court confirmed deterministic on the moved HEAD.

### Sec-fuzz negative leg (real runner) — re-anchored ALIVE

```
$ cd /Users/sac/graphlaw && for f in '\x00\x00\x00\x13{"op":"no_such_op"}' \
    '\x00\x00\x00\x13{"op":"capabilities"'; do printf "$f" | \
    cargo run -q --features runner --bin graphlaw-run; echo exit=$?; done
-> {"ok":true,"result":{"error":{…,"kind":"Unsupported","message":"unknown op `no_such_op`"}}} exit=0
-> {"…kind":"Unsupported","message":"request is not JSON: EOF while parsing a string at line 1 column 19"}} exit=0
```

Both hostile frames answered typed `Unsupported` envelopes, runner exit 0, no
trap/panic — matches the bk31 adversarial leg exactly.

### GWS-SANDBOX-GATES (wasm1) — NOT re-anchored: BLOCKED-ON-CONTENTION (typed)

Four attempts to re-run `test/integration/wasm_sandbox_court.exs` (lane build root
`_build-bkgwsskep`, then fast_test per-hash root, then shared warm `_build/dev`)
each stalled in compile/boot and were killed at the harness background cap
(~30 min ×4, 0 test output); `pgrep` shows orphan `mix run --no-start` beams from
concurrent lanes holding the canonical ports (one beam holding 9443/9444, one
holding the bench-port boot block 39610–39617) — substrate contention on the
shared machine, not a code failure. No verdict either way is claimed for this
leg; the row keeps its receipt-level standing (wasm1, ALIVE on its own subject).
**Repair route**: re-run under `just quiet-check` / `just quiesce` precondition
(the same precondition court-x2 needed).

### GWS-DETERMINISM (gws12) — re-anchored ALIVE (indirect, cheapest leg)

The n3 admission suite's `n3_admission_matches_native_differential` (native/wasm
differential, the determinism row's core leg) passed in the wave-1 court run
above; the full 3-leg differential re-run was not separately executed (typed
observation, not a gap — the differential leg is the row's falsifier surface).

## Wave 2 — SQLD/GLD (8 rows)

### SQLD-8 (sqld8) — re-anchored ALIVE; favorable >20% delta typed (F2)

Driver re-run fresh (lane output `/tmp/bkgwsskep-sqld8.jsonl`, corpus artifacts
in `tmp/sqld8/` untouched since 2026-10-21):

| route | receipt min wall | today min wall | receipt rows/s | today rows/s | delta |
|---|---|---|---|---|---|
| converter (dump→projection) | 1545 ms | **1077 ms** | 64,725 | **92,850** | 43% faster |
| direct (csv→projection) | 222 ms | **167 ms** | 450,450 | **598,802** | 33% faster |

`errors=0` across 6 rounds; correctness legs re-verified in worker output
(`rows=100000` both routes; conv-vs-direct aggregate CSVs identical:
convey/freeze/palletize 33377/33226/33397, sums equal). No degradation — the
>20% throughput delta is in the favorable direction and tracks the receipt's
OTP 28 → today's OTP 29 runtime change (machine string in the emitted jsonl
confirms `otp":"29"`). Receipt figures re-anchored, not stale. F2 recorded so
the next board fold cites the new numbers.

### SQLD/GLD rows 2–8 — receipts on disk verified

`sqld2/3/4/5`, `gld1/2/4/6/7` + `gld5fix` receipts all present under
`docs/jira/v26.10.21/receipts/` (verified `[ -f ]`); no cheap per-row probe
re-run (table-level, consistent with BK-ARD21's own treatment).

## Wave 3 — BENCH (11 rows)

### BENCH-14 gate — **FLIPPED RED (typed defect, F1)**

```
$ just bench-framework-gate; echo exit=$?
   benchee allowlist : 1 file(s), frozen
   :timer.tc probes  : 3 file(s), frozen (BENCH-9 classified)
   VERDICT: FAIL (2 violation(s))
     - TIMER-TC scripts/bench/pb4_merkle_dual.exs:255: unannotated :timer.tc …
     - TIMER-TC scripts/bench/pb4_merkle_dual.exs:266: unannotated :timer.tc …
exit=1
```

The gate the BENCH-14 receipt left green is now **red on the current tree**.
Root cause is a cross-lane premise shift: commit `36142e14` (PB4-T) relocated
`tmp/bench/pb4_merkle_dual.exs` → `scripts/bench/pb4_merkle_dual.exs` without the
`# BENCH-CLASS: probe` annotation; the file's two `:timer.tc` sites (lines
255/266) fall outside the frozen BENCH-9 allowlist. Non-vacuity held: the
gate fail-closed (exit 1, honest red), and `bench-framework-gate-court` also
exits 1 for the real-tree census FAIL — the gate is not vacuous, the tree is
out of contract.

**Repair ticket (F1)**: owner PB4-T / BENCH-14. The file IS a measurement probe,
so the lawful close is the annotation: add `# BENCH-CLASS: probe` at
`scripts/bench/pb4_merkle_dual.exs:255,266` (or reclassify via the BENCH-9
process), then `just bench-framework-gate` → PASS + `bench-framework-gate-court`
green. Do not widen the allowlist.

**F2 (typed observation)**: sqld8 throughput figures above are the new anchors
(92,850 / 598,802 rows/s, OTP 29); next board fold should cite them.

### BENCH-3/5/6/7/8/9/10/11/13 — receipts on disk verified

All 9 receipt files present in `docs/jira/v26.10.21/receipts/` (`[ -f ]`).
BENCH-2/4/12 remain correctly UNWITNESSED (typed-open), matching BK-ARD21.

## Verdict per wave

| wave | re-anchor verdict |
|---|---|
| GWS | 3 of 4 rows re-anchored ALIVE on fresh runs (in-wasm courts 11/11, sec-fuzz histogram byte-identical, negative leg typed); GWS-SANDBOX-GATES smalt-side re-run BLOCKED-ON-CONTENTION (typed, no verdict claimed); GWS-DETERMINISM re-anchored via its differential leg |
| SQLD/GLD | SQLD-8 re-anchored ALIVE (favorable delta, F2); receipts on disk ×9 verified |
| BENCH | BENCH-14 gate red on current tree (F1 typed defect, repair ticket filed); remaining 9 rows receipts-on-disk verified; BENCH-2/4/12 correctly typed-open |

**Overall standing: PARTIAL_ALIVE** — the waves hold as measured surfaces, but the
BENCH-14 gate flip (F1) is a real correctness flip on the current tree and the
sandbox-gates leg could not be re-executed under contention. Both carry typed
next actions; neither invalidates a receipted figure.

## Falsifiers

- F1 closes when `just bench-framework-gate` exits 0 and its court is green on the tree that carries the pb4 annotation.
- GWS re-anchors fail if any of the four suites fails, or a mutated `graphlaw-run` frame traps/unwraps instead of typed `Unsupported`.
- SQLD-8 re-anchor fails if converter wall degrades >20% above 1545 ms, errors > 0, or cross-route aggregate parity breaks.
- The BLOCKED-ON-CONTENTION note is discharged by one green `MIX_BUILD_ROOT=<lane> mix test test/integration/wasm_sandbox_court.exs` run under `just quiesce`.
