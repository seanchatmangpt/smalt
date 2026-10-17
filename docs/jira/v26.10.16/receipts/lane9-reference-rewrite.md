# lane9-reference-rewrite

Standing: PARTIAL_ALIVE

Scope: docs/reference/ rewrite per lane 9 spec — one doc per subsystem,
generated from the code surface (module lists via `grep -h "^defmodule"`,
config keys via `grep get_env(:smalt`, refusal vocabulary from the generated
`docs/ERROR_CODES.md` rows per surface), KD cross-links naming every
divergence with its register row.

## Per-subsystem doc list

- `docs/reference/arm-gateway.md` — 5 modules, 9 config keys, 17 ARM error
  codes, KD-24..KD-32, KD-54..KD-59, KD-78..KD-83, KD-87, KD-91, KD-92
- `docs/reference/egress-data-plane.md` — 13 modules, 11 config keys, 40
  egress codes, KD-01..KD-17, KD-22..KD-23, KD-33/34/36/44/52/60..67,
  KD-75, KD-93, KD-94
- `docs/reference/amqp-service-bus.md` — 16 modules, 8 config keys, $mgmt
  501 vocabulary + atoms, KD-18..KD-21, KD-45..KD-51, KD-53, KD-68..KD-74,
  KD-77, KD-84..KD-86, KD-88
- `docs/reference/affidavit-wasm.md` — 2 modules + engine contract, 2
  config keys, fail-closed refusal ladder, KD-89, KD-90; pointer to the
  pre-existing prose doc `reference-affidavit.md` (kept, linked not
  duplicated)
- `docs/reference/spc.md` — `Smalt.Spc.Drift` laws (registry-gated,
  fail-closed, matter-isolation, fail-safe), no config keys, no KD rows
  name the surface
- `docs/reference/courts.md` — 7 invariant gates + 21 shim courts, flip
  law, GAP-AUD1-01 note, no KD rows minted
- `docs/reference/receipt-ledger.md` — 7 modules incl.
  `Smalt.Security.ConfidentialLedger`, chain law from
  `gates/ledger_chain_gate.py`, refusal vocabulary
  (409 LedgerItemAlreadyExists, 404 TransactionNotFound, 400
  InvalidLedgerName), KD-42/43
- `docs/reference/kd-register.md` — refreshed counts (stale 78/52/26 →
  94 rows / 72 OPEN / 22 CLOSED: 13 CLOSED-WITH-RECEIPT + 9
  CLOSED-SIMULATED, counted from the on-disk table this session)

## Gate output (embedded, this session)

```
DOD_EXIT=0   (just docs-dod-check: 50 OK / 0 MISS)
NAMING_EXIT=0
[NAMING-SWEEP] PASS: 0 violations / 46 allowed
```

## Caveats

- Lane 6 gate `DOCS-INVENTORY.md` was NOT on disk at lane 9 start
  (`find docs -name "*INVENTORY*"` empty); lane 9 proceeded on the
  self-contained spec in the dispatch. The docs-dod-check list pins only
  the pre-existing set — it does not yet name the new lane-9 files; the
  gate still exits 0.
- The docs-dod checklist predates this lane; adding the new docs to the
  pinned list is a coordinator/lane-6 decision.
- arm-gateway doc cites the ERROR_CODES drift-fence finding (r125:
  `InvalidApiVersion` literals at egress_router.ex:1767/1786 lacking
  paired send status) as pending, not resolved.
