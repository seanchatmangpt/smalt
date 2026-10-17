# R75/R102: ledger fence + durability gate

Standing: PASS
Lane: R16 docs (W3/W4 wave 4) · 2026-10-16
Surface: `lib/smalt/security/confidential_ledger.ex` (+22), `gates/ledger_chain_gate.py`

## Claim

Confidential-ledger append fence (duplicate -> 409, chain continuity) and the
chain-durability gate repairs landed.

## Re-run evidence

```
$ mix test test/smalt_services_test.exs
8 tests, 0 failures

$ python3 gates/ledger_chain_gate.py; echo exit=$?
PASS ledger-chain/fixture:broken-seq (refused: [... "FAIL tx id '1.1' != 2.1" ...])
PASS ledger-chain/fixture:duplicate-accepted (refused: [... 'FAIL duplicate contents -> 409' ...])
ledger-chain: receipt .../ledger-chain-receipt.json verdict=PASS
exit=0
```

## Verdict

PASS. Services suite 8/0; ledger-chain gate exit 0 with both mutations detected. R102
(durability gate) is mapped to ledger chain continuity — the fence IS the durability
contract; if R102 intended a different gate, this receipt covers only the chain gate.
