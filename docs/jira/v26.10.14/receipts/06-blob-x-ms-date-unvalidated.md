# Receipt — GAP(blob-x-ms-date-unvalidated) → typed UNSUPPORTED (lane 06)

- **Status:** UNSUPPORTED for v26.10.14 — for lane 13 consumption.
- **Surface:** blob lane `:8443` (`egress_router.ex` blob_route guard).

## Divergence

`x-ms-date` is neither required nor validated on blob routes (only
`x-ms-version` presence is enforced by the `blob_route` guard). Real Azure
requires `x-ms-date` (or `Date`) for 2011-08-18+ versions on authorized
requests and rejects stale dates beyond the allowed skew.

## Why UNSUPPORTED this window

Bounded future fix = presence check + RFC 1123 parse + skew window **shared
with the other `:8443` planes** — a cross-plane header-validation seam, not a
blob-local edit; landing it blob-only would introduce a new split-grammar
divergence of the same class lane 06 just closed for maxresults.

## Where documented

`docs/WIRE_PARITY.md` blob row (`UNSUPPORTED(blob-x-ms-date-unvalidated)`);
`docs/compliance/C4_BLOB.md` §x-ms-date (re-graded GAP → UNSUPPORTED).

---

## On-disk re-verification (2026-10-22, lane BK-SUSP3)

The UNSUPPORTED disposition is re-verified current, not superseded: the GAP
token is still live and no `x-ms-date` validation exists on the blob surface.

```
$ grep -c "GAP(blob-x-ms-date-unvalidated)" docs/WIRE_PARITY.md -> 1, exit=0 (token live, still OPEN)
$ grep -rn "x-ms-date" lib/smalt/egress_router.ex              -> 0 matches, exit=0 (no validation landed)
$ grep -rn "x-ms-date" test/data_plane/blob_hardening_test.exs test/wire/egress_wire_test.exs
  -> exit=2 (no matches in either blob court file)
```

The date-fence that DID land is the sibling x-ms-version grammar validation
(`KD-COVERS: KD-67`, `lib/smalt/egress_router.ex` `plausible_version_value?/1`
— `YYYY-MM-DD` regex + calendar parse, 400 `MissingXMsVersion`); it does not
cover `x-ms-date`. Original UNSUPPORTED evidence untouched. Standing as of
this addendum: the receipt's UNSUPPORTED typing remains accurate as-of-date;
the row stays flagged until the cross-plane header-validation seam lane lands
and mints its own successor receipt. Owner: future cross-plane
header-validation seam (the bounded fix this receipt already scopes).
