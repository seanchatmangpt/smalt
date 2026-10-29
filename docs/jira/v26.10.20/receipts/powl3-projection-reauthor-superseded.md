# PROJAUTH (lane re-author) — SUPERSEDED by original-lane re-landing

Date: 2026-10-21
Lane: PROJAUTH (writer), repo /Users/sac/smalt
**Standing:** SKIP-LOUD (N/A — no artifact landed by this lane; superseded by the original lane's re-landing)

## Outcome

Coordinator stop-and-check (mid-run): POWL-3's original lane re-landed
`lib/smalt/powl2/spec` — specifically `lib/smalt/powl2/projection.ex`
(8552 bytes, mtime 12:10) and updated
`test/internal/powl2_projection_test.exs`. Per instruction, this lane did
NOT overwrite.

## Verification (executed, not assumed)

- `MIX_BUILD_ROOT=_build-projauth mix test test/internal/powl2_projection_test.exs`
  → `8 tests, 0 failures` (12:20:46, seed 473859). Executed twice to first
  reach green: attempts 1–2 were compile-blocked in
  `lib/smalt/powl2/compiler.ex` (a SIBLING lane's in-flight re-author,
  mtime 12:18 — placeholder doc "Compiles a duplicated @type declaration
  later", undefined `Pclauses`); attempt 3 ran green after that lane's
  fix landed. Compile-freeze duration observed: ~2.5 min, self-resolved
  by the owning lane — no cross-lane fix applied.
- Independent pre-check before the stop-and-check: read the re-landed
  projection.ex against the parent spec (Defs 4.2/4.3/4.7/4.8) and the
  test file. Semantics confirmed: `project_mg/4` internal-place rule
  (preset/postset both nonempty and ⊆ members, else ps/pe rerouting,
  entries/exits accumulated from rerouted arcs), `project_sm/4` typed
  SESE refusal `{:error, {:not_sese, {:entry_count|:exit_count, n}}}`,
  `normalize/3` tau insertion gated on delimiter strays
  (`{:tau, :source, ps}` / `{:tau, :sink, pe}`, identity when none),
  `execution_order/2` order^+ Warshall closure over pe→ps overlap plus
  base order, `execution_flow/2` gamma-edge projection to {pe(a), ps(b)}
  with start/finish mapped to start-ps / end-pe.

## Collision disclosure

This lane began re-authoring after a git-clean wave; while reading
references (12:03–12:10), another writer landed projection.ex (12:10) and
the test update. This lane wrote NO source files: zero writes to
lib/ or test/. Only artifact: this receipt.

## Files

- lib/smalt/powl2/projection.ex — OWNER: POWL-3 original lane (not this lane)
- test/internal/powl2_projection_test.exs — OWNER: POWL-3 original lane
- docs/jira/v26.10.20/receipts/powl3-projection-reauthor-superseded.md — this receipt
