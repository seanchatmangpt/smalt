# BK-31 — GWS-IN-WASM-COURTS closure: in-wasm graphlaw court set on the real wasmi binary

**Standing**: PASS
- **Context**: solo
- **Date**: 2026-10-22 (UTC)
- **Subject**: `/Users/sac/graphlaw` @ main `5dc3c01` (feat(abi): op-15 duckdb, manifest re-pin), working tree, no branch change
- **Closes**: VALIDATION.md row `GWS-IN-WASM-COURTS` (was PENDING-GWS-14)
- **Lane**: BK-31

## What ran (real wasmi, not the stub)

All four in-wasm court suites against the graphlaw wasm guest, compiled by the
harness itself (`tests/common/mod.rs::wasm_path()` runs
`cargo build -p graphlaw-wasm --target wasm32-wasip1 --profile wasm` into
`target/wasm-abi/`) and instantiated in a **real wasmi Engine**
(`wasmi::{Engine, Instance, Linker, Memory, Store}` + WASI; see
`tests/common/mod.rs`) driving `gl_alloc`/`gl_call`/`gl_free` over linear
memory. No stub runner, no fake module.

```
$ cd /Users/sac/graphlaw && cargo test \
    --test wasm_governance_preflight --test wasm_n3_admission \
    --test wasm_boundary_fuzz --test wasm_coldchain_e2e
EXIT=0
```

Full log: `/tmp/bk31_court.log`. Per-suite results (run 1):

```
wasm_boundary_fuzz:         test result: ok. 2 passed; 0 failed … 56.80s
wasm_coldchain_e2e:         test result: ok. 3 passed; 0 failed … 0.49s
wasm_governance_preflight:  test result: ok. 3 passed; 0 failed … 0.31s
wasm_n3_admission:          test result: ok. 3 passed; 0 failed … 0.30s
```

11/11 tests green, exit 0, single invocation. These suites cover the row's
"SHACL/N3 courts" surface: governance preflight (SHACL admission + hostile
refusals), N3 admission (partition + fail-closed + native differential), plus
boundary fuzz (312 hostile calls, typed refusals, per-call survival canary)
and the coldchain e2e crown (in-guest SHACL + N3 fixed point + native/wasm
byte-identical differential).

## Artifact identity

- Pinned binary: `priv/graphlaw.wasm`
  blake3 `cbc80f07346f025d4e1cd001f21d15474928cb055d4b1a9c0ac7c31c5938dc6a`
  — matches its receipt `priv/graphlaw.wasm.blake3` exactly (recomputed with
  b3sum 2026-10-22).
- Court artifact: `target/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm`
  sha256 `bf7d3dd3…` / blake3 `2ab5cf43…` — freshly rebuilt from the current
  tree (post op-15 duckdb, `5dc3c01`), so it differs from the v26.10.21 pin by
  the op-15 delta. The pin is intact; the courts ran on the current-source
  build, which is the stricter subject.

## Adversarial leg (real runner, `src/bin/graphlaw_run.rs` = `graphlaw-run`)

Positive control + 3 mutated frames through the real packet-4 stdio runner
(`cargo run --features runner --bin graphlaw-run`), each answered by the wasm
guest with a typed refusal, runner exit 0, no trap/panic:

```
frame {"op":"capabilities"}          -> {"ok":true,"abi":1, …}           (positive control)
frame {"op":"no_such_op"}            -> kind:"Unsupported", "unknown op `no_such_op`"
frame {"op":"capabilities"           (truncated) -> kind:"Unsupported", "request is not JSON: EOF while parsing an object at line 1 column 20"
frame {"op":"n3","rules":"}          (mutated)   -> kind:"Unsupported", "request is not JSON: EOF while parsing a string at line 1 column 21"
```

(Two earlier mis-length probes — a 15-byte declared length against a 19-byte
frame, and a 0x0f-prefixed frame — also answered typed `Unsupported` "request
is not JSON: EOF while parsing a string", never trapping; folded into this
leg.)

This is in addition to the in-court adversarial coverage already present
(`gws9_sql_injection_ast_gate`: 5 SQL-injection tokens refused typed,
positive-control clean; `gws9_wasm_boundary_fuzz`: 312 hostile calls, 0
panics/traps, every refusal `kind` in the documented `RefusalKind` vocabulary,
survival canary after every call).

## What this row does NOT claim

- **frozen-duckdb under wasmtime** remains open — that is GWS-2's `-lduckdb`
  wasm32 artifact gap plus GWS-16's op-15 direction; not claimed here.
- The 64 MiB wall is enforced at the ABI layer (GWS-9 finding 2: frames over
  `MAX_REQUEST_BYTES` fail closed at `gl_alloc`, two-staged); the wasmtime-mode
  swap and `GWS-SEC-FUZZ` (PENDING-GWS-15, BK-6) are separate rows.

## Falsifier

A re-run of the same four suites where any test fails, or a mutated frame
through `graphlaw-run` that traps/panics/unwraps instead of answering a typed
`Unsupported`/`ResourceLimit` envelope.

## Replay

```
cd /Users/sac/graphlaw && cargo test \
  --test wasm_governance_preflight --test wasm_n3_admission \
  --test wasm_boundary_fuzz --test wasm_coldchain_e2e
printf '\x00\x00\x00\x13{"op":"no_such_op"}' | \
  cargo run -q --features runner --bin graphlaw-run   # typed refusal, exit 0
```
