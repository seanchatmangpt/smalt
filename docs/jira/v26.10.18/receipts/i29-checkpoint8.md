# i29 Checkpoint 8 — Dirty-Tree Census (post azb24-bump)

Date: 2026-10-19
Standing: **ALIVE** (census-only; no tree mutations by this lane)
Context: solo(/Users/sac/smalt)

## Question answered

`git status --porcelain` census + receipt attribution: is
`i29-azb24-bump.md` landed, what does the bump lane leave, and what is the
exact commit-ready `git add` line for the coordinator.

## Census (real output, 2026-10-19)

`git status --porcelain`:

```
 M CHANGELOG.md
 M docs/capabilities.json
 M docs/jira/v26.10.16/sdk-results/spc-bands.md
 M mix.exs
 M workspace/package.json
?? docs/jira/v26.10.18/receipts/i29-azb24-bump.md
```

Note: `docs/jira/v26.10.18/receipts/i29-budget-reseed.md` was dirty at
census start and went clean mid-census via the coordinator commit
`fee8afe` ("fix(budget): manifest reseed 2763 budgets — per-test max over
5 exports + 2x headroom"); it is no longer part of the dirty set.

## Receipt backing (per path)

| path | backing receipt | status |
|---|---|---|
| `mix.exs` | `i29-azb24-bump.md` (file 1) | landed (untracked), receipt-backed |
| `workspace/package.json` | `i29-azb24-bump.md` (file 2) | landed, receipt-backed |
| `docs/capabilities.json` | `i29-azb24-bump.md` (file 3, regenerated via `Canonical.write()`) | landed, receipt-backed |
| `CHANGELOG.md` | `i29-azb24-bump.md` (file 4) | landed, receipt-backed |
| `docs/jira/v26.10.16/sdk-results/spc-bands.md` | `i29-spc-attrib.md` (committed `09de85e`) — sanctioned `scripts/spc_gate.py` generated receipt, re-dirties on every doctor/spc-check run | attributed, not orphaned |

**`i29-azb24-bump.md` IS landed** — on disk at
`docs/jira/v26.10.18/receipts/i29-azb24-bump.md`, standing PASS, Context
solo(/Users/sac/smalt). The bump lane left exactly: mix.exs 26.10.16→26.10.18,
workspace/package.json 26.10.14→26.10.18, capabilities.json
semanticEpoch/contentSha256 pair, CHANGELOG 26.10.18 section. Explicitly not
done by that lane (per its "Not done" section): git add/commit, AZB-24 mint
(waits on court-x2 artifacts).

## Exact commit-ready line for the coordinator

```bash
git add mix.exs workspace/package.json docs/capabilities.json CHANGELOG.md \
        docs/jira/v26.10.16/sdk-results/spc-bands.md \
        docs/jira/v26.10.18/receipts/i29-azb24-bump.md \
        docs/jira/v26.10.18/receipts/i29-checkpoint8.md
```

## Lane-hot exclusions

NONE. Every dirty path is receipt-backed; nothing in the dirty set belongs to
an in-flight lane. One operational caveat: `spc-bands.md` is generated output
that rewrites on every `just doctor`/`spc-check` run — commit it in the same
window as any gate run, or expect it to re-dirty with fresh gate output
(attribution to `i29-spc-attrib.md` holds either way).

## Verification

- `git status --porcelain` (real output above).
- `git diff mix.exs workspace/package.json`: version bumps only
  (26.10.16→26.10.18, 26.10.14→26.10.18).
- `git diff docs/capabilities.json`: 2-line pair (semanticEpoch + contentSha256).
- `cat docs/jira/v26.10.18/receipts/i29-azb24-bump.md`: standing PASS,
  complete 4-file list matches the dirty set exactly.

## Addendum 2 — dirty-set census, 2026-10-19 (Context: solo)

`git status --porcelain` at census time (real output):

```
 M docs/jira/v26.10.16/sdk-results/spc-bands.md
 M docs/jira/v26.10.18/receipts/azb-22b-zombie-fix.md
 M docs/jira/v26.10.18/receipts/i29-colima-stop-runbook.md
 M docs/jira/v26.10.18/receipts/i29-court-x2-final.md
?? docs/jira/v26.10.18/receipts/i29-azb20-postfix.md
```

Census of the 4 modified paths (all receipt-backed, diff stat 167 insertions
/ 30 deletions):

1. `spc-bands.md` — `scripts/spc_gate.py` regen (sanctioned per
   `i29-spc-attrib.md`, commit `09de85e`); content: verdict EVENT/tier-1
   seeded → PASS/tier-0 unseeded (392-point window, 0 events). Commit-ready.
2. `azb-22b-zombie-fix.md` — third-strike Re-judge section appended
   (retry window 2: 6 docker builds, 0 ring runs, HEAD-churn + daemon-EOF;
   standing BLOCKED, Context solo). Receipt-backed.
3. `i29-colima-stop-runbook.md` — two quiet-window monitor continuations
   appended (01:19 / 01:35, Context solo(monitor)/solo(monitor+court));
   runbook content sections, standing PARTIAL_ALIVE. Receipt-backed (self).
4. `i29-court-x2-final.md` — no longer empty: HEAD blob `e69de29` (0 bytes)
   → 14,956 bytes / 60 lines of real appended court-x2 run summaries
   (gates 1792397604 → 1792400897, verbatim verdict blocks). Carries real
   content; receipt-backed (self).

Exact commit-ready line for the coordinator:

```bash
git add docs/jira/v26.10.16/sdk-results/spc-bands.md \
        docs/jira/v26.10.18/receipts/azb-22b-zombie-fix.md \
        docs/jira/v26.10.18/receipts/i29-colima-stop-runbook.md \
        docs/jira/v26.10.18/receipts/i29-court-x2-final.md \
        docs/jira/v26.10.18/receipts/i29-checkpoint8.md
```

Untracked decision item (not in this addendum's add line, coordinator
decides): `docs/jira/v26.10.18/receipts/i29-azb20-postfix.md` (4,255 bytes,
GAP-AZB20-1/4 postfix re-test, standing per its header — all four cells
still OPEN). Receipt-backed; include in the same or a follow-up add if
wanted.

## Addendum 3 — harden-lane dirty-set census, 2026-10-19 (Context: solo)

Dirty set per `git status --porcelain` (2 modified + 1 untracked, all
courtface-harden lane):

- `M test/azsim/topology_test.exs` (+60/-9 approx: 70 insertions total across
  both files, 9 deletions)
- `M test/wire/arm_wire_test.exs` (+19)
- `?? docs/jira/v26.10.18/receipts/i29-courtface-harden.md` (3.5+ KB, standing
  PASS, real `fast_test.sh` output embedded — receipt-backed)

Receipt backing: `i29-courtface-harden.md` names both test files as its exact
subject (`GracefulStop` `eventually/2` pattern, zero `Process.sleep` added);
the diff hunk contents (bounded polls on `StsGate` whereis, bridge dequeue
`{:retry, :bridge_queue_empty}`, arm-port TCP readiness) match the receipt's
fix section. Confirmed receipt-backed.

Exact commit-ready line for the coordinator:

```bash
git add test/azsim/topology_test.exs \
        test/wire/arm_wire_test.exs \
        docs/jira/v26.10.18/receipts/i29-courtface-harden.md
```
