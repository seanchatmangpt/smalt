# 40 Invariant Gate Landing: SPARQL Invariant Gate Landed (lands G27)

Status: **ALIVE** — runner landed and executed this session; the court flips
and restores. Every claim below was run, output quoted.

Subject: `/Users/sac/smalt` (working tree, on main @ 31c58e9-class HEAD; note
the dispatch cwd was courtroom-platform-az — the G27 substrate is smalt, worked
there as disclosed).

## What landed

1. **Runner** `scripts/posh_invariant_gate.py` (~40 lines, rdflib 7.6.0, no
   new deps): globs `queries/invariant_*.rq` over the merged
   `ontology/posh.ttl` + `examples/posh_instance.ttl` graph. Exit contract:
   0 clean / 1 typed violation rows on stderr naming query + bound vars /
   2 infra (unparseable graph, or zero `invariant_*.rq` found — loud
   vacuity) / 3 loud skip when a graph file is missing (pack not landed).
   Exit 3 added beyond the G27 spec so the posh-court INVARIANT stage has a
   real SKIP path (the spec's skip branch was dead code otherwise).
2. **`posh-generate` guard replaced** (single disclosed block edit,
   `justfile.d/58-posh.just`): the `grep 'a posh:IngressRoute'` individual-count
   guard block is replaced by the runner call, positioned before
   `ggen sync run` — bad graphs never render. The old guard's KD-POSH-5
   zero-A-box loud-skip is covered downstream by ggen sync's render-rows>0
   non-vacuity check (exit 1), disclosed here.
3. **posh-court Stage 0 (INVARIANT)** added before Stage 1 vet; tally
   `$pass/8` -> `$pass/9`. Typed: exit 3 = SKIP (pack not landed),
   1/2 = FAIL. Note: the recipe header comment still says "7-stage ladder"
   and the stage labels run 0-8 (9 counted) — pre-existing label/count drift
   now slightly wider, flagged for the coordinator, not silently renumbered.
   Stages run uncounted kind/health/build/install pre-stages then counted
   stages 0-8.
4. **`just posh-invariant-court`** — shim-court on a temp copy of the pack
   (`cp -R`, trap cleanup): appends
   `posh:routeOrphanInjected a posh:IngressRoute .` to the copy's instance
   TTL, expects gate exit 1 naming `invariant_orphan_route.rq` +
   `routeOrphanInjected`, then sha256-verifies the on-disk instance
   byte-exact unchanged. Exit 0 PASS / 1 FAIL (incl. VACUOUS if the gate
   does not flip) / 3 loud skip.

## Verification ladder (all run this session)

| gate | command | result |
|---|---| |
| clean run | `python3 scripts/posh_invariant_gate.py` | `[INVARIANT-GATE] 2 queries, 0 rows — clean`, exit 0 |
| just parse | `just --evaluate` | exit 0 |
| court flip | `just posh-invariant-court` | `[POSH-INV-COURT] PASS gate flipped exit 1 naming invariant_orphan_route.rq / routeOrphanInjected; instance sha256 unchanged (fecd2086…644df)` |
| flip witness | mutated temp copy, gate rerun | `[INVARIANT-VIOLATION] invariant_orphan_route.rq: (URIRef('https://smalt.dev/posh/ns#routeOrphanInjected'),)`, exit 1 |

Restore proof: the court mutates only a temp copy; the on-disk
`examples/posh_instance.ttl` sha256 `fecd208604341a09c779ec571f1b47ea78fe1b7c42d70af307abcbcb5c0644df`
verified identical before/after.

## Standing

- Runner: ALIVE (executed this session, clean + flip receipts above).
- posh-court Stage 0: LANDED, not run end-to-end this session (the full
  ladder needs the kind cluster + Azure creds — pre-existing stage
  requirements, unchanged). Stage 0's exact recipe body is exercised via the
  same runner call proven above.
- Full posh-court 9-stage ladder: NOT RUN this session.

See Also: `27-invariant-gate-design.md` · `INDEX.md` ·
smalt `justfile.d/58-posh.just` · smalt `scripts/posh_invariant_gate.py`
