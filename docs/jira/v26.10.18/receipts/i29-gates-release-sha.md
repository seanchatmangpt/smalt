# i29 — Gates Re-run at Release SHA (AZB23-PREFLIGHT table D refresh)

- **Date**: 2026-10-18
- **Subject**: /Users/sac/smalt @ `8b7cbcd190af619d171412ce6f007dd49f4b33a4` (branch main, committed 2026-10-18T23:20:28-07:00)
- **Context**: solo(read-only preflight re-run; no edits outside this receipt, no git state changes, no process kills)
- **Standing**: **PASS** — all three gates exit 0 at current HEAD.

## Scope

Refresh of the three stale rows in `docs/jira/v26.10.18/azsim-burn/AZB23-PREFLIGHT.md` table D
(invariant-gates / publish-dry / docs-dod-check, all PENDING/stale).

## 1. `just invariant-gates` — EXIT 0 (PASS)

Preflight question resolved by reading `test/invariant_gates_test.py` + `gates/common.py`:
the gates harness boots each gate's substrate on **private ephemeral ports**
(`free_port()` bound, exported as `SMALT_TEST_{ARM,ARM_TLS,EGRESS,AMQP,EVENT_HUBS,MCP}_PORT`;
`gates/common.py:34-47`). It does NOT touch canonical 9443/8443/5672, so the colima hold on
those ports does not block it. Ran directly; no eviction, no kill.

Command output (tail):

```
test_all_invariant_gates (__main__.InvariantGatesTest.test_all_invariant_gates)
Every gate: real substrate run -> exit 0, receipt PASS, negatives refused. ... ok

----------------------------------------------------------------------
Ran 3 tests in 202.171s

OK
EXIT=0
```

Per-gate receipts on disk, all `PASS` (`tmp/invariant-gates/`):
cosmos-etag-cas, appconfig-etag-cas, blob-worm, ledger-chain, queue-capacity, lock-clamp,
plus bounds and test-isolation-leak — 8/8 PASS.

Non-vacuity: the harness's own contract (exit 0 only when positive capture passes AND every
negative fixture is refused) held — the DocContractTest tier assertions also ok.

## 2. `just publish-dry` — EXIT 0 (PASS)

```
-- gate 1: mix hex.build -o /tmp/hex-publish-dry/smalt.tar
   PASS (tarball: 793600 bytes; log: /tmp/hex-publish-dry/smalt.tar.build.log)
-- gate 2: inner-tar key grep (pattern: signing.key|verifying.key|\.ggen|keys/)
   PASS (0 matches in contents.tar.gz listing)
-- gate 3: packaged-set leak grep (pattern: athena|/Users/sac)
   PASS (0 hits in packaged set at /tmp/hex-publish-dry/smalt.tar.unpacked)
-- gate 4: python3 scripts/gen_error_codes.py --check
   PASS (docs/ERROR_CODES.md up to date)
== summary ==
PASS [gate1 hex.build]  PASS [gate2 inner-tar keys]  PASS [gate3 leak grep]  PASS [gate4 error-codes]
EXIT=0
```

Clears the preflight's "artifact-freshness half-verified" note: tarball built fresh at this HEAD,
all 4 gates green.

## 3. `just docs-dod-check` — EXIT 0 (PASS)

All checked paths `OK` (no `MISS` lines; sample of tail):

```
OK    docs/jira/v26.10.16/KNOWN_DIVERGENCES.md
OK    docs/RELEASE_NOTES_v26.10.16.md
OK    docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
OK    docs/jira/v26.10.17/RECEIPTS.md
OK    README.md
EXIT=0
```

## Effect on AZB23-PREFLIGHT table D

| Gate | Was | Now |
|---|---|---|
| invariant-gates | PENDING (stale) | **PASS @ `8b7cbcd`** (private-port route, colima-independent) |
| publish-dry | PENDING (stale @ `0009df3`) | **PASS @ `8b7cbcd`, all 4 gates, artifact fresh** |
| docs-dod-check | PENDING (no receipt) | **PASS @ `8b7cbcd`** |

Not addressed by this receipt (still open per preflight): A1–A3 colima stop/quiesce chain,
B1–B3 frozen-tree/burn-ring chain, C1 court-x2 two-green at HEAD.

## Falsifier

Any gate exit != 0, any `tmp/invariant-gates/*-receipt.json` verdict != PASS, any `MISS` line
in docs-dod-check output. None observed.
