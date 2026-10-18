# i21b — coordinator-approved flips: NEXT_WINDOW strike + KD-04 WIRE_PARITY prose

Standing: **PASS**
Date: 2026-10-17
Lane: coordinator-approved flips (solo)

## Scope

1. Applied `NEXT_WINDOW-3.2-item10-strike.draft.md` (Edits A/B/C) to
   `docs/jira/v26.10.16/NEXT_WINDOW.md` (§3 item 2, §4 table row 10) and
   `docs/jira/v26.10.17/NEXT_WINDOW.md` (§4 header + DONE-marked close-condition
   bullet). Gate honored: applied only after
   `docs/jira/v26.10.17/receipts/r244-publish-record.md` was verified on disk
   filled with real output (publish-dry 4/4 PASS, `mix hex.build` exit 0,
   ex4pm 26.10.8 from :hexpm, checksum `d507fd16…24 50fd2`-class match per
   receipt). Draft deleted post-apply.
2. KD-04 registered-divergence prose updated in `docs/WIRE_PARITY.md`:
   rows :122 (BlobService account plane) and :132 (Blob Storage) now cite the
   rename to `InvalidQueryParameterValue` with witness
   `docs/jira/v26.10.16/receipts/kd04-token-rename-witness.md`; the SDK-wave
   cross-reference paragraph (:269-270 region) now states the rename landed in
   `lib/` 2026-10-17 and the KD-04 row stays OPEN pending the next
   `kd_flip.py` pass (code rename, no shim, no `# KD-COVERS`). No GAP token
   touched — GAP flips remain receipt-gated separately.

## Verification (real output)

```
$ just docs-dod-check
OK    docs/jira/v26.10.14/receipts/ws-12-e2e.md
... (54 OK lines, all paths checked)
OK    README.md
DOD_EXIT=0
```

`just docs-dod-check` exit 0 (56/56 OK, 0 MISS).

```
$ grep -c "^OK" <(just docs-dod-check)   # via captured run
56
$ grep -c MISS  -> 0
```

Post-edit grep confirmations:

```
$ grep -n "InvalidQueryParameter" docs/WIRE_PARITY.md
122: ... answers 400 `InvalidQueryParameterValue` (renamed from `InvalidQueryParameter` 2026-10-17 per KD-04; witness ...)
132: ... typed 400 `InvalidQueryParameterValue` (KD-04 rename landed 2026-10-17; witness ...) via `BlobStorage.check_maxresults/1`
269: ... rename landed in lib/ 2026-10-17 ... kd04-token-rename-witness.md ...
$ ls docs/jira/v26.10.17/NEXT_WINDOW-3.2-item10-strike.draft.md
ls: ...: No such file or directory
```

## Standing

PASS — all three flips landed, gate green, draft removed. No git actions
performed (per lane scope). GAP tokens in WIRE_PARITY.md unchanged.
