# DRAFT — GATED ON TWO-GREEN (do not promote to docs/RELEASE_NOTES_v26.10.17.md until the bump lane lands after two-green)

Prepared release-notes text below. NOT landed. Version on disk stays
`26.10.16` until WO-4 runs post-two-green. Standing at draft time:
**TYPED-RED** — court-x2 gate closed honest RED after attempts 1–3;
attempt 4 queued post-i21 (receipt chain
`receipts/r240-court-x2-attempts12-typed-red.md` →
`receipts/r241-court-x2-attempt3-typed-red.md`).

---

# Release Notes — smalt 26.10.17

Third release of smalt: the v26.10.14 substrate (local Azure drop-in on
the BEAM — ARM control plane `:9443`, TLS twin `:9444`, data plane
`:8443`, AMQP Service Bus `:5672`, Event Hubs `:5673`, MCP `:9545`,
loopback only) advanced by a court-RED-closure wave plus the i21 repair
wave. The surface inventory is unchanged from v26.10.16; this window's
work is parity repair, flake repair, publish unblocking, and an honest
court chain. Standing for this document: **TYPED-RED** — court-x2 gate
closed honest RED after attempts 1–3 (receipt chain
`receipts/r240-court-x2-attempts12-typed-red.md` →
`receipts/r241-court-x2-attempt3-typed-red.md`): attempt 1 RED (WasmEngine
"restart hammer", `test/affidavit_wasm_failclosed_test.exs:502` + sdk-smoke
watchdog exit 124), attempt 2 RED (EgressDispatch "batch-list boundary",
`test/egress_dispatch_test.exs:1221`), attempt 3 RED both legs (4 failures
then fence-10 repeat). **35 completed gate invocations, 0 two-green**
(32 prior + 3 this window); attempt 4 queued after the i21 repair wave's
verification receipts. Every tripped face is solo-green on the same tree
(r241 §Solo verification); fence 10 was upgraded CONTENTION →
**PERSISTENT-FLAKE** by the r241 skeptic catch (it repeats under court
load in BOTH attempt-3 legs) and is now repaired deterministically (see
below). Standing flips only on a green two-run receipt; see
`docs/jira/v26.10.17/FINAL.md`.

Publish standing: **B1 CLOSED 2026-10-17** (`PUBLISH_RECORD.md` addendum,
witness `receipts/r244-publish-record.md`) — ex4pm 26.10.8 is published to
hex and smalt's `mix.exs` carries the hex-only pin
(`{:ex4pm, "~> 26.10.8"}`; override dropped; `ash_ex4pm` remains
dev/test-only optional), `mix.lock` resolves ex4pm 26.10.8 from `:hexpm`,
and the full `publish-dry` gate set is **4/4 PASS** (hex.build /
inner-tar keys grep / packaged-set leak grep / error-codes check). The
former TYPED-BLOCKED standing (B1 sole refusal-class blocker) no longer
applies. Remaining release gate: court-x2 two-green (attempt 4 queued
post-i21).

## What changed

- **i21 repair wave (r241 faces closed deterministically)**
  - **Fence 10** (`test/affidavit_wasm_failclosed_test.exs:502`) — the
    PERSISTENT-FLAKE 100 ms wall-clock bound replaced by a deterministic
    **250 ms** bound equal to the engine's own
    `@start_retry_delay_ms 250`: one leaked retry sleep guarantees
    >=250 ms (RED provably); clean refusals are single-digit ms solo,
    129 ms witnessed worst-case under load. 5x solo green + green under
    artificial load (`receipts/i21-fence10-fix.md`).
  - **EgressDispatch setup ETS race** — bounded typed retry
    `resilient_clear/1` (50 retries, 10 ms backoff) around
    `ensure_store_up()` + `Store.clear/0`, rescuing only the exact
    dead-table `ArgumentError`; test-side only
    (`receipts/i21-ets-race-fix.md`).
  - **LRO op-record face** (`test/lro_test.exs:543`) — fixed
    sleep + single sweep replaced with `sweep_until_terminal/3`
    (5 s bounded, typed failure naming offending record keys + rid);
    33/0 solo x3 (`receipts/i21-lro-face.md`).
  - **broker_facade Sweeper-whereis-nil face** — fresh
    `start_supervised!(Sweeper)` fallback when the shared singleton was
    torn down mid-flight; 3x solo + 1x paired green
    (`receipts/i21-brokerfacade-sweeper.md`).
  - **Blob pagination perf budget 110 → 180 ms** — min-of-5 reps, with
    regression math in the block comment: old budget flaked quiet
    (128 ms witnessed); loaded 138/119/170; the revert class
    (full-value materialization) estimates ~205 ms quiet, so 300 ms
    would NOT fence it — 180 ms separates the classes
    (`receipts/i21-blob-budget.md`).
  - **Churn test budget 300 s → 600 s** (`test/store_dets_test.exs`,
    measured churn profile cited)
    (`receipts/i21-churn-budget.md`).
- **Blob HEAD conditionals + header parity (KD-97 CLOSED-SIMULATED)** —
  the blob HEAD arm mirrors the GET RFC 7232 engine (412/304/206/416,
  empty bodies); `x-ms-request-id` + `x-ms-version: 2021-12-02` stamped on
  every blob arm; `x-ms-range` beats `Range` on concat order in GET and
  HEAD. Landing receipt `receipts/r239-kd97-conditional-head-landing.md`:
  49/0 c4_blob + 116/0 blob_hardening + 22/0 egress_wire (was 19 c4
  failures pre-window).
- **EventGrid eg1 readback divergence closed** — eg1_publish re-domained
  onto the shared EventStream counter
  (`receipts/i20f-egmerge-fix.md`).
- **DetsMirror sync contention** — `DetsMirror.sync/1` call timeout 5 s →
  30 s with the contention-mechanism citation
  (`receipts/i20b-contention-mechanism.md`).
- **Compliance corpus first green** — `test/corpus_test.exs` 26/0
  (2026-10-17) with per-file ever-green first witnesses (e.g. C6 OAuth
  18/0, `receipts/i20h-c6-first-witness.md`).
- **KD register** — 95 rows (KD-01..KD-97), **39 CLOSED / 55 OPEN**
  (canonical recount in `docs/jira/v26.10.17/COUNTERS.md`); KD-97 minted
  and flipped CLOSED-SIMULATED this window via `scripts/kd_flip.py --apply`
  gated on the r239 witness. GAP tokens all remain OPEN in
  `docs/WIRE_PARITY.md` (receipt-gated flips only).

## Test-isolation leak remediation

New honest leak court `gates/test_isolation_leak_gate.py` (first-run
verdict `FAIL-TREE-LEAKS offenders=56`, non-vacuity fixtures 3/3 REFUSE,
`receipts/i20e-leak-court.md`) followed by the i21 remediation batches 1–3
(env-restore discipline across `auth_enforce`, ETS identity suites, and
more — `receipts/i21-leak-batch1.md`..`batch3.md`). Leak court now reports
**101 uncovered mutations across 47 files — delta 122 → 101 (−17.2%)**
(`receipts/i21-leak-court-delta.md`). The gate still exits 1 by design
while findings remain and is not yet wired into `just court`; clearing the
remainder and wiring it is next-window work.

## Harness mechanisms

- `just quiet-check` / `just quiesce` — idle-machine and warm-up gates
  exercised as court attempt-3 preconditions.
- Leak-court recipe, NO-CONTEXT flag, rewitness, wt-scratch, corpus-soak
  (`7b42734`).
- `RECEIPT_CONTEXT_LAW` (`docs/jira/v26.10.17/RECEIPT_CONTEXT_LAW.md`) —
  receipt-cited counts are re-read from the receipt at use time; the
  NO-CONTEXT flag marks context-free receipts loudly.

## Honest court chain

35 completed court-x2 invocations, 0 two-green across v26.10.16 +
v26.10.17 — this window ran fix-and-retry (attempt 1 → typed face fixes
landed → attempt 2 → different face → attempt 3 with quiet-check/quiesce
preconditions → TYPED-RED, gate closed). Attempt 4 is queued after the
i21 repair wave's verification receipts. The ledger is carried forward,
not reset; the full inventory is in `docs/jira/v26.10.17/FINAL.md`
(court inventory table) and `docs/jira/v26.10.17/WRAP_LEDGER.md`. Parks:
court-x2 attempt 4, leak-court remainder + wiring, KD-77 PASS re-witness —
all queued in `docs/jira/v26.10.17/NEXT_WINDOW.md` (the v26.10.18 mint).
