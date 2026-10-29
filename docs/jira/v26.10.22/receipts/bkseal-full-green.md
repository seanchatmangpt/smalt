# BK-SEAL: full-green HEAD sweep

- **Standing**: PARTIAL_ALIVE
- **Context**: solo
- **Date**: 2026-10-22 (lane BK-SEAL, MIX_BUILD_ROOT=_build-bkseal, PATH asdf shims first)
- **Scope**: full ladder re-run on the moving HEAD (fleet converging; HEAD advanced twice during the sweep: 37568d4c → 514b1100, tick checkpoints 61ecfc39/e8247a79 landed mid-run)

## Stage 1 — mix compile --force

**Exit 0. 101 compiler warnings** (unused-variable / unused-attribute / discouraged
`Application.get_env` class, all in test/ — lib/ clean in the tail). Tail:

```
└─ deps/plug/lib/plug/router.ex:1335:19: Smalt.Mcp.Router.invoke/2
Generated smalt app
EXIT:0
101   <- warning count
```

**PASS.**

## Stage 2 — mix test (offline suite)

Three runs, each real:

1. **Run 1 (HEAD 37568d4c)**: EXIT 1 — **compile-abort** (census law: 0 tests
   executed, not a failure count) in `test/internal/bkcells_ard_cas_gate_test.exs`
   (`MismatchedDelimiterError` unclosed `(` at line 75). File was DIRTY at run time
   (`git status`: ` M test/internal/bkcells_ard_cas_gate_test.exs`) →
   **in-flight-owned (BK-CELLS lane)**. Wait-retry protocol applied.
2. **Run 2 (HEAD 514b1100 tree)**: EXIT 1 — compile-abort in
   `test/internal/expl6r1_journal_court_test.exs:55`
   (`0::binary-size(64)` conflicting bitstring type spec). During the bounded wait the
   file's owner repaired it on disk (now `0::integer-size(512)`) and the coordinator
   landed it via tick checkpoint 61ecfc39 — **transient mid-edit state, since landed
   fixed; not a HEAD defect at final observation**.
3. **Run 3 (final tree, 514b1100)**: EXIT 2 — **735/739 passed, 4 failures**, real line:

```
Finished in 267.4 seconds (2.3s async, 265.0s sync)
Result: 735/739 passed
Failed: 4 tests
EXIT:2
```

**Classification of the 4 failures — all census-population fences in
`test/internal/internal_tier_census_test.exs` tripping on OTHER LANES' new/in-flight
test files (root cause: files present in test/internal without census registration /
allowlist entry). No lib/ or behavioral failure. Not fixed by this lane (other lanes'
files).**

| # | test | tripped by | owner lane |
|---|---|---|---|
| 1 | every Smalt-prefixed module reference inside closed allowlist | `bkamqpf_f2a_boundary_court_test.exs` (2 refs), `eplaw_ephemeral_boot_court_test.exs`, `kd173r_audience_scope_court_test.exs` off-allowlist | BK-AMQPF, BK-EPLAW, KD-173R |
| 2 | population fence: test/internal exactly registered files | on_disk unregistered: `bkamqpf_f2a_boundary_court_test.exs`, `eplaw_ephemeral_boot_court_test.exs`, `kd173r_audience_scope_court_test.exs` | same 3 lanes |
| 3 | no unaudited pacing token outside the audited poll helper | `eplaw_ephemeral_boot_court_test.exs` — `Process.sleep(250)`, `Process.sleep(100)` (violates no-sleep doctrine test-side law) | BK-EPLAW |
| 4 | no HTTP status literal co-occurs with assert on same line | `kd173r_audience_scope_court_test.exs` — two `assert {:error, {401, ...}}` lines | KD-173R |

## Stage 3 — just invariant-gates

**Exit 0, 6/6 PASS** (positive held + all negative fixtures refused):

```
  appconfig-etag-cas   PASS
  blob-worm            PASS
  cosmos-etag-cas      PASS
  ledger-chain         PASS
  lock-clamp           PASS
  queue-capacity       PASS
[INVARIANT-GATES] PASS: 6/6 gates (positive held + all negative fixtures refused).
EXIT:0
```

## Stage 4 — sleep-gate + sleep-gate-court

**Both exit 0.** Court non-vacuity witness (embedded output):

```
[SHIM] AFTER witness passed (new outcome holds under shim)
[SHIM] RESTORE verified byte-exact (sha256 match)
[PASS] sleep_gate_court: non-vacuous (BEFORE old-signature, AFTER new-outcome, restore verified)
[PASS] sleep_gate court: clean PASSES, injected sleep REFUSED (test + lib + burn + dual-naming + verification TS/PY + py-allowlist + dual-tree + popcorn lib/sh/mjs), restore byte-exact
SG-EXIT:0
SGC-EXIT:0
```

## Stage 5 — just docs-dod-check

**Exit 0** (all receipt paths named in docs exist; OK lines for every milestone
RECEIPTS.md/FINAL.md/KNOWN_DIVERGENCES.md/RELEASE_NOTES). Tail:

```
OK    docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
OK    README.md
DOD-EXIT:0
```

## Stage 6 — python3 scripts/receipt_index.py

**Exit 0** (regenerated RECEIPTS.md + receipts/INDEX.md for v26.10.16 … v26.10.22
without error):

```
wrote /Users/sac/smalt/docs/jira/v26.10.22/receipts/INDEX.md
RI-EXIT:0
```

## Verdict

**PARTIAL_ALIVE.** Stages 1, 3, 4, 5, 6 all green (exit 0). Stage 2 is green at the
behavioral level — 735/739 pass, zero lib/ failures — but the 4 census fences
type loudly against three lanes' new/in-flight files (BK-AMQPF, BK-EPLAW, KD-173R)
that are unregistered in the census allowlist, contain an unaudited
`Process.sleep` (BK-EPLAW — direct no-sleep-doctrine violation in test/), and carry
status-literal asserts (KD-173R). Two earlier compile-aborts this sweep were
in-flight-owned (BK-CELLS, since landed) and transient-mid-edit (EXPL6-R1, since
landed fixed). Full-green seal is blocked solely on those three lanes registering
their files in `test/internal/internal_tier_census_test.exs`'s fences and cleaning
the BK-EPLAW sleeps; no sealing work remains on this lane's side.

**Typed residues (owners)**:
- BK-AMQPF: register `bkamqpf_f2a_boundary_court_test.exs` in census allowlist (+ module refs).
- BK-EPLAW: register `eplaw_ephemeral_boot_court_test.exs`; replace 2 `Process.sleep` with bounded polls / `SLEEP-CLASS` exception.
- KD-173R: register `kd173r_audience_scope_court_test.exs`; fix 2 status-literal asserts.
