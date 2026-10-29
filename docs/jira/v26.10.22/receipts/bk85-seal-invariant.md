# BK-85 — Seal invariant gate root cause + successful-seal court (lane bk85)

**Standing:** **ALIVE** — root cause fixed in the caller; successful seal witnessed
on the real artifact; gate proven non-vacuous; KD-164 minted.
Context: solo
Date: 2026-10-21
Repo: /Users/sac/smalt (main, dirty shared checkout; lane owns
`lib/smalt/affidavit/wasm_engine.ex` + new court
`test/internal/bk85_seal_invariant_court_test.exs` + shim court
`scripts/shim_court/bk85_gate_court.sh` + witness
`scripts/shim_court/bk85_gate_witness.exs` + KD register row KD-164)

## Root cause (finding (a), SPOF-3 observation)

Caller bug, not layout drift, not a gate bug, not an upstream contract change.
The guest contract is exactly as documented:

- upstream `/Users/sac/affidavit/affidavit-wasm/src/ffi.rs:156-191`
  (`affi_admit_and_seal`): writes `blake3(delta)` at CTRT [70..102], tariff
  LE-u64 [167..175], modality [175], `GAIN_5050\0…` anchor [151..167],
  nullifier `blake3(delta_hash)` at [176..208], 352 bytes total.

The host caller `run_seal/5` allocated the guest delta block via
`af_alloc(len)` but **never wrote the delta bytes into it** — the guest hashed
stale heap, so the host `blake3(delta)` invariant leg refused EVERY seal with
`{:error, :invariant_violation}` deterministically (the structural legs passed;
the blake3 leg could never bind). No successful seal was possible anywhere in
the tree — trust_profile's PQC witness therefore always fell back to
`:PQC_NOT_PROVISIONED`.

## Witness (side-by-side, real artifact, real b3sum)

Driving wasmex directly (explicit write of the delta block): guest [70..102]
== host `b3sum --raw` blake3("probe-delta-bk85") ==
`4efa5868cb5d9ee5b936bf29d87d82966b505fd783dd871ad6c4864083a35024` — the gate
legs all hold on a correctly-written block.

Driving the engine GenServer path (pre-fix): guest [70..102] ==
`e572dff82304700b856a555ac3a4558d0df3646a3727816500270a93c66aac1e` — stale
heap, not blake3(delta). Deterministic refusal witnessed at
`call_admit_and_seal/4` on any probe delta.

## Fix

`lib/smalt/affidavit/wasm_engine.ex` `run_seal/5` now writes the delta bytes
into the guest block before the seal export (`:ok = write_mem(store, memory,
delta_ptr, delta)` under the existing try/after free; a write failure raises
inside the caller-owned rescue arm and is classified `:engine_unavailable` —
never a server crash). No guest layout change, no gate change.

## Court (successful-seal legs — test/internal/bk85_seal_invariant_court_test.exs)

Chicago: real wasm artifact (`priv/wasm/affidavit_wasm.wasm`, sha-pinned), real
NIF, real `b3sum`. Bounded polls only, zero sleeps.

1. **Successful seal** via `call_admit_and_seal/4`: `{:ok, %{ctrt_bytes,
   pqc_receipt}}`, 352 bytes; magic/version/tariff/modality/anchor legs;
   **blake3 leg binds**: guest [70..102] == host `b3sum --raw`
   blake3(delta); `pqc_receipt` == verified nullifier segment [176..208]
   (no more `unverified_blake3_host` fallback).
2. **FORBID modality**: seal with modality 0x02 binds byte [175] = 0x02,
   blake3 leg still binds.
3. **JSON seam end-to-end**: `Smalt.Affidavit.Seal.admit_and_seal/2` seals a
   five-R-field receipt; `sealed` is 352 bytes; [70..102] ==
   blake3(canonical JSON).

```
MIX_BUILD_ROOT=_build-bk85 asdf exec mix test \
  test/internal/bk85_seal_invariant_court_test.exs          # exit 0 — Result: 3 passed
MIX_BUILD_ROOT=_build-bk85 asdf exec mix test \
  test/internal/bk85_seal_invariant_court_test.exs \
  test/internal/spof3_affidavit_engine_court_test.exs \
  test/internal/wasm_nif_lifecycle_test.exs                 # exit 0 — Result: 9 passed (4.2s)
```

## Tamper leg (gate non-vacuity — scripts/shim_court/bk85_gate_court.sh)

An in-process test cannot inject a tampered ctrt without a shim, so the
tamper leg is a shim court per repo convention:

- AFTER (landed): real seal succeeds.
- SHIM: gate comparison `raw == binary_part(ctrt, 70, 32)` → `... and false`
  (marked SHIM-COURT).
- BEFORE (shimmed): every real seal refuses `{:error, :invariant_violation}`.
- RESTORE: sha256 byte-exact (verified).

```
scripts/shim_court/bk85_gate_court.sh   # exit 0
# [SHIM] AFTER witness passed (landed engine seals)
# [SHIM] shim applied (host blake3 leg corrupted; SHIM-COURT marker present)
# [SHIM] BEFORE witness passed (shimmed engine refuses :invariant_violation)
# [SHIM] RESTORE verified byte-exact (sha256 match)
# [PASS] bk85_gate_court: non-vacuous
```

The flip IS the proof: a corrupted comparison leg flips every seal to the
typed invariant refusal — the gate is live, not a pass-through.

## KD register

KD-164 minted in the canonical register
(`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md`, rows now KD-01..KD-164 / 161
rows): surface = affidavit wasm seal CTRT invariant gate; divergence =
host-caller skipped the guest input write (upstream layout vindicated);
close condition met 2026-10-21; status **CLOSED-WITH-EVIDENCE** (court + shim
court receipts above). Re-open falsifier named in the row (court test red or
shim court [FAIL:*]).

## Out of scope / pre-existing

- `test/internal/ja15_error_logger_court_test.exs:235` syntax error (JA-15b
  lane) — whole-dir `test/internal/` compile-aborts; unchanged here
  (compile-abort ≠ failure count, per SPOF-3 receipt).
