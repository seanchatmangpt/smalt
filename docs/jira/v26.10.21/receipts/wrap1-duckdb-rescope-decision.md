# WRAP-1: duckdb-in-wasm re-scope decision (recorded per SPEC-SCOPE §6 item 4)

**Standing:** **PASS** (spec amended on disk; evidence receipts read, not assumed; docs-dod-check green)

Date: 2026-10-21
Lane: WRAP-1 (writer)
Repo: /Users/sac/smalt · `docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md`

## Decision (now binding, evidence-cited)

The **14-op ABI ships on `graphlaw.wasm`**; frozen-duckdb stays **native-side**
through the op-15 `duckdb` cursor-streamed ABI op (landed natively by GWS-16).
The wasm module **excludes duckdb**; real-SQL-in-wasm is a **typed follow-up**
(BLOCKED on a wasm32 frozen-duckdb artifact). Smalt's runner shim (GWS-18)
serves the real 14-op artifact.

## Evidence base (re-read on disk this session)

- `receipts/gws2-wasm-build-trial.md`: frozen-duckdb-sys has **no wasm32
  artifact** in the cache and no wasm32 feature/stub path; the DOCS_RS
  workaround "produces" a 6,663,293 B binary whose **export-ABI hash
  `fb656ca6…` == the pinned 14-op artifact** — zero duckdb contribution to
  the wasm surface. In-wasm duckdb is structurally BLOCKED today.
- `/Users/sac/graphlaw/receipts/gws-16-wasm-duckdb-op15.md`
  (PARTIAL_ALIVE): op-15 landed NATIVE-side (coordinator override per GWS-1
  finding) — `src/duckdb_op.rs` behind the `duckdb` cargo feature, wasm op
  table unchanged at 14 ops, manifest `notes` field documents the
  native-only op, 5/5 `wasm_duckdb_op` court, byte-identity
  native-ABI ↔ native builtin, wasm32 build EXIT=0.
- `receipts/gws18-real-runner-court.md` (ALIVE): 7/7 real-runner court on
  the real pinned artifact (real parse admit, typed ABI refusal, raw ABI
  passthrough, 65 MiB wall, pin non-vacuity, crash containment `exit 86`,
  hung-runner fail-closed); this is the gate restoration previously typed
  PENDING-GWS-17 — no standalone GWS-17 receipt exists on disk in either
  repo (searched `/Users/sac/graphlaw/receipts`, smalt receipts, graphlaw
  docs).

## Diff

- `docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md` §6 item 4 — replaced the
  open-choice text ("the choice must be recorded here with a receipt") with
  the recorded decision + evidence receipt paths.
- `docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md` §3a gate table — added the
  **op-15 `duckdb` row** (native-side only, landed; in-wasm typed follow-up,
  never enters the wasm module by decision).
- Disclosure: while adding the op-15 row I also updated gate 3's
  "standing on real" cell from PENDING-ON-REAL-BINARY to
  DEMONSTRATED-ON-REAL-RUNNER — this is directly witnessed by GWS-18's court
  (gates 3/5: crash contained `exit_status 86`, bounded-poll heal, real
  frame admitted) and was left inconsistent otherwise (GWS-18's receipt is
  already cited in this spec's evidence set). Gates 1/2 real-binary cells
  were NOT touched (real-runner mode is config-optional; stub remains
  default; the wasmtime-ceiling leg of gate 2 remains unwitnessed).

## Command receipts

docs-dod-check (every receipt path named in docs must exist):

```
$ just docs-dod-check
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
EXIT=0
```
(63 OK lines total, 0 MISS — trimmed to the tail; full output in session log.)

Grep proof the decision text landed:

```
$ grep -n "RECORDED 2026-10-21" docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md
96:4. **14-op vs duckdb-op re-scope decision (RECORDED 2026-10-21)**
$ grep -n "NATIVE-SIDE ONLY" docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md
119:| op-15 `duckdb` (analytical SQL) | n/a — **NATIVE-SIDE ONLY**, landed (GWS-16, PARTIAL_ALIVE: ...
$ ls docs/jira/v26.10.21/receipts/wrap1-duckdb-rescope-decision.md \
     /Users/sac/graphlaw/receipts/gws-16-wasm-duckdb-op15.md
docs/jira/v26.10.21/receipts/wrap1-duckdb-rescope-decision.md
/Users/sac/graphlaw/receipts/gws-16-wasm-duckdb-op15.md
```

## Standing

PASS — the §6 item 4 obligation ("the choice must be recorded here with a
receipt") is discharged: decision recorded, evidence receipts named and
existing on disk, op-15 row in the §3a table. No court ran against a code
subject; nothing was flipped in the KD register; no GAP token was touched.

## Falsifier

Spec §6 item 4 reverting to open-choice text, or the §3a op-15 row citing a
receipt path that does not exist on disk (`just docs-dod-check` exits 1).

## Gate re-embed (BK-60, 2026-10-21)

Context: solo

NO-CONTEXT was a missing Context line (evidence already embedded: docs-dod-check
63 OK / EXIT=0, grep proofs). Fresh decision-landing re-check, 2026-10-21:

```
$ grep -n "RECORDED 2026-10-21" docs/jira/v26.10.21/WASM-SANDBOX-SPEC.md
101:4. **14-op vs duckdb-op re-scope decision (RECORDED 2026-10-21)**
re-check exit 0
```

The recorded decision line is on disk at spec line 101. Standing PASS unchanged.
