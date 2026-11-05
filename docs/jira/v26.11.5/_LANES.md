# v26.11.5 Lane Ledger

AoQ-on-BEAM wave (2026-11-04). Spec lanes landed first (LANE-01/02/03), then
the implementation wave (L9–L54) landed across smalt, cgap, and arcus.
Ownership is single-owner-per-file. Ledger refreshed 2026-11-04 by L58 from
an on-disk receipt census; every SHA verified in the owning repo's git log.

## Lanes — smalt

| Lane | Face | Commit | Standing |
|---|---|---|---|
| LANE-01 | architecture spec | `6034afac` | LANDED |
| LANE-02 | NIF boundary spec | `fa2e15f1` | LANDED |
| LANE-03 | QUIC decision record | `e8019de2` | LANDED |
| L9 | VM flags surface + fail-closed court | `1c3ed427` | ALIVE |
| L11 | AoQ supervisor skeleton, NIF seam | `73eeeee2` | ALIVE |
| L12r | bin_opt gate + non-vacuity shim court | `91bc8f4e` | ALIVE |
| L13 | framing-law court + egress fence | `41f43a31` | ALIVE |
| L15 | Cursor atomics layout + standing flip | `7a16215c` | ALIVE |
| L16 | KV7 BEAM-oracle live leg court | `db2dd356` | ALIVE |
| L17 | milestone docs index | `8419dd61`/`657f9c32` | LANDED |
| L19 | slab-frame NIF surface 1 | `5cedb493` | ALIVE |
| L23r | aq_slab_window NIF surface 2 | cgap `57521ea6` | ALIVE |
| L24 | receipt-standing lint port | `3dc479e0` (batched w/ L29) | ALIVE |
| L28 | `:aoq` plane name admission | `bc2098b9` | PARTIAL_ALIVE |
| L29 | AOQ fences into full court chain | `3dc479e0` | PARTIAL_ALIVE |
| L32 | KD-178 broker-restart socket link | `824a55da` | PASS |
| L34 | KD-176 close token + entry-cap shim | `890e895e` | PASS |
| L35 | KD-188 managementPolicies route | `e0be5327` | PASS |
| L37 | KD-50 SB queue camelCase fence | `b11f18c4` | PASS |
| L38 | epoch-rotate frame 0x03 handler | `e00431c6` | PASS |
| L41 | bin-opt gate fix (frame.ex) | `15ff8fe5` | PASS |
| L42 | KD-99 RS256+JWKS falsifier court | `db51f6ec` | PASS |
| L44 | KD-130 container re-create 409 close | `ae38ee23` | PASS |
| L46 | first AoQ bench lane | `00bd0a47` | ALIVE |
| L47 | census fence, 7 files registered | `a6e965ff` | PASS |
| L52 | bundle boot write via Tables.boot/1 | `a3c91d64` | PASS |
| L53 | substrate readiness poll budget | `358fe84c` | PASS |
| L54 | KD-189 legal-hold PUT header-only | `00f3877d` | PASS |
| L59 | paired kafka-vs-aoq court + C7 alloc repair + KD-197 | no git (v26.11.6 wave) | PARTIAL_ALIVE |

## Lanes — cgap (read-only census)

Receipts: cgap `docs/jira/v26.11.5/receipts/`.

| Lane | Face | Commit | Standing |
|---|---|---|---|
| L14 | pqc_seal composite seal/open | `92fa5f0b` | PARTIAL_ALIVE |
| L21 | receipt-standing lint port | `8d15fcca` | PASS |
| L25 | pqc_seal mutation re-wave CLOSED | `11f8640b` | PASS |
| L27 | KD-2 claims rows republished | `14bcc036` | PASS |
| L36 | rustfmt convergence, 90 files | `b3fae1f9` | PARTIAL |
| L40 | zero-warning clippy pass | `1a84bf66` | UNVERIFIED |
| w3r | RejBoundedPoly fix, KATs green | `be78ae34` | PASS |

## Lanes — arcus (read-only census)

Receipts: arcus `docs/jira/v26.11.5/receipts/`.

| Lane | Face | Commit | Standing |
|---|---|---|---|
| L18 | alloc census (ZP-19 hot paths) | `ec764b8` | PASS |
| L22 | receipt-standing-lint port | `eaec36e` | PASS |
| L30 | UDS transit probe hardening | `47f351e` | ALIVE |
| L33 | chacha alloc reductions | `e47f79a` | PASS |
| L39 | 16B ringbuf framing SPSC | `147325a` | ALIVE |

## Open faces

- QUIC phase-2 (Rust `quinn` inside the LANE-02 NIF boundary) per
  `aq-quic-transport-decision.md` — not started.
- p09 shm — parked on the cgap 64B framing decision (operator call).
- KD-90 — operator dependency call pending.

## Shared seams

None currently claimed; lanes own disjoint files. L19/L23r straddle smalt and
cgap (cgap crates/cgap-beam NIF + smalt receipt), disclosed in both lanes'
receipts.
