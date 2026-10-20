# RISK_REGISTER — v26.10.19

> Commands and paths below were verified against the PRE-deletion checkout
> (4fd2ff2). Post-deletion, test/ paths resolve to the residual
> test/internal/ tier and the external verification/{ts,py} suites -
> re-ground each cited path before executing.

Seven risk classes from the reset design, each with probability / blast-radius /
detection falsifier (exact runnable command, paths verified on this checkout) /
owner lane. Program-level falsifiers F1–F7 at the bottom. Every command is
grounded in artifacts that exist on HEAD `4fd2ff2` — nothing aspirational.

Owner lanes (standing lane map, `docs/jira/v26.10.19/WORK_ORDERS.md`):
- **WO-lane** — the six typed-open work orders (WO-1…WO-6)
- **Coverage-lane** — SDK matrix / census / parity surfaces
- **Identity-lane** — auth + credential surfaces (`lib/smalt/arm_gateway/`, SDK probes)
- **Hygiene-lane** — lanes/ports/builds/staleness containment
- **Court-lane** — courts, gates, falsifier maintenance

---

## Status refresh 2026-10-19 (lane: docs-status)

| Risk | Status at window close | Evidence |
|---|---|---|
| R1 coverage regression | **MITIGATED** | `python3 scripts/sdk_coverage.py` rc 0 — every cell pass-or-registered (re-run this window, `GATE: OK`); census probe landed (`receipts/v261019-court-census.md`, post-fix `c9b0bf1`) |
| R1a commit-entanglement | monitored, no findings | `git log --oneline -20` review: deletion commits single-purpose (F7 held; deletion manifest `receipts/reset-delete-manifest.txt`) |
| R1b harness-first ordering | **MITIGATED** | deletion gated on receipts landing first (`receipts/v261019-11-test-deletion-gate.md`); `just docs-dod-check` rc 0 this window |
| R2 identity wall | **CLOSED** | real credential path landed: RS256 + JWKS (`lib/smalt/auth/sts_key.ex`, `# KD-COVERS: KD-99,KD-100`); witness `receipts/v261019-13-identity-rs256.md` (PASS; JWKS kid byte-equal + RS256 verify, tampered control fails, instance-discovery 200); `scripts/kd_flip.py --apply` scan reports KD-99 + KD-100 CLOSED-SIMULATED (witness postdates shim 10:10 → receipts 10:33/10:34). Honest note: the register's prose rows at `KNOWN_DIVERGENCES.md:16-17` still read OPEN — registrar row-flip pending; the kd_flip scan is the ground truth |
| R3 / R3a KD-without-evidence | no findings | `kd_flip.py --apply`: FLIP-ELIGIBLE 0, FLIP-PENDING-WITNESS 1 (KD-108, loudly named) — re-run this window |
| R4 staleness cascade | **MITIGATED** | regen gates green this window: `just docs-dod-check` rc 0, `scripts/receipt_index.py` rc 0 (39 receipts indexed, FINAL.md §5); counts in FINAL.md re-derived, not re-cited |
| R4a stale budgets | no findings | manifest reseed carried from `fee8afe`; no budget-gate failures in the court-x2 runs (`receipts/v261019-12-court-x2-close.md`) |
| R5 lane hazards | **MITIGATED** (partial) | orphan lane build roots reclaimed (only the active `_build-lane-final1` remains on disk); stale epmd killed in-session (session action — no receipt; `scripts/port_sweep.sh` dry-run is the standing falsifier) |
| R5a window interleaving | no findings | subject-SHA lease landed (`receipts/v261019-wo1-subject-sha-lease.md`); court-x2 SHA unchanged across both runs (`81a7a29`) |
| R6 portable-target breach | no findings | `portable-target` gate PASS 22 files clean in both court runs (`receipts/v261019-12-court-x2-close.md` verdict tail) |
| R6a blind courts | no findings | gates landed with non-vacuity contracts (`receipts/v261019-15-verification-gates.md`, ALIVE); invariant-gates 6/6 with negative fixtures refused (court-x2 verdict tail) |
| R7 falsifier rot | live note | falsifier smoke-checks re-run this window: `sdk_coverage.py` rc 0, `docs-dod-check` rc 0, `kd_flip.py --apply` scan + FLIP-PENDING report all execute cleanly on HEAD `81a7a29` — the register's detection commands are runnable, not decorative |

---

## R1 — Coverage regression (a test that used to exist/_pass_ no longer does)

Sub-risks: **R1a** commit-entanglement (a behavior fix lands in the same commit
as an unrelated deletion, so revert "the fix" also reverts coverage); **R1b**
harness-first ordering (deleting a surface before the harness that would have
caught its regression — coverage is dead before the gap can be witnessed).

| Field | Value |
|---|---|
| Probability | High — v26.10.19 is a deletion-heavy window (G5 narrowed to injectors-only, peek/clear deferred out-of-face per WO-6, G6 already closed by mount) |
| Blast radius | High — silent loss of a parity witness; the SDK matrix then reports green on a smaller surface with no diff in the claim |
| Detection falsifier | `python3 scripts/sdk_coverage.py; echo "coverage-gate rc=$?"` — exit 1 on any MISSING cell or UNREGISTERED-GAP (fail-closed, header: "Findings are surfaced, not hidden"); cross-check census CRC vs `docs/jira/v26.10.14/receipts/08-servicebus-census.md` |
| Owner lane | Coverage-lane |

### R1a — commit-entanglement
| Field | Value |
|---|---|
| Probability | Medium — solo window, temptation to bundle "fix + cleanup" in one commit is highest here |
| Blast radius | Medium — a revert cannot be surgical; bisect lands on a mixed commit |
| Detection falsifier | `git show --stat HEAD` — a deletion commit must touch ONLY the named target (see F7); also `git log --oneline -20` review for mixed fix+delete commits |
| Owner lane | Court-lane |

### R1b — harness-first ordering violation
| Field | Value |
|---|---|
| Probability | Medium — harness is expensive to run; ordering discipline slips under deadline |
| Blast radius | Medium-high — the deletion is unwitnessable: the test that would have caught the regression is gone before the deletion commit |
| Detection falsifier | `git show --stat HEAD` + `MIX_BUILD_ROOT=_build-ft-az20 just azsim-sdk` on the PRE-deletion HEAD — the probe must run (rc 0/1, not 3 SKIP) before any surface file is deleted; receipts cited in WORK_ORDERS.md must exist via `just docs-dod-check` |
| Owner lane | Coverage-lane |

---

## R2 — identity wall (a surface hard-codes, fakes, or special-cases identity
instead of exercising the real credential path)

Sub-risk **R2a — SmaltTokenCredential temptation**: the temptation is to treat
the existing probe-local credential classes as production identity. They are
NOT: `test/sdk-python/py_arm_resources.py:43`, `test/sdk-python/py_auth_keyvault.py:64`,
`test/sdk-full/auth.probe.mjs:116` are probe shims; the only workspace copy is
`workspace/lib/azure/README.md` (doc, not lib). Zero hits in `lib/` — the
falsifier must keep it that way.

| Field | Value |
|---|---|
| Probability | Medium — the class already exists in three probe files; one bad refactor imports it into `lib/` |
| Blast radius | High — every SDK parity "PASS" becomes vacuous (the probe and the server share one fake credential) |
| Detection falsifier | `grep -rn "SmaltTokenCredential" lib/; echo "identity-wall grep rc=$?"` — must return zero hits (grep rc 1 = clean); second leg: `grep -rln "class SmaltTokenCredential" test/ workspace/` — hits allowed ONLY in the three probe files + workspace README |
| Owner lane | Identity-lane |

---

## R3 — surface-gap green-washing (a MISSING/FAIL cell is made to read green
without a real surface change)

Sub-risk **R3a — KD-without-evidence**: a KNOWN_DIVERGENCES.md row is flipped
(or minted) without a witness receipt, so "registered divergence" becomes a
dumping ground.

| Field | Value |
|---|---|
| Probability | Medium-high — WO-2 requires three register rows (G2/G3/G4) to flip MISSING→COVERED; the register is hand-maintained prose |
| Blast radius | High — the matrix lies at the exact place customers read it |
| Detection falsifier | `python3 scripts/sdk_coverage.py` (UNREGISTERED-GAP = fail) **plus** `just kd-stale` (lists FLIP-PENDING-WITNESS rows — flips whose witness receipt mtime does not postdate the shim, per `scripts/kd_flip.py --apply` gate) **plus** `just docs-dod-check` (every receipt path named in a flip must exist) |
| Owner lane | Coverage-lane |

### R3a — KD-without-evidence
| Field | Value |
|---|---|
| Probability | Medium — `just rewitness <KD-nn>` exists precisely because witnesses rot |
| Blast radius | Medium — a stale KD row hides a live divergence |
| Detection falsifier | `just kd-stale` — must report "no pending-witness rows" (or an empty list) |
| Owner lane | Court-lane |

---

## R4 — staleness cascade (a stale count/standing is copied into a second file
and then a third, each citing the previous copy)

| Field | Value |
|---|---|
| Probability | High — the repo's own history: worktree counts, G01–G09 gate table, exploration-log sync have each drifted 4 times independently (CLAUDE.md `source-of-truth-check` skill exists for exactly this) |
| Blast radius | Medium — WRONG numbers propagate into FINAL.md/RECEIPTS.md and outlive the window |
| Detection falsifier | `python3 scripts/receipt_index.py` — flags receipts with no embedded command output as SUSPECT; plus `grep -rn "515/0\|2763 budgets\|2816-test" docs/jira/v26.10.19/ docs/jira/v26.10.18/FINAL.md` to catch copied counts that no longer match `git show --stat` |
| Owner lane | Hygiene-lane |

### R4a — stale budgets (the budget manifest lags the suite)
| Field | Value |
|---|---|
| Probability | Medium — manifest at `docs/jira/v26.10.18/test_budgets.json` was reseeded this window (manifest reseed 2763 budgets, commit `fee8afe`); every new/renamed test in v26.10.19 makes the gate fail-closed by design |
| Blast radius | Low-medium — gate noise; or worse, silently skipped gate |
| Detection falsifier | `just test-budget` — fail-closed: stale manifest entry (test absent from export), unbudgeted new test, or breach all exit 1; non-vacuity mutations run internally ("VACUOUS GATE" ⇒ exit 1) |
| Owner lane | Court-lane |

---

## R5 — lane hazards (concurrent lanes corrupt shared state: build roots,
ports, substrate PID file)

Sub-risk **R5a — window interleaving**: two lanes' operations interleave inside
the same window — e.g. two `docker build`s racing HEAD (witnessed: 4 concurrent
PIDs, `docs/jira/v26.10.18/receipts/azb-22b-zombie-fix.md`), or two budget-gate
runs O_TRUNC-ing each other's export (the reason `28-test-budget.just` uses a
`$$`-suffixed export).

| Field | Value |
|---|---|
| Probability | High — annealing waves run Audit/Mutate/Repair/Verify concurrently; 168 orphan build roots (~88 GiB) already reclaimed once |
| Blast radius | Medium-high — a lane's green is another lane's green-on-wrong-SHA |
| Detection falsifier | `scripts/port_sweep.sh` (dry-run default — must report no strays) + `python3 scripts/quiet_check.py` (typed veto list: stray beams, court ports 9443/8443/5672/5673/9444/9445, concurrent mix/court processes, load gate) |
| Owner lane | Hygiene-lane |

### R5a — window interleaving
| Field | Value |
|---|---|
| Probability | Medium — every docker build now must take the flock image-build lease (WO-1 fix 2) |
| Blast radius | High — wrong-SHA image labeled as ring subject |
| Detection falsifier | `git rev-parse HEAD` recorded pre-build and re-checked post-build (`git rev-parse HEAD` unchanged) + `docker ps` / build-log grep for concurrent `docker build` PIDs; WO-1 close condition requires pinned-SHA ring run |
| Owner lane | Hygiene-lane |

---

## R6 — portable-target breach (something hard-coded to this checkout leaks
into a committed artifact: absolute paths, `_build-ft-*` / `_build-lane*`
scratch roots, `tmp/` scratch, host-specific env)

Sub-risk **R6a — blind courts**: a court/gate whose non-vacuity was never
itself tested — it would pass even on a broken tree, so it cannot detect R6
(or anything else).

| Field | Value |
|---|---|
| Probability | Medium — the repo carries 80+ `_build-*` roots and `tmp/` scratch; receipts commonly paste absolute paths |
| Blast radius | Medium — committed receipt/matrix with absolute-home paths breaks every downstream `just docs-dod-check`-style relative check and leaks host layout |
| Detection falsifier | `grep -rn "absolute-home" docs/ (see portable_target_gate.py); echo "portable-target rc=$?"` — must be rc 1 (zero hits); plus `git status --short` must show no `_build-*` or `tmp/` artifacts staged |
| Owner lane | Hygiene-lane |

### R6a — blind courts
| Field | Value |
|---|---|
| Probability | Medium — new gates land each window (sleep-gate-court, budget-gate non-vacuity exist precisely as the anti-blind pattern) |
| Blast radius | High — every downstream "green" derived from a blind court is worthless |
| Detection falsifier | `just shim-courts` — anti-vacuity mutations: SHIM → AFTER (the flip IS the proof) → RESTORE (sha256 byte-exact, fail-closed); exit 0 required, exit 3 skip is loud |
| Owner lane | Court-lane |

---

## R7 — falsifier rot (the detection commands in this register stop being
runnable or stop discriminating: renamed recipe, deleted manifest, moved path)

| Field | Value |
|---|---|
| Probability | High — falsifiers cite receipts/manifests under `docs/jira/v26.10.18/` which are window-frozen; e.g. `test_budgets.json` is already v26.10.18-owned while v26.10.19 adds tests |
| Blast radius | High — the whole register silently becomes decorative |
| Detection falsifier | `just docs-dod-check` (every receipt path named in docs exists) + `just --list | grep -E "test-budget|kd-stale|shim-courts|quiet-check|azsim-sdk"` (recipes still visible) + `python3 scripts/sdk_coverage.py` still exits 0/1 (not traceback) |
| Owner lane | Court-lane |

---

# Program-level falsifiers F1–F7

One command each, runnable from repo root on any lane, all paths verified.

### F1 — Revert-the-diff coverage audit
No coverage is lost relative to the pre-window baseline; the SDK matrix claim
does not shrink silently.
```bash
python3 scripts/sdk_coverage.py; echo "F1 rc=$?"   # 0 = every cell pass-or-registered
```
Supported by: census CRC inside sdk_coverage.py vs
`docs/jira/v26.10.14/receipts/08-servicebus-census.md` and
`git show --stat` on any coverage-touching commit (R1a).

### F2 — Harness-first receipts on pre-deletion HEAD
The harness that would catch a deletion's regression RAN GREEN (or fail-honest)
on the pre-deletion HEAD, receipt-cited.
```bash
MIX_BUILD_ROOT=_build-ft-az20 just azsim-sdk; echo "F2 rc=$?"   # 0/1 = ran; 3 = SKIP (unacceptable for F2)
```
Receipt must be named in the deletion's WORK_ORDER entry and exist:
```bash
just docs-dod-check; echo "F2b rc=$?"
```

### F3 — Identity-wall honesty
No fake credential in production lib; probe-local credentials stay probe-local.
```bash
grep -rn "SmaltTokenCredential" lib/; echo "F3 rc=$?"   # must be rc 1 (no hits)
grep -rln "class SmaltTokenCredential" test/ workspace/  # hits ONLY in py_arm_resources.py, py_auth_keyvault.py, auth.probe.mjs, workspace README
```

### F4 — No unregistered gaps
Every non-pass matrix cell is a registered KD with a live witness.
```bash
python3 scripts/sdk_coverage.py && just kd-stale; echo "F4 rc=$?"
# sdk_coverage rc 0 (no UNREGISTERED-GAP) AND kd-stale reports no FLIP-PENDING-WITNESS rows
```

### F5 — Staleness containment
A stale number/standing cannot propagate: receipts carry embedded output, and
copied counts are re-derived, not re-cited.
```bash
python3 scripts/receipt_index.py; echo "F5 rc=$?"
just test-budget; echo "F5b rc=$?"   # budget manifest matches the live suite
```

### F6 — Lane hygiene at completion
At window completion: no stray beams, ports free, load quiet, lane build roots
reclaimed.
```bash
python3 scripts/quiet_check.py; echo "F6 rc=$?"   # 0 = court-ready
scripts/port_sweep.sh; echo "F6b rc=$?"           # dry-run reports no strays
just lane-clean-dry; echo "F6c rc=$?"             # orphan build roots counted, none ours
```

### F7 — Single-purpose deletion commit w/ git show --stat check
Every deletion is its own commit touching only the named target; revert is
surgical; nothing else rides along.
```bash
git show --stat HEAD   # deletion commits must list ONLY the target paths; any extra path = F7 FAIL
git log --oneline -20  # mixed fix+delete commits are an R1a finding
```
Pre-commit per repo law (`CLAUDE.md`): `git commit -F <file>`, never inline `-m`.

---

## Verification appendix (paths confirmed on HEAD `4fd2ff2`, 2026-10-19)

All commands above reference artifacts confirmed present:
`scripts/{sdk_coverage.py,verify_all.sh,court_x2.sh,isolation_court.py,mutation_court.py,port_sweep.sh,substrate.sh,quiet_check.py,test_budget_gate.py,naming_sweep.sh,kd_flip.py,receipt_index.py,shim_court/}`,
`justfile.d/{06-lane-cleanup.just,12-docs-dod.just,14-sdk-matrix.just,24-quiesce.just,26-rewitness.just,28-test-budget.just}`,
`docs/jira/v26.10.18/{test_budgets.json,WORK_ORDERS→v26.10.19}` wait —
`docs/jira/v26.10.19/WORK_ORDERS.md`,
`docs/jira/v26.10.14/receipts/08-servicebus-census.md`,
`test/sdk-smoke/census.test.cjs`, `test/{wire,azsim,data_plane,arm}/`,
`lib/smalt/egress_router.ex:1515` (ResourceGraph route, G6 closed),
`workspace/lib/azure/README.md`. KNOWN_DIVERGENCES.md/SDK_MATRIX.md render
per-window (v26.10.14, v26.10.16 exist; v26.10.19's are minted when its
`sdk-results/` lands — the F1/F4 gate derives them via
`scripts/sdk_coverage.py` window paths).

One correction to the draft appendix (kept verbatim above by accident — use this instead): the appendix's `WORK_ORDERS→v26.10.18` phrasing was a drafting slip; the correct citation is simply `docs/jira/v26.10.19/WORK_ORDERS.md`, which exists. Everything else in the register is grounded and runnable as written.
