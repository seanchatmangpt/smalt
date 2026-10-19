# FINAL.md — v26.10.18 window wrap

- **Date**: 2026-10-19
- **Subject**: /Users/sac/smalt (branch main; version bumped to 26.10.18)
- **Context**: solo(documentation wrap; no execution, no git state changes)
- **Standing of this document**: CENSUS — every claim cites a receipt on disk.
  The court-x2 verdict is TYPED-RED (gate carried; see §3).

## 1. Window summary

v26.10.18 executed the azsim-burn program: the AZB-01..24 work-order ladder
(plane profiles, supervision subtrees, burn/chaos harnesses, SDK interop,
gates) plus the test-suite rewrite waves, docs-audit implementation, HAVE
supervisory engine, and the ratchet mod. The release gate ladder
(`docs/jira/v26.10.18/azsim-burn/README.md` §Release gate): G1 (zero-sleep)
and G5 (SDK lanes) closed this window; G2/G3/G4 carry to v26.10.19 as
typed-open (§4).

## 2. Work-order standing (AZB-01..24)

Standing is each receipt's own verdict line; paths relative to
`docs/jira/v26.10.18/receipts/`.

| WO | Standing | Receipt |
|---|---|---|
| AZB-01 image pin (OTP 28 + Elixir 1.19.5) | ALIVE | azb-01-image-pin.md |
| AZB-02 netns, zero host port publish | ALIVE | azb-02-netns.md |
| AZB-03 burn JSONL schema + validator | ALIVE | azb-03-burn-schema.md |
| AZB-04 plane profile loader | PASS | azb-04-plane-loader.md |
| AZB-05 control plane profile | PASS | azb-05-control-plane.md |
| AZB-06 data plane profile | PASS | azb-06-data-plane.md |
| AZB-07 integration plane profile | ALIVE | azb-07-integration-plane.md |
| AZB-08 identity plane profile | PASS | azb-08-identity-plane.md |
| AZB-09 plane supervision subtrees | ALIVE | azb-09-plane-subtrees.md |
| AZB-10 cross-plane wiring | ALIVE | azb-10-cross-plane.md |
| AZB-11 isolation court | PARTIAL_ALIVE | azb-11-isolation-court.md |
| AZB-11b leak remediation | PARTIAL_ALIVE | azb-11b-leak-remediation.md |
| AZB-12 ratio fences | ALIVE | azb-12-ratio.md |
| AZB-13 boot burn x50 | ALIVE | azb-13-boot-burn.md |
| AZB-14 SIGKILL storm + DETS repair | ALIVE | azb-14-sigkill-storm.md |
| AZB-15 subtree DR kills | ALIVE | azb-15-dr-subtrees.md |
| AZB-16 AMQP saturation | ALIVE | azb-16-amqp-saturation.md |
| AZB-17 parallel plane matrix | ALIVE | azb-17-parallel-matrix.md |
| AZB-18 cgroup soak | typed-RED-carried | azb-18-cgroup-soak.md |
| AZB-19 overlap scheduling | PARTIAL_ALIVE | azb-19-overlap.md |
| AZB-20 SDK interop | PARTIAL_ALIVE | azb-20-sdk-interop.md |
| AZB-21 zero-sleep gate | ALIVE | azb-21-zero-sleep.md |
| AZB-22 burn ring | typed-RED-carried | azb-22-burn-ring.md |
| AZB-22b zombie fix | ALIVE (verify) | azb-22b-zombie-verify.md |
| AZB-23 court-x2 | TYPED-RED-CARRIED | azb-23-court-x2.md |
| AZB-24 version bump | PARTIAL_ALIVE | i29-azb24-bump.md |

AZB-18 detail: harness + fail-closed `validate_burn.py` gate proven on a real
container leg; data + identity planes completed the full 2740-test offline
tier under a 2g cap (44 / 45 real failures, cgroup-environment class to
classify next cycle); control + integration remain OOM-killed at 2g
(exit 137, 0 tests — compile-abort, not a failure count). The RECEIPTS.md
index row reads FAIL from the on-spec 1g run; the receipt's own final
standing line is PARTIAL_ALIVE after the 2g diagnostic leg
(`azb-18-cgroup-soak.md`, "Standing: PARTIAL_ALIVE" section; index:
`RECEIPTS.md` line ~36).

AZB-20 detail: per-plane matrix + header audit executed for real; 6
FAIL-class cells stand as open typed gaps
(`azb-20-sdk-interop.md`; gap-fix lane verification
`i29-azb20-verify.md` — cosmos bulk partition-key cell CLOSED, control-plane
cells REPRODUCED still-OPEN; lib adoption `i29-azb20-lib-land.md` ALIVE,
515 tests / 0 failures).

AZB-22 detail: ring machinery GREEN where witnessed (chaos x50 all green;
gate + subject-moved guard both refuse as designed) but the ring carries a
typed RED (ZOMBIE_BEAM at boot stage, jidoka line-stop). The zombie FACE is
closed (`azb-22b-zombie-fix.md`; verify `azb-22b-zombie-verify.md` ALIVE,
boot-burn 12/12 CLEAN); the full ring re-judge was deferred on un-leased
concurrent image builds — 3 infrastructure strikes embedded in
`azb-22b-zombie-fix.md` §"Ring boot re-judge retry — BLOCKED again".

## 3. Court-x2 verdict — TYPED-RED (gate carried)

- Verdict receipt: `docs/jira/v26.10.18/receipts/azb-23-court-x2.md`
  (Standing: TYPED-RED, gate carried to v26.10.19).
- Attempt ledger: `docs/jira/v26.10.18/receipts/i29-court-x2-final.md`
  (8 gate entries, 1792397604 → 1792402305), per-attempt logs
  `tmp/court-x2-1792*.log`. No two-consecutive-greens witnessed; every
  green is single-run.
- Precondition state at freeze (AZB23-PREFLIGHT.md): B2/B3 carried to
  v26.10.19 as TYPED-OPEN, AZB-23 proceeded without them
  (`azsim-burn/AZB23-PREFLIGHT.md` §Amendment 2026-10-19).
- **VERDICT: TYPED-RED — the gate never exited 0 twice consecutively.**
  Attempt ledger with per-run verdicts (GREEN/NOT GREEN read verbatim from
  the logs; the receipt ledger records UNPARSED due to a court23.sh
  parser-pattern mismatch, documented in the verdict receipt):

  | Attempt | run1 | run2 | Log |
  |---|---|---|---|
  | 1792397604 | NOT GREEN (5 fail) | UNPARSED/aborted | tmp/court-x2-1792397604.log |
  | 1792398603 | NOT GREEN (6 fail) | GREEN (0 fail) | tmp/court-x2-1792398603.log |
  | 1792399039 | NOT GREEN (1 fail) | NOT GREEN (4+1) | tmp/court-x2-1792399039.log |
  | 1792399378 | NOT GREEN (1 fail, tf-smoke abort) | GREEN (0 fail) | tmp/court-x2-1792399378.log |
  | 1792399870 | NOT GREEN (8+1) | NOT GREEN (5+1) | tmp/court-x2-1792399870.log |
  | 1792400897 | GREEN (0 fail, 1 invalid) | NOT GREEN (2 fail) | tmp/court-x2-1792400897.log |
  | 1792401910 | GREEN (0 fail) | NOT GREEN (2 fail) | tmp/court-x2-1792401910.log |
  | 1792402305 | NOT GREEN (4 fail) | NOT GREEN (5 fail) | tmp/court-x2-1792402305.log |

- Green witnesses (run-level, never two-consecutive): gate @1792400897
  run1 GREEN 2755/0; gate @1792399378 run2 GREEN 0 failures;
  gate @1792401910 run1 GREEN 0 failures; dry5 rehearsal both-green 2733/0
  ×2 (`i29-court-dry5.md`); full-soak leg C 2728/0 (`i29-full-soak-d.md`).
- Residual: a bounded family of 4-6 genuine cross-plane boot-order races
  (DrScenarios 1-4 subtree-kill recovery, KV foreign-key 401s,
  throttle `:cosmos`, identity STS-over-wire) — solo-green everywhere,
  failing under fresh-boot ordering; `SMALT_MAX_CASES=4` does not clear
  them (not pure load; probe dispatch-reported, receipt UNLOCATED —
  flagged in the verdict receipt). Close condition = the race family fixed
  at the structural level; first v26.10.19 work order alongside WO-1.

## 4. v26.10.19 handoff

Ordered per `azsim-burn/AZB23-PREFLIGHT.md` §Blocking chain, items 2–6 plus
the G-ladder residuals:

1. **Burn-ring re-run (G2 / AZB-22 close)** — pin a SHA, re-run
   `just burn-ring` under an image-build lease (flock, same pattern as
   `scripts/substrate.sh`) so concurrent docker builds cannot strike a ring
   re-judge again (`AZB23-PREFLIGHT.md` §Amendment;
   `azb-22b-zombie-fix.md`).
2. **G3 court-x2** — two consecutive green legs at the pinned SHA on a
   frozen quiescent tree; mint `rNNN-court-x2-azsim-two-green.md` per
   `azsim-burn/TICKETS.md` (`azsim-burn/README.md` §Release gate G3).
3. **G4 isolation court** — close the AZB-11 runtime-twin residual:
   full-suite twin not yet witnessed green
   (`azb-11-isolation-court.md`; runtime-twin runs
   `i29-isolation-runtime5.md` PARTIAL_ALIVE,
   `i29-isolation-runtime2.md` FAIL).
4. **GAP-AZB20-1 plane mounting** — implement Option A from
   `azsim-burn/GAP-AZB20-1-PLAN.md`: mount `Smalt.Store` in the control
   subtree when `:data` not selected (control_supervisor.ex), crash-path
   header plug in the ARM router (GAP-AZB20-3), ResourceGraph route on ARM
   (GAP-AZB20-6); ~50 lines, zero StoreTable additions. Re-test per the
   plan §Re-test commands; regression
   `mix test test/data_plane/ test/arm/ test/wire/ test/azsim/`.
5. **AZB-18 close** — raise `SMALT_SOAK_MEM_LIMIT` toward 4g for the
   2.0-CPU planes or stagger compile (control/integration OOM at 2g);
   ledger the cgroup-environment failure faces (data 44 / identity 45) in
   FLAKE_LEDGER; ledger/fixed the unledgered faces census before any
   re-burn can derive ALIVE; rebuild the image byte-complete after a Docker
   disk raise (missing `.venv-cosmos` layer)
   (`azb-18-cgroup-soak.md` §Run 2 + §Disclosures;
   `i29-docker-reclaim.md` — safe-reclaim scope exhausted, coordinator/
   operator action required).
6. **Cgroup validator + mem defaults** — the standing-derivation fix is
   proven (`i29-validator-standing-fix.md` ALIVE); next cycle: fold the
   corrected default mem cap (4g for 2.0-CPU planes or a staggered-compile
   profile) into `docker/burn/cgroup-soak.sh`'s compose emission so the
   gate no longer requires a documented env override to complete the
   heaviest planes (`azb-18-cgroup-soak.md` §Run 2).
7. **Landed this window, queued into the new window's surface**: G1 Queue
   Storage (feature, distinct from gate G1) —
   `lib/smalt/data_plane/queue_storage.ex` (577 lines) + egress router arm
   + 2 StoreTable rows, engine/wire tiers green x2
   (`i29-g1-land.md` ALIVE; register flip + s10 verify
   `i29-wrap-items.md` PASS).

## 5. Release ledger

- **Version**: 26.10.18 — `mix.exs` `@version`, `workspace/package.json`
  (26.10.14 → 26.10.18, clears a 2-version skew), `CHANGELOG.md`,
  regenerated `docs/capabilities.json` (`i29-azb24-bump.md`; plan
  `azsim-burn/AZB24-BUMP-PLAN.md`; bump commit `2ac4874` "feat(release):
  version 26.10.18").
- **Commits**: 106 commits on main since `2eb5f89` through HEAD `49a9ad1`
  ("docs(receipts): full-soak leg G — all failures LOAD-class, zero NEW,
  azb-20 surfaces clean") as of 2026-10-19 (live `git log --oneline
  2eb5f89..HEAD | wc -l`).
- **Key receipts** (beyond the WO table): gates re-run at release SHA
  `8b7cbcd1` all three exit 0 (`i29-gates-release-sha.md` PASS);
  compile-clean sweep (`i29-compile-clean.md` ALIVE); static-gate quad
  re-run (`i29-static-gates-pregate2.md` PASS); budget gate final
  (`i29-budget-final.md` + `i29-budget-final2.md` PASS, reseed
  `i29-budget-reseed.md` CLOSED); wire tier (`i29-wire-2x.md` PASS;
  pre-gate ALIVE `9120684` — 2816-test legs, zero NEW faces,
  `i29-wire-pregate.md`); e2e tier full re-verify
  (`i29-e2e-final.md` PASS); full-soak leg G — all failures LOAD-class,
  zero NEW (`i29-full-soak-g.md` PARTIAL_ALIVE); ws/cli fresh legs
  (`i29-ws-cli-fresh.md` PASS); docs gates
  (`i29-docs-gates2.md`, `i29-docs-gates3.md` PASS); wrap items
  (`i29-wrap-items.md` PASS); final sweep (`i29-receipt-final.md` PASS).
- **Known-open at wrap** (carried, not regressed): court-x2 TYPED-RED,
  gate carried to v26.10.19 (§3); publish-dry / docs-dod-check /
  invariant-gates flagged stale at preflight, gates refresh at release SHA
  per `AZB23-PREFLIGHT.md` table D + §Blocking chain step 5.

## 6. Handoff pointer

Planning handoff to the next window lives with the v26.10.19 planning
artifacts; the authoritative open-item list is §4 above plus
`azsim-burn/AZB23-PREFLIGHT.md` (§Amendment 2026-10-19).
