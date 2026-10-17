# Receipt — R8 (receipt-index-check real gate + injected-drift flip)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PASS
- **Date:** 2026-10-15 (witnessed by W1 wave-2 docs lane)

## Subject files

- `justfile.d/13-receipt-index.just` (`receipt-index-check` recipe)
- `scripts/receipt_index.py`

## Defect

`receipt-index-check` was previously a restatement, not a gate that can exit 1.

## Fix

The recipe now snapshots committed bytes, regenerates once via
`scripts/receipt_index.py`, diffs, fails loudly on any drift, and restores the
pre-run bytes via trap.

## Verification (2026-10-15, W1 wave-2 docs lane, unedited output)

Clean case — gate admits a matching index:

```
$ just receipt-index-check ; echo "exit=$?"
receipt-index: clean (committed index matches regeneration)
exit=0
```

Injected-drift flip (non-vacuity witness): appended
`DRIFT-MARKER R8-injected` to `docs/jira/v26.10.14/RECEIPTS.md`, then:

```
$ just receipt-index-check ; echo "exit=$?"
...
-DRIFT-MARKER R8-injected
receipt-index: DRIFT — committed index does not match regeneration (restored committed bytes)
error: recipe `receipt-index-check` failed with exit code 1
exit=1
```

The flip IS the proof: the gate refuses a drifted index (exit 1), it does not
vacuously admit.

## Finding disclosed to the recipe owner (not in this lane's authority)

The recipe's trap restores the PRE-CHECK bytes, not "committed bytes": in the
drift witness the drifted marker line survived the run (my lane's backup at
/tmp/r8-backup.md was used to restore the true working-tree bytes afterward,
verified byte-exact). A drift-injection court must keep its own pre-injection
copy. Recipe text/echo message should be reworded or the trap re-pointed.
