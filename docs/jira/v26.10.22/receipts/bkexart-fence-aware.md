# BK-EXART — fence-aware extract_standing (embedded tool output no longer over-matches)

**Standing:** ALIVE — bk146r extractor artifact gone (parses ALIVE from its header), suspects stable at 23, receipt_index rc=0, non-vacuity probes witnessed; zero evidence edited, zero parser widening beyond fence skipping.

Context: solo

## Change

`scripts/receipt_index.py::extract_standing` now tracks ``` fences while scanning:
lines inside a fenced code block are skipped (embedded evidence, not the receipt's
verdict). Header prose region remains the standing source. No change to
`STANDING_LINE_RE` / `standing_field_value` (the BK-WPARSE one-parser contract in
`scripts/witness_all.py` is untouched).

## Non-vacuity probes (embedded, before the regen)

```
$ python3 - <<EOF  (extract_standing on synthetic receipts)
P1 fence-only standing-like token -> ('UNKNOWN', '')      # still flags standing-less
P2 header **Standing:** PARTIAL_ALIVE + fenced `standing=ALIVE, cells=14, exit=0`
   -> ('PARTIAL_ALIVE', 'Standing: PARTIAL_ALIVE — mixed')  # header wins
P3 fenced noise + bottom `Standing: ALIVE` -> ('ALIVE', 'Standing: ALIVE')
EOF
```

## Regen (embedded)

```
$ python3 scripts/receipt_index.py
receipts=1462 sdk=61 total=1523 suspects=23   # rc=0
# suspects count identical to BK-STAND4's 23 (receipt total grew 1459->1462 from
# other lanes' landings, not this change)
# bk146r-pillar-consumers.md now parses ALIVE (was the `ALIVE,` first-token artifact)
$ python3 scripts/witness_all.py --dry-run
[WITNESS-SUMMARY] total=506 witnessed-green=0 stale-typed=342 failed=0 (DRY-RUN)  # rc=0
```

The BK-WPARSE 16-assertion self-check is not present in the tree (no wparse test
file in scripts/ or test/); the three non-vacuity probes above re-demonstrate
the probe class directly against `extract_standing`.

Disclosure: the scripts/receipt_index.py edit was swept into coordinator tick
checkpoint 881252ea (in-flight snapshots, BK-EXART named) before the lane
receipt commit 62ea9575 landed — this lane's commit is the receipt alone.

Receipt: docs/jira/v26.10.22/receipts/bkexart-fence-aware.md
