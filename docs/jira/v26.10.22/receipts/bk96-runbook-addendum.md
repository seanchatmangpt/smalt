# BK-96: substrate-up runbook addendum (SMALT_UP_TIMEOUT + toolchain pin)

**Standing**: ALIVE
**Context**: solo

## Change

No doc in `docs/` documented `SMALT_UP_TIMEOUT` (grep confirmed only
`scripts/substrate.sh:21` and the BK-76 receipt referenced it). Added a
"Substrate-up operational notes" section to
`docs/reference/just-recipes.md` — the reference doc that already carries the
`substrate-up` recipe rows — immediately before "See Also".

## Content added (docs/reference/just-recipes.md, new lines 109-121)

1. Boot timeout on loaded hosts: default 90s (`scripts/substrate.sh:21`) is
   tuned for quiet machines; on loaded multi-lane hosts a cold dep compile
   blows past it and surfaces as exit-2 boot fail. Fix: export
   `SMALT_UP_TIMEOUT=240` or pre-warm via `mix compile` before
   `substrate-up`. (BK-76 lesson.)
2. Toolchain PATH pin: `substrate-up` requires asdf `1.20.4-otp-29` on PATH;
   homebrew `1.19.5` is refused. `just doctor` flags the drift. (BK-72-adjacent
   lesson.)

## Verification

```
$ just docs-dod-check; echo "EXIT=$?"
... 62 OK lines (incl. "OK    docs/reference/just-recipes.md") ...
EXIT=0
```

Not committed (per work order).
