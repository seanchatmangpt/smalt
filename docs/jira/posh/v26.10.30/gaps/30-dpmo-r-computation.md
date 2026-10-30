# 30 DPMO R Computation: One Mechanically-Derived Route Count

Status: PARTIAL — the R definition, runner, and non-vacuity court executed this
session (receipt on disk); the single-source wiring into `posh-generate` /
`posh-court` / any DPMO tally is PROPOSED, not landed (lane owns this one file;
58-posh.just is another lane's surface).

## Subjects

- Pack: `/Users/sac/smalt/ggen-marketplace/packs/posh` (HEAD 31c58e9 is the
  consumer repo; smalt working tree as of 2026-10-30)
- Merge set: `ggen.toml [ontology] source = ontology/posh.ttl` +
  `imports = ["ontology/routes.ttl", "examples/posh_instance.ttl"]`
  (ggen.toml:11-14)
- Charter: `/Users/sac/smalt/docs/jira/posh/v26.10.30/dfcharter/dpmo.md` §1.1

## The three counts that exist today (re-read from disk this session)

| Count | Value | Source |
|---|---|---|
| grep-guard "R" | 3 | `justfile.d/58-posh.just:97-99` |
| coverage cells | 19 | `scripts/posh_coverage.py:18-41` |
| **R (the ONE definition)** | **16** | SPARQL COUNT, receipt `tmp/posh/r-receipt.json` |

- grep guard: `grep -h 'a posh:IngressRoute'` over ontology/posh.ttl +
  examples/posh_instance.ttl piped to `wc -l`. Misses `routes.ttl` entirely
  (12 more IngressRoute) and counts no EgressRoute; it is a zero-check,
  not R.
- coverage cells: 12 EXPECTED_RESOURCES + 7 EXPECTED_DATA_SOURCES (lane
  brief said 20; disk says 19). Different population — provider surface
  inventory, never citable as R.
- R: the only mechanically-derived number of the three.

The lane brief's premise "posh_instance.ttl has 3 IngressRoute individuals, grep
guards approximate R" is itself the finding: the grep guard does not approximate
R, it undercounts by 5.3x (3 vs 16) because the pack's real merge set includes
`ontology/routes.ttl`.

## The ONE R definition

R = SPARQL COUNT(DISTINCT ?r) over
`{ ?r a posh:IngressRoute } UNION { ?r a posh:EgressRoute }`,
evaluated over the exact ggen merge set (ggen.toml [ontology] source +
imports) — the same graph ggen sync run projects from, so a route that exists
in the graph and a route that exists in the code are counted from the same
bytes.

Computation is class-based, not the charter's literal query: `dpmo.md` §1.1's
verbatim SPARQL (posh:Route + STRSTARTS "urn:posh:ingress:") returns **0** on
the real graph (witnessed this session: `charter_literal_query_result: 0` in
the receipt) — the pack types routes `posh:IngressRoute`/`posh:EgressRoute`
with `https://smalt.dev/posh/ns#` IRIs. This is a live instance of
gaps/19-vocabulary-drift.md; dpmo.md §1.1's query text needs the class-based
form (this note is the correction source; the charter edit itself is another
lane's surface).


## Receipt contract (no independent recomputation)

- Path: `/Users/sac/smalt/tmp/posh/r-receipt.json` (tmp/posh — the same scratch
  root posh-clean manages; durable copy belongs in
  `docs/jira/posh/v26.10.30/receipts/` at integration).
- Producer: the posh-generate rdflib runner (rdflib 7.6.0 — the only local
  toolchain that executes the pack's .rq files today; note: the lane brief's
  "G27 recommends" reference is UNRESOLVED — grep over
  `docs/jira/posh/**`, _LANES.md, RESOLUTIONS.md and the consumer repo's gaps/
  finds no G27; the runner is defined here operationally, by what ran).
- Schema: `definition`, `runner`, `sources` (the 3 ttl files),
  `import_basis`, `R`, `charter_literal_query_result`, both invariant row
  counts, `gate_status`, both mutation results, `non_vacuity`.
- Consumers read `R` from the receipt; any DPMO claim whose R differs from the
  latest receipt R is invalid (charter dpmo.md §1.1 law, now enforceable by
  diffing against the file instead of re-counting).

Wiring to land (PROPOSED, outside this lane's file ownership):
1. posh-generate: after the ggen sync step, run the rdflib runner and write
   r-receipt.json; fail closed if R is absent or 0 (replaces the grep
   zero-check, which stays only as a loud pre-check if desired).
2. posh-court pre-stage: read r-receipt.json, emit `[POSH-COURT] R=16` in the
   tally; refuse to proceed on missing/stale receipt.
3. Any DPMO tally: cite receipt R only.

## Formula instantiation — today vs charter example (honest scale)

DPMO = D_total / (U x O) x 1e6, O = 4 opportunities per route per run
(dpmo.md §1-2).

| Quantity | Today (R=16) | Charter example (R=120) |
|---|---|---|
| O per run | 64 | 480 |
| Qualification U=500 → opportunities | 32,000 | 240,000 |
| 1 defect → DPMO | 31.25 | 4.17 |
| D=0 → DPMO_95 (Poisson, 3.689e6/N) | 115.3 | 15.37 |
| Zero-defect runs needed for DPMO_95 ≤ 1.0 | 57,641 | 922,250* |

*charter §2.3's 3,689,000 opportunities ÷ 480; at today's R=16 the bar is
3,689,000/64 = 57,641 runs, or R growth. At toy scale the honest claim is:
**all DPMO figures are PLANNED** — nothing is attestable beyond "0 defects
observed in gate runs, DPMO_95 = 115.3 at R=16, U=500". R growth (routes.ttl
12 → more resources) and census-scale U are the only paths to a ≤ 1.00 DPMO
claim; neither exists today.

## Non-vacuity (executed this session, asserts fail-closed)

Scratch copies only; the repo tree was not mutated. Receipt field
`non_vacuity` in `/Users/sac/smalt/tmp/posh/r-receipt.json`.

- **Mutation A** — well-formed extra IngressRoute (own turnstile + receipt,
  reusing declared shape/sink) appended to a scratch instance copy:
  R 16 → 17, both invariant queries still empty, gate stays PASS.
  Proves R is a count: it moves with graph content and is not a threshold.
- **Mutation B** — true orphan route (IngressRoute, no `posh:admittedBy`)
  appended to a scratch instance copy: R 16 → 17 AND
  `invariant_orphan_route.rq` returns 1 row → gate FAIL. Proves the gate is
  real: an orphan cannot hide behind a changed R.

Together: adding a route individual must change R; PASS/FAIL is decided only
by the invariant queries. A court that observed R move while PASS held and
could not flip RED on the orphan is the vacuous outcome this pair rules out.

## Verification receipt

- `python3 /tmp/lane30/r_runner.py` → exit 0; all asserts green; receipt
  written to `/Users/sac/smalt/tmp/posh/r-receipt.json` (re-read post-write).
- Runner: rdflib 7.6.0. Sources: ontology/posh.ttl + ontology/routes.ttl +
  examples/posh_instance.ttl (the ggen.toml merge set).
- R = 16; charter literal query = 0; orphan invariant 0 rows; turnstile
  invariant 0 rows; gate PASS; mutationA R=17/PASS; mutationB R=17/FAIL
  (1 orphan row).
- Lane scratch (`lane30_scratch_a/b.ttl`) deleted post-run; repo trees
  untouched apart from this file.

## Standing

PARTIAL: R definition + computation + non-vacuity court ALIVE (executed,
receipt on disk); grep-guard replacement, court wiring, and charter §1.1
query-text correction are PROPOSED. The DPMO program itself is PLANNED at
R=16 — see the scale table.
