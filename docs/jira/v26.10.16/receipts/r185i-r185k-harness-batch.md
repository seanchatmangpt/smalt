# Receipt — R185i / R185k (test harness batch)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 late docs sweep, lane 267)
- **Standing:** PASS (R185i); PASS (R185k)
- **Date:** 2026-10-16 (W-late docs lane, batch 2 of 5)

## What landed

- **R185i** (test_helper idiom + frame property): `test/test_helper.exs:75-93`
  — `wait_gone/2` shutdown-wait helper is all-`defp` (mixed def/defp on one
  name is a compile error; the SHIM-COURT-lane-R185i unblock is disclosed
  in-source at line 81). Frame property suite at
  `test/property/frame_codec_property_test.exs` runs the AMQP frame codec
  under property tests.
- **R185k** (receipt_index standing extraction): `scripts/receipt_index.py:54`
  — "an explicit Standing line outranks any SHIM-COURT-free lane edit
  (R185k)", i.e. the indexer now extracts the standing from an explicit
  `Standing:` line in receipts instead of inferring it. Per its lane report,
  this corrected 7 receipts' standing in the regenerated
  `receipts/INDEX.md`.

## Verification (2026-10-16, lane 267, unedited output)

```
$ MIX_BUILD_ROOT=_build-lane267 mix test test/property/frame_codec_property_test.exs
7 properties, 0 failures
exit=0
$ grep -n "R185" test/test_helper.exs
81:  # name is a compile error — SHIM-COURT-lane-R185i unblock, disclosed).
$ python3 scripts/receipt_index.py
receipts=274 sdk=15 total=289 suspects=21
wrote /Users/sac/smalt/docs/jira/v26.10.14/RECEIPTS.md
wrote /Users/sac/smalt/docs/jira/v26.10.14/receipts/INDEX.md
exit=0
```

(Indexer note: `scripts/receipt_index.py` globs every milestone version dir
for receipt input but writes `RECEIPTS.md`/`INDEX.md` into the v26.10.14
root; the 274 count includes the v26.10.16 batch receipts.)

## Standing

PASS — R185i suite-grounded (7 properties, 0 failures); R185k grounded by
the in-source marker plus the regen effect visible in
`receipts/INDEX.md` (counts in the regen output above, run after the batch
writes completed).
