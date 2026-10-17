# Receipt — R20 (naming-sweep zero violations)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W1 wave-2 docs lane)

## Subject files

- `scripts/naming_sweep.sh` (allow-list scoped; excludes generated/lane dirs)

## Defect

Naming violations (redundant suffix/decorator drift across surfaces) were
open at audit time.

## Fix

Violations repaired by their owning lanes; the sweep is the gate.

## Verification (2026-10-15, W1 wave-2 docs lane, unedited output)

```
$ bash scripts/naming_sweep.sh >/tmp/ns.out 2>&1; echo "exit=$?"; tail -1 /tmp/ns.out
exit=0
[NAMING-SWEEP] PASS: 0 violations / 52 allowed
```
