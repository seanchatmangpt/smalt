# BK-32 — GWS-SEC-FUZZ: security fuzz of the graphlaw wasm boundary (GWS-15, security half)

**Standing**: PASS
**Context**: solo
**Date**: 2026-10-21
**Subject**: `/Users/sac/graphlaw` @ `5dc3c01` (working tree, uncommitted test extension `tests/wasm_boundary_fuzz.rs`), artifact `graphlaw/target/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm` (freshness-pinned: rebuilt whenever any `src/` or `wasm/src` mtime exceeds the artifact, per the test's `wasm_fresh` gate)

## What ran

Extended the GWS-9 fuzz court (`tests/wasm_boundary_fuzz.rs`) from 240 to 1100
deterministic fuzz iterations (seeded xorshift64*, fixed seed — same inputs,
same verdicts) plus the focused boundary cases. Court subject is the REAL
compiled wasm module driven in wasmi through the hostile `gl_call`
ptr/len path (`gl_alloc` → `gl_call` → `gl_free`), exactly as a malicious host
would. Adversarial classes: deep JSON nesting (0..10 000, straddling the
MAX_JSON_DEPTH=64 guard), 16 MiB-boundary frames (exactly-at / exactly-over
`MAX_REQUEST_BYTES`), malformed UTF-8 (lone continuation, 0xFF/0xFE, overlong,
surrogates), SQL-injection tokens (wasm `shacl` op + native `sql_ast` gate),
NaN/Infinity float literals, truncation mid-frame (random cuts), and random
byte mutation inside framed JSON.

Every hostile frame asserts, via `assert_typed`:
1. response is a well-formed JSON envelope with an `ok` bool;
2. `ok:false` carries `error.kind` from the documented `RefusalKind`
   vocabulary (`graphlaw docs/refusals.md`) plus a string message;
3. the instance SURVIVES — a benign `{"op":"capabilities"}` canary answers
   `ok:true` after every hostile call.

## Command output (embedded, real)

```
$ cd /Users/sac/graphlaw && cargo test --test wasm_boundary_fuzz -- --nocapture
running 2 tests
GWS-9 subject: /Users/sac/graphlaw/target/wasm-abi/wasm32-wasip1/wasm/graphlaw_wasm.wasm
GWS-9 native SQL gate: 5 tokens refused, positive-control clean AST conforms = false
test gws9_sql_injection_ast_gate ... ok
GWS-SEC-FUZZ refusal-class histogram (1172 hostile frames):
  ok:true (admitted): 4
  refusal:EngineRejected: 291
  refusal:NotSemanticContent: 28
  refusal:ResourceLimit: 195
  refusal:Unsupported: 654
GWS-SEC-FUZZ PASS: 1172 hostile frames, 0 panics/traps/hangs, every refusal typed (kind in vocabulary), instance survived all calls (canary after each).
test gws9_wasm_boundary_fuzz ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 271.28s
```

## Verdict

- **1172 hostile frames** (>= 1000 required), 0 panics, 0 traps, 0 hangs.
- Refusal-class histogram (frame → verdict class): Unsupported 654,
  EngineRejected 291, ResourceLimit 195, NotSemanticContent 28, ok:true 4
  (the 4 admissions are the designed exactly-at-boundary cases: depth <= 64
  nesting and exactly-at 16 MiB frames — the limit is `>`, not `>=`, by
  contract). Every `ok:false` verdict typed within the documented vocabulary.
- `TierMismatch` / `Ambiguous` are reachable vocabulary entries not exercised
  by these adversarial classes (they require law-tier mismatches, not hostile
  framing); recorded as an observation, not a gap in this row's scope.
- No panic/hang ⇒ no typed defect to file. Non-vacuity: the court's own
  assertions (`assert_typed`, depth-guard exact checks, canary-after-every-
  call) would fail on any untyped refusal or lost instance; the histogram
  total is asserted equal to the frame count.

## Closes

VALIDATION.md row **GWS-SEC-FUZZ** (PENDING-GWS-15, security half) — flipped
to CLOSED citing this receipt. The determinism half of GWS-15 was already
closed by `receipts/gws12-cross-engine-determinism.md` (PASS, 3-leg
differential). Falsifier: re-running
`cargo test --test wasm_boundary_fuzz` on the pinned artifact reproduces the
court; any panic/trap/hang or untyped refusal is the row's reopen condition.
