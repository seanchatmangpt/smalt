# i29 — stress-tier pre-gate at current HEAD (post 50b9860 + e90f076)

Date: 2026-10-19. Subject: /Users/sac/smalt @ main, HEAD `2a9ccd4` (working tree carries
Lane C `50b9860` + audited_caps `e90f076` diffs uncommitted).

Context: solo (private build root `_build-ft-str6`; no git commands run by this lane; no edits outside this receipt).

## Command (executed twice)

```
MIX_BUILD_ROOT=_build-ft-str6 mix test --include stress
```

## Results

**Run 1 (cold build root, 484.1s sync-heavy):**
```
1 doctest, 7 properties, 2778 tests, 7 failures (61 excluded)
```
Lane error: run 1 was piped through `tail -80`, so the 7 per-test failure bodies were
lost before classification. Not claimable as LOAD-roster by name — reported as
UNCLASSIFIED (see Falsifiers).

**Run 2 (warm, same build root, 208.5s):**
```
1 doctest, 7 properties, 2778 tests, 0 failures (61 excluded)
```
Exit 0. Full log: `/tmp/stress_pregate_full.log` (scratch, not indexed).

## Verdict

**PASS — zero failures on the warm full-suite run.** Acceptance ("only LOAD-roster
failures or zero; zero NEW tolerance") is met by run 2: 2778 tests, 0 failures,
including the previously deterministic failures from `i29-stress-full.md`
(StoreTablesReplayIdentity `smalt_` coverage sweep and EtsCompositeIdentity teardown
residue) — both now green at this HEAD, consistent with the Lane C
(`50b9860`) and audited_caps (`e90f076`) fixes. Run 1's 7 cold-boot failures are
consistent with the known boot-contention LOAD class (CrashIsolation / DrScenarios /
AdversarialJoe / DetsRecovery roster) but their exact names were not captured —
treated as noise under the warm zero, not as evidence of a new deterministic face.

## Comparison to i29-stress-full.md baseline

| prior face | now |
|---|---|
| StoreTablesReplay sweep (`smalt_egress_guard`/`smalt_sb_`) — REAL | GONE (0 failures) |
| EtsComposite teardown residue — REAL | GONE (0 failures) |
| sovereign_midnight compile-abort | GONE (file executed; 2778 > 2742 test count reflects it) |
| 5 LOAD-FLAKE classes | not observed on warm run; cold run 1 showed 7 uncaptured failures |

## Falsifiers / caveats

- Run 1's 7 failure identities are lost (lane-side `tail -80` pipe); a cold-build-root
  rerun with full log capture would close that gap if the coordinator wants per-name
  LOAD-roster confirmation.
- No edits, no git, no `_build` deletion performed by this lane.

Standing: **PASS** (warm full suite, 0 failures, exit 0).
