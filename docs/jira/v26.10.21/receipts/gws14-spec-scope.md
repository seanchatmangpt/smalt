# GWS-14 — WASM-SANDBOX-SPEC honest scoping amendment (milestone-doc)

- **Lane**: GWS-14 spec-scope (milestone-doc)
- **Date**: 2026-10-21
- **Subject**: `docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md`
- **Authority**: GWS-14 skeptic audit `receipts/gws14-skeptic.md` (ALIVE as of 2026-10-21)
**Standing**: ALIVE
Context: pair (spec amendment authored against the GWS-14 skeptic audit findings)

## Diff

```
$ git diff --stat docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md
 docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md | 67 ++++++++++++++++++++++++++++++++
 1 file changed, 67 insertions(+)
```

Pure insertion; original §1-4 (target state) preserved verbatim.

## What landed

1. Header amendment block: §1-4 are TARGET state, typed per the audit's SUSPECT
   on the mandatory-seam gap.
2. **§5 Current State**: stub mode is default (host-side-only 64 MiB wall;
   deterministic Elixir stand-in; `graphlaw_duckdb.wasm` does not exist);
   guard is config-optional — unguarded transitions admitted, `Bridge.eval`
   has zero production callers, engine not on the admission path (audit §5
   SUSPECT carried); fail-closed verified inside the engine only; zero-NIF
   claim scoped strictly to `lib/smalt/wasm/` — repo-wide FALSE (Wasmex NIF
   in `lib/smalt/affidavit/wasm_engine.ex`).
3. **§6 Path to Directive 1-3 Compliance**: mandatory-seam decision (wire
   Bridge into executor guard seam OR scope Directive 1/3 opt-in — no silent
   middle); graphlaw_duckdb.wasm build (GWS-2 DOCS_RS path + GWS-17 gate
   restoration); determinism differential (PENDING-GWS-12); 14-op vs
   duckdb-op re-scope decision (GWS-1 recommendation 3); run+receipt
   wasm_sandbox_court.exs (PENDING-GWS-13).
4. **§3a Gate standing**: 3 gates marked DEMONSTRATED-ON-STUB /
   PENDING-ON-REAL-BINARY, each row typed.

## Verification (real output)

```
$ just docs-dod-check
OK    README.md
EXIT=0
```
(63/63 paths OK, exit 0 — full listing in the run log; the gate is fail-closed
on any MISS.)

## Not done here

- No GAP token minted or flipped; no KD row touched; no register flips.
- Court run receipts (PENDING-GWS-12/13/14/17/18) remain with their owner lanes.
