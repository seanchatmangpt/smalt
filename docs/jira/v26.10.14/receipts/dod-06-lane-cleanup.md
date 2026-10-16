# Receipt: DoD-6 lane cleanup (v26.10.14)

- **Date**: 2026-10-15
- **Lane**: DoD-6, owner of `justfile.d/06-lane-cleanup.just`
- **Authority**: operator 2026-10-01 cleanup law — lane build roots are leases, not assets; deleted at integration before the final commit (`same-checkout-fanout.md`)
- **Subject**: repo /Users/sac/smalt, branch main @ 3fc2543 (working tree, uncommitted)

## Commands + exits

| step | command | exit |
|---|---|---|
| enumerate | `ls -d _build*` | 62 entries (canonical `_build` + 61 lane roots) |
| write tooling | `justfile.d/06-lane-cleanup.just` (lane-clean, lane-clean-dry) | — |
| dry run | `just -f justfile.d/06-lane-cleanup.just lane-clean-dry` | 0 |
| cleanup | `just -f justfile.d/06-lane-cleanup.just lane-clean` | 0 |
| witness | `ls -d _build*` | only `/Users/sac/smalt/_build` remains |
| compile gate | `mix compile --warnings-as-errors` | 0 |

## Result

- **Deleted: 61 orphaned lane build roots** (`_build-l*`, `_build-f16*`, `_build-lane*`, `_build-laneCOSMOS*`, `_build-lanePPLAN*`, `_build-docs*`, `_build-lens9`, `_build-stab3`, `_build-verdict`, `_build-lanePY1`, `_build_f16L6`, etc.).
- **Freed total: 35,352,680 KB = 33.71 GiB.**
- Live-reference guard (`lsof +D` + beam/elixir cwd scan) found **zero** live-referenced dirs; no skips.
- Canonical `/Users/sac/smalt/_build` untouched.

## Compile witness

`mix compile --warnings-as-errors` → exit 0, no output (clean canonical build).

## .gitignore check (read-only)

`/_build-*/` present at line 3 — hyphen lane variants covered. **Follow-up (one line, coordinator):** the underscore variant `_build_f16L6` existed pre-cleanup and is NOT covered by the pattern; consider adding `/_build_*` if underscore-style lane roots recur.

## Standing

ALIVE — executed on the real repo root with witnessed du totals, lsof guard run, and a passing compile gate after deletion. No commits made, per instructions.
