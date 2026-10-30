# 27 Invariant Gate Design: SPARQL Invariant Gate for the POSH Pack

Status: PARTIAL — design grounded on live execution this session (rdflib 7.6.0,
zero new dependencies to install). No file outside `gaps/27` was modified.
Every executable claim below was run, not inferred.

## Reality vs charter

Charter: INVARIANT gate = SPARQL over ingress/egress graphs. Reality
(`/Users/sac/smalt/justfile.d/58-posh.just:97-103`, fifth guard of the
`posh-generate` recipe): a `grep -h 'a posh:IngressRoute'` count over
ontology + instance files. That guard counts *existence of individuals*, not
*invariant conformance*: an orphan route (no `posh:admittedBy`) still
increments the count, so the gate passes on a graph that violates the orphan
invariant. The turnstile-receipt invariant is not checked at all.

The pack already ships both must-be-empty queries:

- `/Users/sac/smalt/ggen-marketplace/packs/posh/queries/invariant_orphan_route.rq`
- `/Users/sac/smalt/ggen-marketplace/packs/posh/queries/invariant_turnstile_receipt.rq`

## Options

### (a) rdflib/Python SPARQL runner — RECOMMENDED

Grounding receipt (run this session): `python3 -c 'import rdflib'` succeeds,
rdflib 7.6.0. Both `.rq` files parse and execute against
`examples/posh_instance.ttl`:

- `invariant_orphan_route.rq` → 0 rows (clean)
- `invariant_turnstile_receipt.rq` → 0 rows (clean)

Non-vacuity mutation (run this session): injecting one orphan individual
(`posh:routeOrphanInjected a posh:IngressRoute` with no `posh:admittedBy`)
into the in-memory graph flips the orphan query from 0 → 1 row naming the
injected route. The court can flip, therefore it is not vacuous.

Pros: queries already exist as SPARQL (the charter's own artifact form); the
runner is ~15 lines of Python with a dep that is already installed; the same
runner generalizes to any future `queries/invariant_*.rq` (glob, not
per-query code). Cons: a Python dep at generate time (rdflib is not vendored
by smalt; it is present on this machine).

### (b) Elixir in-graph SPARQL

Rejected on cost: smalt carries no SPARQL client dep (`mix.exs` has
`spark`, `ash`, `finch` — no `sparql`/`grisp` RDF stack). Adding `sparql.ex`
+ `rdf.ex` pulls a graph/exo-syntax stack into smalt's dependency tree solely
to run two queries at generate time. This is local reinvention of what rdflib
already does, in a repo whose compile-freeze SLA makes new deps expensive
([[same-checkout-fanout]] addition 2).

### (c) Keep grep, count the right thing

Rejected as the end state: grep cannot express `FILTER NOT EXISTS` — the
invariant is a negative structural condition over two triples
(`?route posh:admittedBy ?t` absence), which no line-count approximates.
The closest honest grep proxy (count routes, count `admittedBy` triples,
assert equal) still misses the turnstile-receipt query and any future
join-shaped invariant. Option (c) is at best a stopgap; (a) is cheaper than
maintaining the proxy logic.

## Specification of the recommended mechanism

### Runner

`scripts/posh_invariant_gate.py` (new, ~30 lines) in smalt:

```python
#!/usr/bin/env python3
"""POSH invariant gate: every queries/invariant_*.rq MUST be empty.
Exit 0 = clean, exit 1 = invariant violation, exit 2 = infra failure."""
import glob, os, sys
import rdflib

PACK = os.environ.get("SMALT_POSH_PACK", "ggen-marketplace/packs/posh")
GRAPH_FILES = ["ontology/posh.ttl", "examples/posh_instance.ttl"]

try:
    g = rdflib.Graph()
    for f in GRAPH_FILES:
        g.parse(os.path.join(PACK, f), format="turtle")
except Exception as e:
    print(f"[INVARIANT-GATE-FAIL] cannot parse graph: {e}", file=sys.stderr)
    sys.exit(2)

queries = sorted(glob.glob(os.path.join(PACK, "queries", "invariant_*.rq")))
if not queries:
    print("[INVARIANT-GATE-FAIL] no queries/invariant_*.rq found — vacuous gate", file=sys.stderr)
    sys.exit(2)

failed = False
for q in queries:
    rows = list(g.query(open(q).read()))
    if rows:
        failed = True
        for r in rows:
            print(f"[INVARIANT-VIOLATION] {os.path.basename(q)}: {r}", file=sys.stderr)
if failed:
    sys.exit(1)
print(f"[INVARIANT-GATE] {len(queries)} queries, 0 rows — clean")
```

### Graph source

`ontology/posh.ttl` + `examples/posh_instance.ttl` merged into one rdflib
Graph — the same two files the existing grep guard already reads, and the
same merged T-box+A-box that `ggen sync run` renders from (pack manifest
`[ontology] imports`). No new source of truth.

### When it runs

**Both, cheaply:**

1. **`posh-generate` stage** — replace the grep block (lines 97-103) with one
   call: `python3 scripts/posh_invariant_gate.py || exit 1`, positioned after
   the pack-manifest/ggen.toml presence guards and before `ggen sync run`
   (bad graphs must never render). The existing individual-count grep can
   stay or be folded in; it answers a different question (vacuity of the
   A-box) and remains correct for that question.
2. **`posh-court` stage** — add as a named stage (e.g. stage 0, before vet)
   so the 7-stage ladder re-proves invariants on whatever graph is on disk
   at court time, independent of generate.

CI inherits both automatically via the existing workflow that runs the
ladder; no separate CI wiring needed.

### Exit contract

| exit | meaning | gate behavior |
|---|---|---|
| 0 | all `invariant_*.rq` returned 0 rows | proceed to `ggen sync run` |
| 1 | ≥1 row in any query — typed violation lines on stderr naming query + row | fail `posh-generate` / fail court stage |
| 2 | infra failure: graph unparseable, or zero `invariant_*.rq` found (loud vacuity — a gate that reads no queries carries no bits) | fail, never skip silently |

Loud-skip discipline preserved: unlike the manifest guards (which exit 3 =
SKIP because the pack is not landed), a landed pack with a bad graph exits 1
= FAIL, not SKIP.

### Non-vacuity mutation (standing requirement)

The mutation must flip the gate **through the full runner**, not just the
query. Standing court (add as `just posh-invariant-court`):

1. Copy `examples/posh_instance.ttl` to a temp file; append
   `posh:routeOrphanInjected a posh:IngressRoute .` (orphan by construction —
   no `posh:admittedBy`).
2. Run the runner with `SMALT_POSH_PACK` pointing at a temp pack dir whose
   `examples/posh_instance.ttl` is the mutated copy. Expect exit 1 and
   stderr naming `invariant_orphan_route.rq` + the injected route.
3. Restore-verify: the original on-disk instance file's sha256 is unchanged
   (mutation happens on a copy, never in place — shim-court protocol,
   [[testing-chicago-style]]).

Receipt this session (query-level, in-memory equivalent of step 2): mutated
graph yields exactly 1 row
`https://smalt.dev/posh/ns#routeOrphanInjected`; unmutated yields 0. The
falsifier is proven flip-able; a court that cannot flip is FAIL.

## Status

- Design: ALIVE (this document).
- Runner script: NOT IMPLEMENTED (specified above; ~30 lines, no new deps).
- Queries: ALIVE (both execute clean under rdflib 7.6.0, receipts above).
- Non-vacuity: PROVEN at query level this session; runner-level court
  (`posh-invariant-court`) specified, not implemented.

See Also: `gaps/24-cross-repo-skew.md` · smalt `justfile.d/58-posh.just`
