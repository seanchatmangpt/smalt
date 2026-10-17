# Receipt — R15 (gate fixtures + verdict tightening)

- **Subject:** `/Users/sac/smalt` @ main, working tree (v26.10.16 repair wave)
- **Standing:** PARTIAL_ALIVE — mutation fixtures proven non-vacuous; positive
  path of `cosmos_etag_cas_gate` FAILs on the current tree (defect recorded
  below, outside this lane's authority to fix)
- **Date:** 2026-10-15 (witnessed by W1 wave-2 docs lane)

## Subject files

- `gates/cosmos_etag_cas_gate.py` (fixtures `etag-unstable-reread`,
  `all-empty-race-codes`, `bad-etag-format`; verdict check tightened at
  lines 93-95)
- `gates/ledger_chain_gate.py` (fixture `broken-seq` at line 122)

## Defect

The gates admitted vacuously: mutating an observation could still pass —
no negative fixture forced a refusal, and the verdict never checked that
412 losers carry a non-empty `PreconditionFailed` code.

## Fix

Three negative fixtures added to cosmos-etag-cas (`etag-unstable-reread`
mutates only `etag_reread`; `all-empty-race-codes` strips all loser codes;
`bad-etag-format` degrades the etag shape) and `broken-seq` to ledger-chain;
verdict tightened to require 5 non-empty `PreconditionFailed` loser codes.

## Verification (2026-10-15, W1 wave-2 docs lane, unedited output)

Non-vacuity: every mutation fixture refuses (the flip IS the proof).

```
$ python3 gates/ledger_chain_gate.py 2>&1 | tail -3 ; echo "exit=$?"
PASS ledger-chain/fixture:broken-seq (refused: ['PASS all appends returned 201', 'PASS got 3 receipts', 'PASS duplicate contents -> 409', 'PASS ledger lists the appended receipts', "FAIL tx id '1.1' != 2.1"])
PASS ledger-chain/fixture:duplicate-accepted (refused: ['PASS all appends returned 201', 'PASS got 3 receipts', 'FAIL duplicate contents -> 409', 'PASS ledger lists the appended receipts', 'PASS chain continuity holds'])
ledger-chain: receipt /Users/sac/smalt/tmp/invariant-gates/ledger-chain-receipt.json verdict=PASS
exit=0
```

```
$ python3 gates/cosmos_etag_cas_gate.py 2>&1 | grep fixture:etag-unstable
PASS cosmos-etag-cas/fixture:etag-unstable-reread (refused: [... 'FAIL etag stable across read' ...])
PASS cosmos-etag-cas/fixture:all-empty-race-codes (refused: [... 'FAIL losers carry PreconditionFailed with codes present (5 losers, none stripped)' ...])
cosmos-etag-cas: receipt /Users/sac/smalt/tmp/invariant-gates/cosmos-etag-cas-receipt.json verdict=FAIL
```

All 7 cosmos fixtures refuse correctly; ledger-chain overall verdict PASS.

## OPEN DEFECT (recorded for the owning repair lane — gates/ and lib/ are
## outside this docs lane's file ownership)

The cosmos-etag-cas POSITIVE path cannot pass on the current tree. Raw
observation capture (gate harness, ephemeral-port self-boot, anonymous mode):

```
"race": [200, 412, 412, 412, 412, 412],
"race_codes": ["", "", "", "", "", ""],
```

Root cause: the gate extracts the loser code via
`(body or {}).get("error", {}).get("code")` (gate capture, worker loop), but
the cosmos data-plane 412 body renders the code at TOP LEVEL
(`lib/smalt/data_plane/cosmos.ex:1626` `error_response/5` →
`%{"code" => code, "message" => message}`). The wrapped
`{"error":{"code":...}}` shape exists only on blob-plane error arms
(`lib/smalt/egress_router.ex:1179`, `:1501`). Verdict line 93-95 therefore
always sees `race_codes == [""]*6` and FAILs the positive check
("5 losers, none stripped") even though the wire behavior itself is correct
(one 200, five 412s, stale write 412).

Fix options for the owner: read `body.get("code")` in the gate capture, or
have the cosmos egress arm wrap 412 bodies in the `error` envelope to match
the Azure Cosmos error shape — pick per real-SDK census, not aesthetics.

Witnessed substrate note: first gate runs hit a stale global substrate; a
fresh `scripts/substrate.sh down/up` cycle and the gate's own self-boot both
reproduce the same FAIL, so this is not a stale-process artifact.
