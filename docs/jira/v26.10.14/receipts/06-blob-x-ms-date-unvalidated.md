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
