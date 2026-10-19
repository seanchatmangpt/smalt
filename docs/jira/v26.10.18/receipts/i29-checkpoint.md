# i29 — Integration Checkpoint Prep (pre-coordinator-commit census)

Date: 2026-10-18. Subject: /Users/sac/smalt @ main, HEAD `6eec145`.
Context: solo (git status census; `just receipt-index` at close).
No lib/test edits made by this lane; git read-only (no add/commit — coordinator owns git).

## 1. git status --porcelain, grouped by lane ownership

### Landed-receipt-backed (each diff has a receipt naming it)

| file | owning lane / receipt |
|---|---|
| `scripts/naming_sweep.sh` | naming-sweep repair — allowlist pin moved 252→262 + new pins; receipts `i29-gates-postfix.md`, `i29-full-soak-b.md` (sweep rerun) |
| `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md` | KD-94 row prose edit (athena path shortened); `i29-kd-sync.md` (audit) + naming-sweep pin move above |
| `lib/smalt/plane/integration_supervisor.ex` | AZB-17/20 plane-supervision fix (add `Smalt.Store` child); `i29-azsim-regression.md` (found the defect; fix disclosed by the owning lane) |
| `test/azsim/plane_supervision_test.exs` | same AZB-17/20 lane; eaddrinuse flake fix paired with the supervisor fix |
| `docs/jira/v26.10.16/sdk-results/spc-bands.md` | bench-runner lane; `i29-bench-check.md` |
| `docker/burn/compose.burn.yml` | AZB-18 burn cpus ladder; `azb-18-cgroup-soak.md` (standing STAGED — container leg not executed) |
| `docs/jira/v26.10.18/rewrite-drafts/WORKQUEUE.md` | W14 landing flip; backed by tracked receipt `w14-review.md` |

### In-flight (no closing receipt since 6eec145)

| file | state |
|---|---|
| `lib/smalt/messaging/amqp/sweeper.ex` | AZB-20 interop unblock guard (comment reclassified `:smalt_sb_*`); edit disclosed in AZB-20 receipt prose but no closing receipt on disk naming this hunk |
| `mods/ratchet/*` — 9 files (lib/commands.js, lib/gate.js, lib/inject.js + 5 test files) | mods/ratchet lane in-flight; r1–r10 receipts are older landed legs, no NEW receipt since 6eec145 covers these modifications |
| `docs/jira/v26.10.18/receipts/i29-full-soak-b.md` | modified after its initial commit — in-flight receipt update |
| `docs/jira/v26.10.18/receipts/i29-corpus-fresh2.md` | UNTRACKED new receipt — rides the next commit |

### Coordinator housekeeping (regenerated this receipt)

`docs/jira/v26.10.{14,16,17,18}/RECEIPTS.md` + `receipts/INDEX.md` via `just receipt-index`.

## 2. Receipts newest-first (`ls -t docs/jira/v26.10.18/receipts/ | head -40`)

| file | standing | one-line claim |
|---|---|---|
| `i29-full-soak-b.md` | PASS with 1 KNOWN rotating face | full soak x2, no new deterministic faces; one compile-abort recurrence on a foreign in-flight file |
| `i29-corpus-fresh2.md` | PASS | corpus+compliance slice, 3 runs on private build root, 0 failures |
| `i29-bench-check.md` | PASS | bench lanes emit; SPC bands verdict PASS tier 0 |
| `i29-sovereign-gap-triage.md` | PASS-with-caveat | 5/6 sovereign-gap bodies pass deterministically; 5.3 ARG KQL keeps typed exclusion (landed as 6eec145) |
| `i29-azsim-regression.md` | PARTIAL_ALIVE | 73-test azsim suite green on most runs; 2 typed defects (sovereign_midnight compile-abort — fixed by 0009df3 — and plane_supervision eaddrinuse flake) |
| `azb-18-cgroup-soak.md` | STAGED | burn cpus-ladder harness authored + config-validated; container leg NOT executed |
| `i29-dataplane-soak.md` | (no standing line) | data-plane + arm slice soak x2 on private build root |
| `i29-gates-postfix.md` | PARTIAL_ALIVE | compile clean, invariant-gates PASS; naming-sweep FAIL (76 pre-existing violations, none lane-owned) |
| `i29-stress-full.md` | PARTIAL_ALIVE | stress tier cannot go green this wave: 2 deterministic failures + 1 compile-abort, rest typed load/isolation flakes |
| `i29-kd-census-fix.md` | PASS | prose-only KD census count fix, no table rows touched, no flips |
| `i29-docs-drift-fix.md` | PASS | docs drift fixes |
| `i29-kd-sync.md` | PASS | KD register audit-only sync, no flips applied |
| `i29-docs-diaataxis.md` | PASS (with reported unfixed structural items) | diataxis restructure audit |
| `i29-checkpoint.md` | this receipt | census + boundary proposal + index regen |

## 3. Proposed commit boundary

Group A — naming-sweep repair + receipts (coherent, self-verifying):
- `scripts/naming_sweep.sh`, `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`,
  `docs/jira/v26.10.18/receipts/i29-gates-postfix.md` (already committed — no-op),
  updated `i29-full-soak-b.md` + new `i29-corpus-fresh2.md` receipts.

Group B — AZB plane-supervision fix + regression receipts:
- `lib/smalt/plane/integration_supervisor.ex`, `lib/smalt/messaging/amqp/sweeper.ex`,
  `test/azsim/plane_supervision_test.exs`, receipt `i29-azsim-regression.md`.
  Note: sweeper.ex is typed in-flight; if its owning lane has not closed, commit it
  only with the lane's receipt or defer it to Group B'.

Group C — AZB-18 burn harness (STAGED standing, container leg unexecuted):
- `docker/burn/compose.burn.yml` + `azb-18-cgroup-soak.md`. Committing is safe
  (no runtime behavior change to smalt proper); message should carry the STAGED caveat.

Group D — bench/SPC + WORKQUEUE/docs:
- `docs/jira/v26.10.16/sdk-results/spc-bands.md` (i29-bench-check.md),
  `docs/jira/v26.10.18/rewrite-drafts/WORKQUEUE.md` (w14-review.md).

Group E — mods/ratchet (DO NOT RIDE the next commit):
- all 9 `mods/ratchet/**` modified files. No receipt since 6eec145 names them;
  they are in-flight lane output and would be unreceipted actuation in a wrap commit.
  Defer to the ratchet lane's own commit with its receipt.

Group F — regenerated indexes (wrap commit, last):
- `docs/jira/v26.10.{14,16,17,18}/RECEIPTS.md` + `receipts/INDEX.md`
  + this receipt (`i29-checkpoint.md`).

## 4. just receipt-index regen (executed)

```
wrote /Users/sac/smalt/docs/jira/v26.10.14/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.14/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.16/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.16/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.17/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.17/receipts/INDEX.md
wrote /Users/sac/smalt/docs/jira/v26.10.18/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.18/receipts/INDEX.md
```

v26.10.18 SUSPECT count: **0** — "Cross-check / SUSPECT flags: None: every receipt
contains at least one exit-code, test/probe count, or PASS/FAIL token."
