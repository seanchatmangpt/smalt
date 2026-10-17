# R48: cosmos etag CAS gate

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `gates/cosmos_etag_cas_gate.py` (modified), fixture courts

## Claim

Etag CAS invariant gate repairs land with positive + mutation fixtures and a fail-closed
verdict.

## Re-run evidence

```
$ python3 gates/cosmos_etag_cas_gate.py; echo exit=$?
PASS cosmos-etag-cas/fixture:etag-not-refreshed (refused: [...'FAIL etag refreshed on write'...])
PASS cosmos-etag-cas/fixture:stale-write-accepted (refused: [...'FAIL stale etag reused -> 412'...])
PASS cosmos-etag-cas/fixture:etag-unstable-reread ...
PASS cosmos-etag-cas/fixture:all-empty-race-codes ...
PASS cosmos-etag-cas/fixture:bad-etag-format ...
cosmos-etag-cas: receipt /Users/sac/smalt/tmp/invariant-gates/cosmos-etag-cas-receipt.json verdict=PASS
exit=0
```

## Verdict

PASS. Exit 0 with all five fixtures refusing mutated observations (each fixture's FAIL line
is the mutation being detected). Positive-path behavior cross-checked by cosmos blob test
batch: 254 tests, 0 failures.
