# POWL-3 — Smalt.POWL2.Projection (Defs 4.2/4.3/4.7/4.8)

Date: 2026-10-21. Lane: POWL-3 (writer). Repo: /Users/sac/smalt.
Context: pair (concurrent POWL wave; shared compile healed by sibling lanes).

## Files (owned, written this session)

- `lib/smalt/powl2/projection.ex` (new) — rewritten twice: once against the
  transient map-shaped net, then reconciled to `Smalt.PetriNet` (POWL-1) when
  it landed; wiped once by the wave rotation (~12:00) and rewritten against
  the re-landed PetriNet.
- `test/internal/powl2_projection_test.exs` (new) — 8 Chicago tests, real
  PetriNet collaborators, final-state assertions, no doubles.

## Command output (real)

    $ MIX_BUILD_ROOT=_build-powl3 mix test test/internal/powl2_projection_test.exs
    Running ExUnit with seed: 448291, max_cases: 32
    ........
    Finished in 0.08 seconds (0.00s async, 0.08s sync)
    8 tests, 0 failures

    $ MIX_BUILD_ROOT=_build-powl3 mix compile
    Generated smalt app

## Semantics (as implemented)

- project_mg/4: internal place x iff preset(x), postset(x) both nonempty
  subsets of M; boundary arcs rerouted {:place,x,t} -> {:place,ps,t},
  {:transition,t,x} -> {:transition,t,pe}; internal arcs kept; subnet
  source ps sink pe; entries/exits recorded.
- project_sm/4: project_mg + SESE gate (exactly 1 entry arc, 1 exit arc),
  typed refusal {:error, {:not_sese, {:entry_count|:exit_count, n}}}.
- normalize/3: tau source/sink inserted ONLY when ps carries incoming or
  pe carries outgoing arcs; strays re-pointed through {:tau,:source,ps} /
  {:tau,:sink,pe}; identity otherwise (test proves no-tau-when-unneeded).
- execution_order/2: order^+ = transitive closure (Warshall) of base pairs
  + overlap edges pe_i == ps_j.
- execution_flow/2: gamma edges {a,b} -> {pe_a, ps_b}; start -> start child's
  ps; end child's pe -> finish.

## Disclosures

- Compile-freeze SLA unblocks applied to sibling in-flight files: none —
  sibling files (reticle.ex, executor.ex, change_feed.ex, decomposition.ex)
  were mid-write but healed by their owners within minutes; I polled and
  re-ran rather than touching them.
- The whole POWL2 lib wave (incl. my projection.ex) was rotated out and
  re-landed at ~12:00; my file was rewritten reconciled to the re-landed
  PetriNet and the re-landed ChoiceGraph struct (dropped :id field).

## Standing

**Standing:** ALIVE (8/8 tests green on the current on-disk wave at 2026-10-21 12:13 PT,
MIX_BUILD_ROOT=_build-powl3). Falsifier: rerun
`MIX_BUILD_ROOT=_build-powl3 mix test test/internal/powl2_projection_test.exs`
— any failure invalidates.
