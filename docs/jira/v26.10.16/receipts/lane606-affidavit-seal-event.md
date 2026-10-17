# Lane 606 — affidavit.seal OCEL event

Standing: ALIVE (fence test green on real sink)

## Diff

- `ggen-marketplace` `packs/smalt-substrate-pack/ontology.ttl`: added
  `smalt:et-affidavit-seal` → `"affidavit.seal"` (closed OcelEventType row).
- `/Users/sac/smalt/lib/smalt/ocel/event_registry.ex`: regenerated via
  `mix ggen_igniter.sync` (event_types + object_types queries); replay is
  byte-identical (second run: unchanged/skipped, no "wrote" line).
- `/Users/sac/smalt/lib/smalt/telemetry/affidavit_ocel.ex`: NEW emitter,
  registry-gated fail-safe (CourtOcel pattern). Attributes: `subject_sha`,
  `verdict`, `engine_hash`; one `document` object keyed by subject SHA
  (matter isolation: ids only).
- `/Users/sac/smalt/test/affidavit_ocel_emit_test.exs`: NEW fence test
  (3 tests, 0 failures) — real-sink emission passes the registry gate and
  closes references; anti-vacuity flip: mutated type
  `affidavit.seal.MUTATED` is dropped (`{:ok, :dropped}`, log never
  created); fail-safe: unwritable sink returns `{:error, :erofs}`,
  never raises.

## Pack-lock re-pin receipt

`.ggen_igniter/manifest.json` entry
`...templates/event_registry.ex.eex=>lib/smalt/ocel/event_registry.ex`
re-pinned to
`sha256:c8d1dc54c8949dc8e96416179f2d123f8ebd7512ec4a7d16f44f3bd65cdc8985`
at `2026-10-16T21:51:02.212536Z` (regenerated under
`MIX_BUILD_ROOT=_build-lane606`).

## Compile-freeze SLA disclosures (lane 606 unblocking another lane's in-flight files)

1. `lib/smalt/affidavit/seal.ex`: added missing `validate/1` (presence check
   of the five R fields) — it was referenced but undefined; compile was
   broken for all lanes.
2. `lib/smalt/affidavit/seal.ex`/`wasm_engine.ex`: the WasmEngine lane later
   rewrote both files (I did not revert their rewrite, which superseded my
   `validate/1` fix); I additionally silenced two `--warnings-as-errors`
   blockers in `wasm_engine.ex` (unused `bytes` → `_bytes`, unused
   `@expected_abi_version` attribute) during the frozen window.

## Command receipts

- `MIX_BUILD_ROOT=_build-lane606 mix smalt.gen` → reactor reconciliation OK;
  registry.ex unchanged; event_registry.ex written then replay-identical.
- `MIX_BUILD_ROOT=_build-lane606 mix test test/affidavit_ocel_emit_test.exs`
  → `3 tests, 0 failures` (real sink, real registry gate).
