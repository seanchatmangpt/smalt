# i29 AZB-24 Version Bump (26.10.18)

Date: 2026-10-19
Context: solo(/Users/sac/smalt)
Plan: docs/jira/v26.10.18/azsim-burn/AZB24-BUMP-PLAN.md (followed; §2 diffs 1-4, §3/§4 wrap NOT in this lane's scope)

## Files changed (complete list, all by this lane)

1. `mix.exs` — `@version "26.10.16"` → `@version "26.10.18"` (line 4).
2. `workspace/package.json` — `"version": "26.10.14"` → `"version": "26.10.18"`
   (line 3; clears the plan-noted 2-version skew).
3. `docs/capabilities.json` — regenerated via
   `MIX_ENV=test mix run --no-start -e 'Smalt.Projection.Canonical.write()'`.
   Diff: `identity.semanticEpoch` 26.10.16 → 26.10.18 +
   `identity.contentSha256` a4e83220… → 5cf1a4c5… (2 lines). THIRD_PARTY.md
   rider byte-unchanged.
4. `CHANGELOG.md` — inserted `## [26.10.18] - 2026-10-19` section between
   `## [Unreleased]` and `## [26.10.16] - 2026-10-16` (highlights per
   coordinator direction: sovereign midnight 18/18, G1 queue storage landed,
   AZB-17 8x4 ALIVE, isolation gates green, KD-98, budget gate 0/0/0,
   validator standing fix; G2-G4 + ring re-run + plane-mounting carried to
   v26.10.19).

## Verification (real output)

- `docs/capabilities.json` identity block on disk now:
  `semanticEpoch: "26.10.18"` (read back via python json parse post-write).
- `python3 scripts/gen_error_codes.py --check` →
  `docs/ERROR_CODES.md up to date`, exit 0.
- `git diff --stat docs/capabilities.json` → 2 insertions/2 deletions
  (expected single-line semanticEpoch + contentSha256 pair).

## Not done (per instructions)

- No `git add`/`git commit` — tree left dirty for coordinator-owned commits.
- AZB-24 mint (`scripts/mint_release_receipt.py`, plan §3) NOT run —
  requires post-bump release SHA + court-x2 artifacts (gate window).

## Concurrent-lane note (not this lane's diff)

At receipt time `git status` also shows dirty:
`docs/jira/v26.10.16/sdk-results/spc-bands.md` (pre-existing at session
start) and `docs/jira/v26.10.18/receipts/i29-budget-reseed.md` (another
lane's in-flight edit). Neither touched by this lane; coordinator should
attribute at integration.

## Standing

PASS — bump applied and verified on disk; awaiting court window for
court-x2 + release mint.
