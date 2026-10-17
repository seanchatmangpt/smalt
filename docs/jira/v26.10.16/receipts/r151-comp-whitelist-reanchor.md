# Receipt — R151 (comp_whitelist re-anchor, shim court non-vacuous)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 wave)
- **Standing:** PASS
- **Date:** 2026-10-16 (W7 docs lane)

## Subject

R151 re-anchored the comp whitelist gate at the shared `unhandled_comp?/2`
helper in `lib/smalt/egress_router.ex` (all arms), replacing per-route
whitelisting. Non-vacuity proven by
`scripts/shim_court/comp_whitelist_court.sh` (GAP-AUD1-01).

## Verification (2026-10-16, W7 docs lane, unedited output)

```
$ scripts/shim_court/comp_whitelist_court.sh
[SHIM] baseline sha256(lib/smalt/egress_router.ex) = 183761fb4aa8067321c9fc40266a4f0b1b43b019d230da9120dcc7e5d967f599
[AFTER] landed whitelist holds: all unimplemented comps -> typed 400, body unchanged
[SHIM] whitelist disabled at the shared unhandled_comp?/2 helper (all arms)
[BEFORE] corruption witnessed: comp=snapshot overwrote the blob body via the generic Put Blob fallback
[RESTORE] byte-exact restore verified (sha256 match)
[COURT] PASS: GAP-AUD1-01 comp-whitelist gate is NON-VACUOUS
exit=0
```

## W10 re-run (2026-10-16, docs lane W10)

```
$ just shim-court comp_whitelist
[BEFORE] corruption witnessed: comp=snapshot overwrote the blob body via the generic Put Blob fallback
[RESTORE] byte-exact restore verified (sha256 match)
[COURT] PASS: GAP-AUD1-01 comp-whitelist gate is NON-VACUOUS
EXIT=0
```

Standing: PASS.
