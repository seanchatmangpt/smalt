# affidavit-wasm

Fail-closed WASI reactor host for the affidavit C-ABI wasm artifact, plus
receipt admission/sealing on top. Generated from the code surface.

Sibling doc: `docs/reference/reference-affidavit-wasm.md` carries the
prose-level reference (what gets sealed, artifact build/pin, doctor check,
test files). This file is the generated code-surface enumeration; keep
both, link, don't duplicate.

## Modules

| module | file |
|---|---|
| `Smalt.Affidavit.WasmEngine` | `lib/smalt/affidavit/wasm_engine.ex` |
| `Smalt.Affidavit.Seal` | `lib/smalt/affidavit/seal.ex` |

Consumers: `Smalt.TrustProfile` (`lib/smalt/trust_profile/trust_profile.ex`),
`Smalt.Telemetry.AffidavitOcel` (`lib/smalt/telemetry/affidavit_ocel.ex`).

## Engine contract (from `wasm_engine.ex` moduledoc)

1. Read artifact from `config :smalt, :affidavit_wasm_path`
   (default `priv/wasm/affidavit_wasm.wasm`).
2. Admit: sha256 sidecar pin (`priv/wasm/affidavit.sha256` is the
   authority), WASI import allowlist (`wasi_snapshot_preview1` only),
   required exports `_initialize`, `af_abi_version`, `af_alloc`, `af_call`,
   `af_free`.
3. Instantiate with real WASI imports; `_initialize` exactly once
   (wasm32-wasip1 reactor).
4. ABI v1: `af_abi_version() -> u32` (expect 1), `af_alloc(len) -> ptr`
   (0 = over-limit refusal), `af_call(ptr, len) -> (out_ptr << 32) |
   out_len`, `af_free(ptr, len)`.

Wire: UTF-8 JSON `{"op":...}` answered by the module itself
`{"ok":true,...}` / `{"ok":false,"error":{...}}` — never a trap.

## Config keys

| key | default | call site |
|---|---|---|
| `:affidavit_wasm_path` | `priv/wasm/affidavit_wasm.wasm` (`@default_path`) | `wasm_engine.ex:282` |
| `:affidavit_wasm_pin_path` | `priv/wasm/affidavit.sha256` (`@default_pin_path`) | `wasm_engine.ex:306` |

## Refusal vocabulary (fail-closed contract)

From `seal.ex` / `wasm_engine.ex` moduledocs — the admission path never
raises:

- `{:error, :engine_unavailable}` — artifact missing / pin mismatch /
  failed admission / crash / export missing
- `{:error, {:invalid_receipt, field}}` — local validation failure
  (required fields: `subject_sha`, `authority`, `consequence`, `replay`,
  `standing`)
- `{:error, {:seal_refused, code}}` — engine refusal
- `af_alloc` over-limit returns ptr 0 (engine-side over-limit refusal)

## KD cross-links

Canonical register: `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`.

- KD-89 trust_profile PQC path — wasm engine unavailable degrades to a
  typed refusal; PQC verification stays typed-unknown without the artifact
- KD-90 seal latency (b3sum subprocess dominance) — measured p50 4.379ms /
  p95 4.814ms / max 8.275ms

## See Also

- `docs/reference/courts.md` (receipt courts this engine feeds)
- `docs/reference/receipt-ledger.md`