# Architecture Memo: SOTA Local-First Sync vs. Sovereign Binary Lithography

Standing: OPERATOR-CHARTER (memo of record, 2026-10-21) — performance claims carry the
whitepaper number-law: figures cite repo receipts; unanchored claims are typed at the end.
Context: full · See also: [PRD.md](PRD.md) · [SYNC-CHARTER.md](SYNC-CHARTER.md) ·
[../v26.10.21/whitepaper/lithography.pdf](../v26.10.21/whitepaper/lithography.pdf)

## 1. Thesis

Contemporary local-first sync stacks (Replicache/Reflect, ElectricSQL, PowerSync, Convex,
bespoke CRDT engines) are probabilistic replication over ad-hoc schemas: dual-language
mutators, defensive middleware, serialization taxes, heuristic merges. The sovereign
alternative formalizes client/server coordination as deterministic state-space fabrication
across an airlock: the identical compiled WASM law reticle runs in both tiers; ingress is a
byte-0 formal sieve; conflicts resolve topologically (SESE-POWL join ω); the wire is naked
41-byte Packet-4 frames; every batch yields a constant-size Merkle receipt.

## 2. Comparative matrix (claims → anchors)

| Dimension | SOTA sync stacks | Sovereign lithography | Anchor (receipt/artifact) |
|---|---|---|---|
| Execution consistency | Dual-stack mutators (TS + Go/Rust), drift caught by contract tests | Single reticle: `gl_call` over the identical binary in browser worker + server WASM-1 pool | GWS-12 cross-engine byte-identity court; SYNC-2 node probe drove the pinned artifact |
| Ingress admission | Open-world strings + layered sanitization (WAF/Zod/ORM) | Closed-shape sieve at byte 0; ANDON non-mutating | ja5 fail-fast court (typed 400/413/412, zero store mutation); SYNC-2 op-1 ANDON probe |
| Conflict resolution | LWW (clock skew) / workflow-blind CRDTs | SESE-POWL join ω: commutative merges, mutually-exclusive ⇒ refusal leaf + client snap-back | fond runner court (strong-cyclic loopback, typed `fond_loop_bound_exhausted`); ω = **unbuilt** (FR-SNC-006, queued WO) |
| Wire protocol | JSON/protobuf serialization tax | Naked 41-byte Packet-4 frames, CRC32, direct journal append | SYNC-2 codec court 11/0 (landed); SYNC-1 receiver in flight; 5.0µs append claim = **UNANCHORED** (SJ-1 courts seal protocol structurally, not µs) |
| Storage horizon | Unified OLTP/OLAP or CDC pipelines | Bifurcated: actor `.wal` vs `.seal`-gated analytical mounts | SJ-1/SJ-2 courts; GWS-12; sqld8 450,450.5 rows/s measured |
| Provenance | Retrospective JSON logs + human affidavits | 48-word (384 B) O(1) self-authenticating Merkle receipts (pplan seal term, post-GAP-6a; was 40-word/320 B pre-GAP-6a); the separate sync wire receipt stays fixed 320 B | pb4r: measured O(1) at n=10..10^5 (48 words); GAP-6a agent chain = bk129rr (PASS); reconciliation = bkrsize-receipt-truth; `<0.2ms verify` claim = **UNANCHORED** (seal ladder 0.048–2399.5 ms, PB4-R re-run) |

## 3. Deep-dive deltas (summary; full operator text is the memo of record)

1. **Zero-drift invariant** — one reticle, two tiers, byte-exact identical decisions
   (GWS-12). Divergence is structurally unrepresentable rather than test-caught.
2. **Byte-0 decidability** — closed SHACL shapes; refusal is the final product, sealed as a
   Merkle leaf; zero heap, zero transactions, zero seq advance on refuse.
3. **Topological joins** — commutative partial-order paths merge (⊗); mutually exclusive
   choices halt (⊕) with a refusal leaf and client snap-back to canonical head. LWW/CRDT
   failure classes (silent overwrites, illegal merged states) are unrepresentable.
4. **Zero-serialization persistence** — client IndexedDB frame bytes ⇒ smaltFetch raw
   stream ⇒ CRC/seq verify ⇒ unmodified bytes into the journal sink. No JSON, no ORM,
   no re-allocation.
5. **Provenance on the write path** — RDFC-1.0 canonicalization + tree hash per batch;
   O(1) receipt; statutory self-authentication without custodian testimony.

## 4. Unanchored-claim ledger (per the number law)

| Claim in the memo | Status | Path to anchor |
|---|---|---|
| Operational commit ≤5.0µs / WAL append ≤5.0µs | UNANCHORED (structural courts only) | extend the SJ-1 bench with per-append wall-clock + reds at quiet load |
| Merkle verify <0.2ms | UNANCHORED (ladder shows 0.024ms @10 leaves — matches at small n only) | scope the claim to ≤10^3 leaves or bench the verify path at 10^5 |
| Local write p99 ≤10µs | Gate (SYNC-2) | browser-side measurement court, warmed per TTV-7 standard |
| Join ω semantics | UNBUILT | FR-SNC-006 WO (COURT-SYNC-ANDON) |

Everything else in the matrix is receipt-anchored via the linked courts.
