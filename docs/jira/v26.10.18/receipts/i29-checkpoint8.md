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
