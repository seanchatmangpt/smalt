# GWS-13 — WASM+DuckDB Integration Manifest (milestone-doc)

**Standing:** PARTIAL_ALIVE — manifest document landed; every wave item it
registers is PENDING-GWS-n (no GWS-1..12 receipt has landed yet, verified
2026-10-21)
Context: full

## Scope

Authored the integration manifest from landed artifacts only:

- `/Users/sac/graphlaw/docs/wasm-duckdb-integration.md` (new): wave-item
  register GWS-1..12, each typed `PENDING-GWS-n`; provisional integration
  build order (flagged pending GWS-1 confirmation); ABI duckdb-op design
  sketch (GWS-3), data-injection design (GWS-4), SHACL/N3 in-wasm courts
  (GWS-5/6), bridge alignment (GWS-7), perf differential (GWS-8), security
  fuzz (GWS-9), E2E (GWS-10), memory wall (GWS-11), determinism
  cross-engine (GWS-12); case-study cross-reference table mapping
  `COLDCHAIN-CASE-STUDY.md` sections to wave items.

## Grounding (real command output, 2026-10-21)

```
$ grep -rl "GWS-" /Users/sac/graphlaw 2>/dev/null | grep -v target
(no output — zero GWS receipts or artifacts in graphlaw)

$ ls /Users/sac/graphlaw/wasm/src
abi_meta.rs
ffi.rs
lib.rs

$ ls /Users/sac/smalt/lib/smalt/wasm/
bridge.ex
pool.ex
worker.ex
```

Grep and file census confirm: no GWS-n receipt exists on disk in either
repo; every status token in the manifest is PENDING-GWS-n by construction
(no receipt, no flip).

## Cross-references

- `/Users/sac/smalt/docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md` (sandbox
  topology, 64 MiB wall, 3-gate court)
- `/Users/sac/smalt/docs/jira/v26.10.21/GRAPHLAW-SPEC.md` (GL-1..12, ANDON
  wire face, GL-6 dual-governance)
- `/Users/sac/smalt/docs/jira/v26.10.21/COLDCHAIN-CASE-STUDY.md` (worked
  example; numbers are design targets until GWS-8 measures them)
- `/Users/sac/graphlaw/docs/wasm-integration.md` (gl_* packed-u64 ABI)

## Verification

```
$ just docs-dod-check 2>&1 | tail -15
OK    docs/jira/v26.10.16/receipts/r200b-kd71-xopt-props.md
OK    docs/jira/v26.10.16/receipts/r200d-kd68-selector-impl.md
OK    docs/jira/v26.10.16/receipts/r200f-kd46-mgmt-surface.md
OK    docs/jira/v26.10.16/receipts/r200h-kd76-pk-witness-repair.md
OK    docs/jira/v26.10.16/FINAL.md
OK    docs/jira/v26.10.16/RECEIPTS.md
OK    docs/jira/v26.10.16/WRAP_LEDGER.md
OK    docs/jira/v26.10.16/PUBLISH_RECORD.md
OK    docs/jira/v26.10.16/KNOWN_DIVERGENCES.md
OK    docs/RELEASE_NOTES_v26.10.16.md
OK    docs/jira/v26.10.18/FINAL.md
OK    docs/jira/v26.10.18/RECEIPTS.md
OK    docs/jira/v26.10.17/receipts/r241-court-x2-attempt3-typed-red.md
OK    docs/jira/v26.10.17/RECEIPTS.md
OK    README.md
exit=0
```

`docs-dod-check` exit 0: every receipt path named in user-facing docs
exists on disk.

## Receipt

- Doc: `/Users/sac/graphlaw/docs/wasm-duckdb-integration.md`
- **Standing:** PARTIAL_ALIVE (manifest landed; 6 of 12 wave items flipped PASS
  at WRAP-2, remaining items pending receipts)

## WRAP-2 flip sync (2026-10-21)

Manifest status tokens flipped against landed evidence, each re-run this
session on the real tree (`/Users/sac/graphlaw`, branch main, dirty with
concurrent GWS lanes' files):

| Item | Token | Evidence (re-run output, real) |
|---|---|---|
| GWS-5 | PENDING → PASS | `cargo test --test wasm_governance_preflight`: `test result: ok. 3 passed; 0 failed` |
| GWS-6 | PENDING → PASS | `cargo test --test wasm_n3_admission`: `test result: ok. 3 passed; 0 failed`; `wasm_native_differential`: `2 passed; 0 failed` |
| GWS-9 | PENDING → PASS | receipt `graphlaw/receipts/gws-9-wasm-boundary-fuzz.md` (312 hostile calls, 0 panics); re-run `wasm_boundary_fuzz`: `2 passed; 0 failed … 56.02s` |
| GWS-10 | PENDING → PASS | receipt `graphlaw/receipts/gws-10-e2e-coldchain-wasm.md`; re-run `wasm_coldchain_e2e`: `3 passed; 0 failed`; duckdb phases typed PENDING-GWS-3/4 carried honestly |
| GWS-11 | PENDING → PASS | receipt smalt `receipts/gws11-wasm-memory-wall.md`; re-run with `GRAPHLAW_WASM=/Users/sac/graphlaw/priv/graphlaw.wasm`: `test result: ok. 7 passed; 0 failed … 0.58s`. Note: WITHOUT the pinned-binary env the same file runs 4/7 (3 fail on cap expectations vs a rebuilt unpinned binary) — the pinned run matches the receipt of record |
| GWS-12 | PENDING → PASS | receipt smalt `receipts/gws12-cross-engine-determinism.md` (3-leg partition-identical); re-run `gws12_coldchain_cross_engine`: `2 passed; 0 failed` |

Not flipped (no receipt of record on disk): GWS-1, GWS-2, GWS-3, GWS-4,
GWS-7, GWS-8 — remain `PENDING-GWS-n`.

Standing after sync: PARTIAL_ALIVE (6/12 landed).
