# Strata Charter Gap Backlog (v26.11.5)

Standing: PARTIAL — cited receipts verified where checkable; unverified
claims marked as-of-date; gaps registered as wave seeds, not claims.

Derived from the Strata working-backwards charter review (2026-11-04). The
charter is backlog, not status. Each row below is a registered wave seed,
admitted only after its falsifier runs on an exact subject.

## Verified this session (receipt pointers)

| Claim | Receipt | Standing |
|---|---|---|
| AoQ chain hot-path fold (`AoqChain::append` unification) | cgap `8ccb43d0` (+ ERRATA-2 `ff10da29`) | ALIVE (commit verified in cgap log) |
| Slab NIF surface (open/frame/window/stamp/lease/sync) | cgap `aq_slab.rs`, C8 receipt this wave | PARTIAL_ALIVE (16/16 lib tests; contract-court lease leg BLOCKED on owner-lane poll inversion) |
| chachaSeal 4→1 / chachaOpen 3→1 alloc reduction | arcus alloc(l33) `e47f79a` | ALIVE (commit form verified; per-op counts cited from commit message) |
| UDS transit probe hardening | arcus flight(l30) `47f351e` | ALIVE (commit form verified; 55,411 trips/sec cited number NOT pinned to a receipt — UNVERIFIED) |
| Framing law + header layout (AOQ1/CRC/typed refusals) | smalt C6 receipt (24/24 framing court) | PASS |
| Arrow substrate v1 (sealed registry + court ladder) | smalt C3 receipt (30/30) | PASS |
| Datagram face + send_batch | smalt C5 receipt (16/16) | ALIVE |
| bin_opt_info gate + non-vacuity court | smalt C1 receipt + `91bc8f4e` | PARTIAL_ALIVE (2 real worker.ex violations red — repair queued peer-side as L41) |

## Registered gaps (wave seeds — none admitted yet)

| # | Gap | Charter surface | Falsifier shape |
|---|---|---|---|
| S1 | Turnstile contract: refusal at exactly frame 4,097, `BUSY 0x4347A003` constants | unnamed in landed specs | court: 4096 passes, 4097 refuses with exact code; mutation flips |
| S2 | 0 payload B/op → measured receipt | spec-scoped only | C7 alloc bench (tprof call_memory + zero-GC fence) — lane in flight this wave |
| S3 | Membrane stratum (enif resource-binary routing, off-heap queues, 0 allocs/round-trip) | smalt NIF seam is Stub | binds to C8's landed aq_slab surface; `Smalt.Aoq.Nif.Beam` impl of the NifHolder behaviour |
| S4 | Wasm arena stratum | greenfield | define subject first: which runtime (wasmex is in-tree), which arena ops, falsifier = alloc delta vs Elixir baseline |
| S5 | arcus UDS soak 55,411 trips/sec | number unpinned | re-run the l30 probe with JSONL receipt emission (bench lanes write only their own result file) |
| S6 | ML-KEM-768 handshakes | greenfield | stdlib/rust CryptoPadding-free KEM leg + interop vector court |
| S7 | Statutory docket surface (ASC 450/SOX 404/EU AI Act/FRE 902) | greenfield | scope check first: is this an ontology/vocabulary lane (public-cloud-ontology precedent) or a feature claim? Decide before building |
| S8 | QUIC-as-system-bus | phase 2 per landed decision record | unchanged — quinn ≥0.11.15 in NIF boundary; not started |

## Chatman Equation rendering note

`ΔS_admitted + Φ_lease ≡ R_receipt mod Σ_PQC` is a stylization. The
machinery-mapped form is the FAQ's three-term gate: admitted state
(sealed registries, frame tables), live lease (cursor atomics ledger),
receipt (BLAKE3-chained receipts) — all three partially landed this wave
(C3/C6/C8). Press-release form stays out of governing docs.
