# Receipt — R11 (ERROR_CODES.md regeneration + drift fence)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W1 wave-2 docs lane)

## Subject files

- `scripts/gen_error_codes.py`
- `docs/ERROR_CODES.md` (generated — regenerated, never hand-edited)

## Defect

The doc could drift from its sources in `lib/smalt/arm_gateway/router.ex`,
`lib/smalt/egress_router.ex`, `lib/smalt/arm_gateway/lro.ex`,
`test/compliance/*.exs`.

## Fix

Regenerated from the generators; the `--check` fence is the gate.

## Verification (2026-10-15, W1 wave-2 docs lane, unedited output)

```
$ python3 scripts/gen_error_codes.py --check ; echo "exit=$?"
docs/ERROR_CODES.md up to date
exit=0
$ awk '/^\| /{c++} END{print c-2" data rows (minus header+separator)"}' docs/ERROR_CODES.md
79 data rows (minus header+separator)
$ grep -c '^| ' docs/ERROR_CODES.md
81
```

## Count-note (recorded, not resolved here)

The repair order cited "80 rows"; the on-disk regenerated artifact carries 79
data rows (81 `|`-lines including header and separator). The regeneration is
drift-fenced and exits 0, so the artifact is self-consistent; the 80-vs-79
delta is in the ORDER's claim, not the artifact.
