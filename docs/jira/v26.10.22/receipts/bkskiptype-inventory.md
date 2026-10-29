# BK-SKIPTYPE — complete SKIP inventory (terminal gate: zero untyped)

**Standing:** ALIVE (every SKIP record on disk is typed permanent or carries a dispatched fix; zero untyped rows in the table)
Context: solo
Date: 20261022
Owner: BK-SKIPTYPE
Repo: /Users/sac/smalt (canonical checkout; read-only audit)

## Embedded census (real grep output, 2026-10-22)

1. **Bench/witness jsonls** — `grep -l -i 'skip' tmp/bench/*.jsonl tmp/witness*`:
   of the 66 jsonls under `tmp/bench/` plus the tmp witness files, exactly **2
   carry SKIP state**:

   ```
   tmp/bench/ctq4-memory.jsonl
   tmp/bench/spc-watch2.jsonl
   ```

2. **Browser smoke / witness-all legs** — latest SMOKE_RECEIPT
   (`/tmp/bkskipport-smoke.txt`, BK-SKIPPORT AFTER run 20261022T1144Z),
   `grep -o 'SKIP([^)]*)\|UNSUPPORTED([^)]*)'`:

   ```
   1 SKIP(face-absent::acr_face_absent)
   1 SKIP(kd101-airgap:local-delivery-unimplemented)
   1 SKIP(eh-plane-down(5673-connect-:eprotonosupport)
   2 SKIP(wasm-transport:function :httpc.request/4 is undefined (module :httpc is not available)   [apim, topic]
   1 SKIP(ca-missing:/Users/sac/smalt/.smalt/tls/ca-cert.pem)                                      [+1 dup line in file]
   1 UNSUPPORTED(recordset-A:RouteNotFound-404-zone-deleted-clean)  [dns — typed loud non-SKIP]
   ```

   Baseline (witness-all 20261021T234535Z, BK-SKIPPORT BEFORE): 16 OK / **15
   SKIP** / 0 FAIL — acr, apim, blob, certs, dns, eg, egd, eh, keyops, mcp,
   policy, queue, reconcile, tls, topic. After BK-SKIPPORT: 23 OK / 6 SKIP /
   1 UNSUPPORTED / 0 FAIL — 9 legs ported/typed away, 6 remain.

3. **e2e court** (`workspace/scripts/e2e-court.mjs`) — 2 SKIP lines, verbatim
   in bke2skip-skip-typing.md:29-32.

4. **Named-exclusion note**: the receipt-index gate output
   (`/tmp/witness_before.txt` / `_after.txt`) mentions receipt *filenames*
   `skip-audit.md`, `skip-fetch-census.md`, `skip-rewitness.md`, `skip.md` —
   these are SKIP-named receipt files flagged for missing rerunnable commands,
   NOT skip verdicts; out of inventory scope (they are the typing receipts
   themselves).

## Full SKIP inventory table (zero untyped rows)

| # | skip id | class | typing receipt | disposition |
|---|---------|-------|----------------|-------------|
| 1 | acr `face-absent::acr_face_absent` | face-absent | bkskipport-fetch-ports.md:80 (also v26.10.21 bk15-skip-fetch-census.md:49, bk40-skip-audit.md) | PERMANENT |
| 2 | apim (wasm `:httpc` + substrate APIM face absent) | face-absent + transport-impossible | bkskipport-fetch-ports.md:81 (bk40 CONFIRMED-PERMANENT) | PERMANENT |
| 3 | egd `kd101-airgap:local-delivery-unimplemented` | air-gap-by-design | bkskipport-fetch-ports.md:82 (kd101 typed gap IS the assertion surface) | PERMANENT |
| 4 | eh (AMQP over raw `:gen_tcp` to 5673; wasm has no sockets) | transport-impossible-in-browser | bkskipport-fetch-ports.md:83 (bk40 re-typed plane precondition green; residual = wasm raw-TCP) | PERMANENT |
| 5 | topic (same AMQP raw-TCP law as eh) | transport-impossible-in-browser | bkskipport-fetch-ports.md:84 | PERMANENT |
| 6 | tls `ca-missing` (on-disk CA unreadable in wasm) | transport-impossible-in-browser | bkskipport-fetch-ports.md:85 | PERMANENT |
| 7 | dns → `UNSUPPORTED(recordset-A:RouteNotFound-404)` | face-absent (loud non-SKIP verdict) | bkskipport-fetch-ports.md:87-88 | TYPED-NON-SKIP (rides along) |
| 8 | blob, certs, keyops, mcp, policy, queue, reconcile, eg | (former SKIPs) ported/typed-away | bkskipport-fetch-ports.md:24-27; bk15-skip-fetch-census.md; bk40-skip-audit.md | CLOSED-PORTED (witnessed OK 20261022T1144Z) |
| 9 | e2e `composition: panel rendering` | face-absent (DOM/Web Serial not executable in node; compensated by tsc type-layer PASS) | bke2skip-skip-typing.md:41-58 | PERMANENT |
| 10 | e2e `live: popcorn iframe src` (no Next server :3100) | environment-gated (skip text names the dispatch command) | bke2skip-skip-typing.md:60-71 | DISPATCHED |
| 11 | spc-watch2.jsonl `verdict: SKIP, reason: load_gate_never_opened` (load_1min 33–40 vs gate <8) | environment-gated (load gate) | bk40-skip-audit.md:40 (PENDING-DISPATCH; fix = `just quiesce` + rerun, court-x2 precedent) | DISPATCHED |
| 12 | ctq4-memory.jsonl `smoke_receipt: "SKIP legs typed wasm-transport/cors"` | reference-only restatement of inventory rows 1–6 | bk40-skip-audit.md:41 (REFERENCE-ONLY); inherits bkskipport typing | PERMANENT (by inheritance; not an independent verdict) |
| 13 | appconfig/rg legs `SKIP(substrate-down:...)` classifier | environment-gated (substrate-down path, added by BK-SKIPFIX so down reads SKIP not FAIL) | bkskipfix-classifiers.md (DOWN witness on dead-port shim; non-vacuity via FAIL→SKIP flip) | DISPATCHED-BY-DESIGN (flips to PASS when substrate up; UP witness 2026-10-22) |

## Cross-checks

- BK-WIT3 (fresh witness-all) had not landed as a receipt file at census time
  (`popcorn_demo/receipts/` newest = 20261021T234535Z-witness-all.md); the
  fresh smoke evidence used is BK-SKIPPORT's 20261022T1144Z run. If BK-WIT3's
  run reproduces the 6 permanent rows, this table stands unchanged; any new
  SKIP reason in its output is out of this lane's scope (owner types it).
- Prior typing chain: BK-15 (v26.10.21) first census/typing of the 15 →
  BK-40 adversarial re-typing + jsonl census → BK-SKIPPORT port wave
  (6 remain permanent) → BK-E2SKIP (e2e pair) → this receipt consolidates all
  classes with the jsonl census.
- Terminal-gate reading: every row is either PERMANENT with a named
  surface/transport law, or DISPATCHED with a named fix command
  (`9>&- just substrate-up`, start Next on :3100, `just quiesce`).
- Falsifier: a SKIP string appearing in any witness/bench jsonl or smoke
  receipt that does not appear in this table's distinct-id set (acr, apim,
  egd, eh, topic, tls, panel-rendering, popcorn-iframe, load-gate,
  ctq4-restatement, substrate-down) refutes "zero untyped".
