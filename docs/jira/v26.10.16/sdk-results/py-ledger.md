# PY-L — Confidential Ledger py probe (KD-43)

- **Subject**: `/Users/sac/smalt`, live substrate (MIX_ENV=test, anonymous auth),
  lane-private ports 39325-39329 (egress=39328 serving `/app/transactions`).
- **SDK**: REST via `requests 2.34.2` on CPython, venv
  `test/sdk-python/.venv-arm` (azure-confidentialledger NOT installed; REST
  surface probed directly in the azure-confidentialledger wire format).
- **Harness**: `test/sdk-python/py_ledger.py` (8 checks),
  `test/sdk-python/run_ledger.sh` (flock-managed boot, MIX_BUILD_ROOT=_build-lane331).
- **Run**: 2026-10-16. **Result: 8/8 checks PASS (exit 0).**

## Command output (receipt)

```
[PASS] append lazy-create subledger (POST /app/transactions -> 201) :: status=201 body={"contents":{"contents":{"msg":"py-ledger-1360b3dd","n":1}},"data_hash":"cba04f7a...","merkle_root":"b22b936f...
[PASS] append receipt has transactionId :: transactionId=1.1
[PASS] append receipt echoes contents (wrapped shape, see receipt) :: {"contents": {"msg": "py-ledger-1360b3dd", "n": 1}}
[PASS] append receipt has signature + merkle chain fields
[PASS] read by transactionId (GET /app/transactions/:txId -> 200) :: status=200
[PASS] read latest (GET /app/transactions/latest -> 200) :: status=200
[PASS] second append -> 201 with new transactionId :: tx1=1.1 tx2=2.1
[PASS] list transactions contains both appends in order :: status=200 ids=['1.1', '2.1']

[py-ledger] 8/8 checks PASS
[pyl] probes exit=0
```

## Lazy-create append (scope trim, 80/20)

Appending to a never-created subledger returns 201 with `transactionId=1.1`
— the emulator lazily materializes the subledger, matching real-service
append-materializes semantics at the probe surface. The lib/ existence fence
(`:ledger_enforce_existence`, 404-class) is a separate coordinated pivot and
not exercised here.

## Divergences observed

1. **Contents double-nesting** (documented emulator convention, pinned by
   probe check 3): POST body `{"contents": {...}}` yields wire receipt
   `{"contents": {"contents": {...}}}` — azure-confidentialledger surfaces
   the payload directly at `receipt["contents"]`. Inner payload round-trips
   intact; shape-only divergence. Candidate KD row for the ledger family;
   left unregistered here (row minting owned by the KD registrar).

Standing: PASS (probe lane). KD-43 close condition ("probe authoring") is
satisfied by this receipt; the register flip (`kd_flip.py --apply`) is gated
on this receipt's mtime vs the shim/subject and owned by the coordinator.
