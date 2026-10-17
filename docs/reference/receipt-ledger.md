# receipt-ledger

Confidential Ledger surface plus the semantic read layer over it.
Generated from the code surface.

## Modules

| module | file |
|---|---|
| `Smalt.Semantic.LedgerEntry` | `lib/smalt/semantic/ledger_entry.ex` |
| `Smalt.Semantic.StoreRead` | `lib/smalt/semantic/store_read.ex` |
| `Smalt.Semantic.Evidence` | `lib/smalt/semantic/evidence.ex` |
| `Smalt.Semantic.Resource` | `lib/smalt/semantic/resource.ex` |
| `Smalt.Semantic.Domain` | `lib/smalt/semantic/domain.ex` |
| `Smalt.Semantic.R2RMLGuard` | `lib/smalt/semantic/r2rml_guard.ex` |
| `Smalt.Security.ConfidentialLedger` | `lib/smalt/security/confidential_ledger.ex` (ledger write path; emits `InvalidLedgerName` / `LedgerItemAlreadyExists`) |

Store: `:smalt_ledger_transactions` (an ETS table in `Smalt.Store`; see
`docs/reference/ets-tables.md`). Ledger writes go through
`POST /app/transactions` on the egress surface; the chain law is
`merkle_root = sha256(prev_hash <> data_hash)` with genesis prev of 64
zeros and `transactionId = "<seq>.1"` monotonic (pinned by
`gates/ledger_chain_gate.py`).

## Config keys

| key | default | call site |
|---|---|---|
| `:receipt_signing_key` | `nil` | `config/config.exs` (receipt signing; nil = unsigned dev receipts) |

`lib/smalt/semantic/*.ex` modules read no `Application.get_env` keys — the
read layer is config-free over `Smalt.Store`.

## Refusal vocabulary

- 409 `LedgerItemAlreadyExists` — duplicate contents refused (gate-pinned)
- 404 `TransactionNotFound` — unknown transaction id (egress surface,
  ERROR_CODES)
- 400 `InvalidLedgerName` — non-UTF8 / non-binary ledger name fence
  (receipted r131, v26.10.16 W5/W6)
- `Smalt.Semantic.StoreRead` typed refusals: non-map rows and vacuous
  identity ("transactionId") refused on `:smalt_ledger_transactions`

## KD cross-links

Canonical register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.

- KD-42 / KD-43 — ledger probe cells (TS/PY), closed CLOSED-WITH-RECEIPT

## See Also

- `docs/ERROR_CODES.md` (generated; `just gen-error-codes`)
- `docs/reference/ets-tables.md`
- `docs/reference/affidavit-wasm.md` (receipt sealing)
- `docs/SEMANTIC_PROJECTION.md`