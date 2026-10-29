# KD-44 / KD-08 / KD-09 — live-wire re-probe witness (W12-A)

**Date**: 2026-10-20
**Standing**: PASS (all three hold on the live substrate)
**Context**: solo
**Subject**: live substrate pid 47090 (booted 2026-10-20, /tmp/smalt-substrate-state/substrate.pid;
an earlier boot pid 11444 was restarted mid-session by another lane — all witness legs below
were run against the post-restart boot and are internally consistent)
**Surface**: Cosmos data plane, plain HTTP loopback :8443 (egress twin), STS bearer auth
(token minted per batch from `POST http://127.0.0.1:9443/{tid}/oauth2/v2.0/token`,
scope `https://cosmos.azure.com/.default`). KV KD-15 handshake not applicable (cosmos bearer).
Probe db `w12awit28816` created and DELETEd (204) after the probe — no residue.
Probe tooling: raw curl against the live wire; no in-process harness.

## KD-44 — bulk per-op partition key (JSON-array header pinion respected)

Two SDK-shape bulk POSTs to `/dbs/:db/colls/:coll/docs` with
`x-ms-cosmos-is-batch-request: true`, per-op scalar `partitionKey`, NO request-level
`x-ms-documentdb-partitionkey` (the fix wraps the scalar into the single-element JSON array).

First leg (a1 not yet existing — solo seeds had been 400'd for a missing pk header at that
point, which is correct partition_check behavior, not a bulk defect):

```
HTTP 200
[(201, 'a1', 10), (201, 'a9', 9)]
```

Mixed-status leg after a1 existed (verbatim):

```
== KD-44 mixed: bulk upsert existing a1 + create a77 ==
HTTP 200
[(200, 'a1', 10), (201, 'a77', 77)]
```

Mixed 200/201, no pk-400. The probe db at the time held a1,a2,a3,a9.
Per-op scalar pk accepted without any 400 — the KD-44 header-shape fix is live.

## KD-08 — feed x-ms-max-item-count cap + continuation

Seed 4 docs (a1,a2,a3,a9) in fresh container `c1`; GET feed with `x-ms-max-item-count: 2`.

```
HTTP 200
x-ms-continuation: 2#4:dzEyYXdpdDI4ODE2L2Mx:a2
page1 count 2 ids ['a1', 'a2']
== resume with continuation '2#4:dzEyYXdpdDI4ODE2L2Mx:a2' ==
HTTP 200
(no continuation on last page)
page2 count 2 ids ['a3', 'a9']
```

Page of exactly 2 + continuation token; resume returns the disjoint remainder
(a3,a9 ∩ a1,a2 = ∅); no continuation header on the last page. KD-08 holds live.

## KD-09 — container list x-ms-max-item-count + continuation

4 containers (c1..c4) in the fresh db; GET `/dbs/:db/colls` with `x-ms-max-item-count: 2`.

```
HTTP 200
x-ms-continuation: g2gCYQNhAg
page1 2 ['c1', 'c2']
== resume ==
HTTP 200
(no continuation on last page)
page2 ['c3', 'c4']
```

Paged 2+2, continuation honored, pages disjoint. KD-09 holds live.

## Notes for the register (not flips — kd_flip owns those)

- Covers KD-44, KD-08, KD-09. Receipt postdates the lib/ shims
  (`lib/smalt/data_plane/cosmos.ex` KD-COVERS comments) — the flip gate (receipt mtime >
  shim mtime) is satisfiable from this file.
- Mid-session substrate restart observed (pid 11444 → 47090, another lane's transition);
  all witness legs ran against the final boot. One 401 mid-probe from a short-lived STS
  token was re-minted, not a substrate failure.
- KD-36 note (out of scope, no defect): bulk "Upsert" on a non-existent id returns 201
  (create leg), matching Azure semantics; existing-id upsert returns 200 via the replace
  path — both witnessed above.
