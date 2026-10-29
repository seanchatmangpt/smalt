# BK-113 — RDF-star GAP-1a probe: purrdf lowering self-stability + RDF.ex interop

**Standing:** PARTIAL_ALIVE (measured; probe-only, no fixes implemented, no lib/ changes)
Context: solo
Date: 2026-10-21
Subject: /Users/sac/smalt @ main (uncommitted worktree) + /Users/sac/graphlaw @ main (read-only, untouched)
W3C-A carried GAP-1a: purrdf 2.0.2's canonical N-Quads lowers RDF 1.2 triple terms
(`<< s p o >>`) to a reifies blank node with the private predicate
`<urn:purrdf:rdfc:reifies>`. This probe measures (a) self-stability of the lowering,
(b) interop of the canonical form with a standard parser.

## Verdict (sharply typed)

**Self-stable + hash-deterministic: YES (measured). Interop: REFUSED (measured),
with a split surface.**

- The blake3 digest path is deterministic within purrdf's identity universe: the
  canonical N-Quads is a fixed point of (parse → canonicalize). No hash-path defect.
- A standard-adjacent parser refuses the canonical serialization on the N-Quads
  surface specifically. GAP-1a is an **interop gap**, not a hash-path defect.
- New sub-finding: RDF.ex 3.0.1 supports triple terms in **Turtle but NOT in its
  N-Quads decoder** — a split-surface divergence inside RDF.ex itself, now part of
  the GAP-1a close condition.

## Probe 1 — purrdf self-stability (lower → re-parse → same canonical form?)

Cargo probe at `/tmp/w3ca2/probe-rs` (purrdf "=2.0.2" from crates.io, the exact
pinned engine; blake3 crate for digesting). Input:

```turtle
@prefix ex: <http://ex/> .
ex:alice ex:says << ex:bob ex:age 40 >> .
```

Actual transcript:

```
=== ROUND 1 canonical N-Quads ===
<http://ex/alice> <http://ex/says> _:c14n0 .
_:c14n0 <urn:purrdf:rdfc:reifies> <<( <http://ex/bob> <http://ex/age> "40"^^<http://www.w3.org/2001/XMLSchema#integer> )>> .
---
blake3: e1309fc9732a6242ff128375ad57a17e1b7be7fd4a80a6a7344442d257b15466
=== ROUND 2 canonical N-Quads ===
<http://ex/alice> <http://ex/says> _:c14n0 .
_:c14n0 <urn:purrdf:rdfc:reifies> <<( <http://ex/bob> <http://ex/age> "40"^^<http://www.w3.org/2001/XMLSchema#integer> )>> .
---
blake3: e1309fc9732a6242ff128375ad57a17e1b7be7fd4a80a6a7344442d257b15466
SELF-STABLE (nquads identical): true
HASH-DETERMINISTIC (blake3 equal): true
R3 fixed point: true
wrote /tmp/w3ca2/round1-canonical.nq
```

Verbatim transcript; the program asserts equality programmatically (self-stable,
hash-deterministic, fixed point at round 3). Canonical digest:
`e1309fc9732a6242ff128375ad57a17e1b7be7fd4a80a6a7344442d257b15466`.

Round 3 confirms the canonical form is a **fixed point** (canonicalize(canonical)
= canonical, byte-identical, third time).

## Probe 2 — RDF.ex 3.0.1 interop witness

Environment: smalt deps, `MIX_BUILD_ROOT=_build-w3ca2` (deleted after run;
`rm -rf` was permission-denied — **residual: `/Users/sac/smalt/_build-w3ca2` may
still exist and needs lane-clean**), Elixir 1.20.4-otp-29 via asdf shim
(`~/.asdf/shims/mix`; homebrew elixir 1.19.5 shadows asdf in PATH — disclosure).

Input: `/tmp/w3ca2/round1-canonical.nq` (purrdf's round-1 canonical output, exact bytes).

```
INTEROP-REFUSE: "N-Quad scanner error on line 2: {:illegal, ~c\"(\"}"
```

RDF.ex's N-Quads decoder refuses the `<<( … )>>` triple-term production outright.

**Characterization probe (same content, Turtle surface):**

```
TURTLE-ACCEPT (triple term as object): [{~I<http://ex/alice>, ~I<http://ex/says>, {~I<http://ex/bob>, ~I<http://ex/age>, RDF.XSD.Integer.new(40)}}]
PLAIN-NQ-STYLE (no triple term): ACCEPT
```

Same triple-term content ACCEPTs in Turtle, REFUSEs in N-Quads. The gap is in the
RDF.ex N-Quads/N-Triples scanner's grammar, not in RDF.ex's triple-term data model
(the parsed term is a first-class triple term: `{s, p, o}` tuple).

## Disposition (per the task's typing rule)

Self-stable + hash-deterministic → re-type GAP-1a as **interop gap only**:

- **Row re-typed** in `docs/jira/v26.10.22/W3C-FORMALIZATION.md` row 1: "private
  serialization, deterministic hash path — interop gap".
- **Owner: upstream purrdf** — emit RDF 1.2 triple-term syntax end-to-end in
  canonical N-Quads (close condition unchanged from the census: canonical form
  round-trips through a standard RDF 1.2 parser; measured today as FAIL with the
  RDF.ex N-Quads REFUSE receipt above).
- **Second owner added: upstream RDF.ex** — implement the triple-term production
  in the N-Quads/N-Triples scanner (its Turtle decoder already accepts it, so the
  data model supports it; grammar gap only).
- **Not a hash-path defect**: the graphlaw blake3-over-canonical-N-Quads path is
  deterministic (fixed point proven) and unaffected by interop; the digest remains
  defined only inside purrdf's identity universe, severity unchanged on the hash
  leg.

## Probe artifacts

- `/tmp/w3ca2/probe-rs/` — cargo probe (purrdf =2.0.2 + blake3), `src/main.rs` holds
  the full lower→re-parse→canon→fixed-point logic; program asserts printed `true`
  for self-stable / hash-deterministic / R3 fixed point.
- `/tmp/w3ca2/round1-canonical.nq` — purrdf canonical bytes fed to RDF.ex.
- Probe-only lane; no lib/ changes, no commit, graphlaw untouched.
