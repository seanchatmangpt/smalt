# R178e — census regression (PARKED, repair in flight)

Standing: PARTIAL_ALIVE

## Status

PARK receipt, per W11 dispatch: the census-replay substrate window shows a
regression witnessed by its owning lane as FAIL 2/11 on the census suite
(11 census rows, 2 failing). The repair (R178e) is in flight by that lane
and had NOT landed at the time of this receipt. No docs-lane re-run is
possible against a landed artifact — none exists yet; this receipt records
the park, it does not verify a repair.

## Close condition

This receipt flips to PASS (or is superseded) only when the R178e landing
receipt exists with embedded before/after census output. Until then the
census-replay substrate window stays open in WRAP_LEDGER.md.
