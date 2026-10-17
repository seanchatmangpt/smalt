# R98: comp-whitelist gate

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/egress_router.ex` (comp whitelist), `scripts/shim_court/comp_whitelist_court.sh`

## Claim

Comp-whitelist gate (unimplemented `comp=` on blob PUT -> typed 400) is non-vacuous.

## Re-run evidence

```
$ bash scripts/shim_court/comp_whitelist_court.sh; echo exit=$?
[COURT] comp-whitelist court subject: lib/smalt/egress_router.ex
[SHIM] baseline sha256(lib/smalt/egress_router.ex) = 0d21ceaa765d2f4e1e0c5a901ab73b37717a591ce514df2d6b2ddef331d0e7e1
[AFTER] landed whitelist holds: all unimplemented comps -> typed 400, body unchanged
[SHIM] whitelist disabled in both blob arms
[BEFORE] corruption witnessed: comp=snapshot overwrote the blob body via the generic Put Blob fallback
[RESTORE] byte-exact restore verified (sha256 match)
[COURT] PASS: GAP-AUD1-01 comp-whitelist gate is NON-VACUOUS
exit=0
```

## Verdict

PASS. Shim court PASS with the flip witnessed (BEFORE corruption vs AFTER hold) and a
byte-exact restore. Note: this court's semantics (reserved/typed refusal) conflict with
egress_dispatch_test.exs:2188's 201-expectation — see r85/r87.
