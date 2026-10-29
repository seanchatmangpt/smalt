# BK-XPRI — v26.10.21 → v26.10.22 cross-milestone court re-run

**Standing: PARTIAL_ALIVE** — 12 v26.10.21 ALIVE-class cells re-courted fresh on the
current tree; 11 GREEN, 1 deterministic RED (HIGH regression finding, typed below),
1 flake disclosed (non-reproducing, green 2/3). Cross-milestone "strengthened" claim is
therefore **not** unqualified: the sql-ingest wire 400-face regressed inside the
v26.10.22 window.

Context: solo · Date: 2026-10-22 · Repo: /Users/sac/smalt
Lane: BK-XPRI (read-only cross-check; only this receipt written; private build root
`_build-lane-xpri` deleted at lane close).

## Method

Enumerated v26.10.21's terminal-gate surfaces from the v8 board
(`docs/jira/v26.10.21/VALIDATION.md`, 45-cell census) and picked the 12
highest-load-bearing ALIVE cells that own a court file on disk. Re-ran each court fresh
with `MIX_BUILD_ROOT=_build-lane-xpri mix test <court>` (peer court run distributed per
its documented invocation). Only the receipt below was written; no `lib/` or `test/`
edits.

## Per-cell results (real output, current tree)

| # | Cell (v26.10.21 board) | Court file | Result |
|---|---|---|---|
| 1 | AR-CORE-IDOM (ARMFIX idiom fixes) | `test/internal/armstrong_idiom_court_test.exs` | 8/8, 7/8, 8/8 over 3 runs — **flake disclosed** (below) |
| 2 | AR-CORE-01 (ProcessIter adoption) | `test/internal/process_iterator_court.exs` | 1/1 GREEN (0.4 s) |
| 3 | AR-WIRE-01 (JSONSAX) | `test/internal/bk3_jsonsax_court_test.exs` | 14/14 GREEN (0.3 s) |
| 4 | AR-POWL-03 (GraphCompat) | `test/internal/powl2_graph_compat_court.exs` | 8/8 GREEN (0.1 s) |
| 5 | AR-OBS-04 (peer two-node) | `elixir --name court127@127.0.0.1 --cookie smalt_peer_court -S mix test test/integration/peer_two_node_court.exs` | **4/4 GREEN, exit 0** distributed |
| 6 | AR-DATA-01 (BK-CELLS ARD CAS gate) | `test/internal/bkcells_ard_cas_gate_test.exs` | 1/1 GREEN |
| 7 | AR-DATA-04 (resize probe re-witness) | `test/internal/bkcells_data04_resize_probe_test.exs` | 1/1 GREEN |
| 8 | AR-OBS-02 (label adoption) | `test/internal/impl6_process_label_test.exs` | 6/6 GREEN |
| 9 | GLD-3 sql-ingest wire face | `test/internal/sql_ingest_wire_court.exs` | **2/3 — deterministic RED (2/2 runs)** |
| 10 | GLD-2 CDC court | `test/integration/gld2_cdc_court.exs` | PASS exit 0 (145 events / 115 rows, all legs ok + typed PENDING journal) |
| 11 | PRD-APIM (BK-CELLS witness) | `test/integration/apim_wire_test.exs` | 6/6 GREEN |
| 12 | PRD-KV crypto face | `test/integration/kv_crypto_face_test.exs` | 4/4 GREEN |

Unaffected-tier spot evidence: peer court non-distributed run shows 0 tests / 4 invalid
with a loud SKIP banner — the documented loud-skip contract still holds.

## RED finding — HIGH: sql-ingest malformed-JSON face 500s (was typed 400)

- **Surface**: `POST /sql-ingest` malformed-JSON leg of the GLD-3 400-face
  (`test/internal/sql_ingest_wire_court.exs:145`, body `'{"format": '` with
  `content-type: application/json`). Asserts 400; **measured 500 on 2/2 fresh runs**
  (identical failure: `assert s1 == 400; left: 500, right: 400`).
- **Was green at v26.10.21 wrap**: `receipts/gld3-sql-ingest-wire-face.md` records
  "Result: 3 passed" — this is a regression, not premise rot.
- **Mechanism (read from the current tree)**: `lib/smalt/egress_router.ex:50`
  `use Plug.ErrorHandler` + the **BK-EGS1 / EXPL9-R2 crash-path fence**
  (`handle_errors/2` at `lib/smalt/egress_router.ex:3964`): any unhandled pipeline
  exception — including `Plug.Parsers.ParseError`, which carries `plug_status: 400` —
  now has a **500 XML InternalServerError envelope SENT inside the handler**
  (`send_resp(500, …)` / `fegs1_fallback_send/2`) before Bandit can render the
  exception's typed 400. The fence was built to convert naked adapter 500s into
  Storage-shaped 500s; it does not exempt plug-status-400-class exceptions, so it
  swallows the parsers' typed 400 face. (`docs/jira/v26.10.22/receipts/bkegskep-fence-audit.md`
  is the owning receipt; its falsifier surface is the crash-path face, not the
  parsers-400 face — the fence strengthened one face and regressed another.)
- **Diff-range suspicion**: the BK-EGS1/EXPL9-R2 fence landing inside the v26.10.22
  window (present in the checkpoint 7a84b484 tree; `git log -p` shows 37 commits
  touching `lib/smalt/egress_router.ex` since 2026-10-21, incl. the w6R-split
  delegator refactor). The fence commit is the only window change that edits the
  crash-path render path this face rides on. Typed **HIGH** per the task rubric: a
  v26.10.21 ALIVE cell whose court now REDs.
- **Suggested close condition**: exempt `Plug.Parsers.ParseError` (or all
  `Plug.Exception` exceptions with `plug_status/1 < 500`) from the
  handle_errors 500-render in `lib/smalt/egress_router.ex` so Bandit renders the
  typed 400; re-run `mix test test/internal/sql_ingest_wire_court.exs` → 3/3. Owner:
  the EXPL9-R2 / BK-EGS lane.

## Flake disclosure (not a regression)

AR-CORE-IDOM's atom-count fence leg ("verify over hostile entries mints zero atoms")
failed 1/3 runs with `atom table grew: 40369 -> 40397` — the fence counts the VM-global
atom table while other async tests in the same beam mint atoms concurrently. Green 8/8
on the other 2 runs (the original ARMFIX receipt also disclosed a non-reproducing
flake on this court). Not typed as regression; a same-beam-async isolation fix (or
`async: false` on that leg) would de-flake it. Owner: ARMFIX/idiom court owner.

## Cross-milestone standing

- v26.10.21's terminal gates are **strengthened on 11/12 re-courted cells** (real fresh
  output above, current tree).
- The "strengthened" claim is **REGRESSED on 1/12** (HIGH): the BK-EGS1 crash-path
  fence turned the sql-ingest parsers-400 face into a 500. This also implies any other
  delegator face relying on plug-status-400 exceptions (same pipeline) is suspect.
- Board standing stays **PARTIAL_ALIVE** (both boards): the cross-check found a real
  regression the witness-all lane (BK-WIT2) had classified under its NO-STANDING/RED
  residue without naming this mechanism.

## Receipt / replay

```
export PATH="$HOME/.asdf/shims:$PATH"; cd /Users/sac/smalt
export MIX_BUILD_ROOT=_build-lane-xpri
for f in test/internal/armstrong_idiom_court_test.exs \
         test/internal/process_iterator_court.exs \
         test/internal/bk3_jsonsax_court_test.exs \
         test/internal/powl2_graph_compat_court.exs \
         test/internal/bkcells_ard_cas_gate_test.exs \
         test/internal/bkcells_data04_resize_probe_test.exs \
         test/internal/impl6_process_label_test.exs \
         test/internal/sql_ingest_wire_court.exs \
         test/integration/gld2_cdc_court.exs \
         test/integration/apim_wire_test.exs \
         test/integration/kv_crypto_face_test.exs; do
  mix test "$f"
done
elixir --name court127@127.0.0.1 --cookie smalt_peer_court -S mix test \
  test/integration/peer_two_node_court.exs
```

Expected replay: rows 1–8, 10–12 GREEN; row 9 RED 2/3 (the HIGH finding); armstrong
flake may or may not reproduce (2/3 green observed).
