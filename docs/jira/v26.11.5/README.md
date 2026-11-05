# v26.11.5 — AoQ Milestone Index

Milestone pointer file for the AoQ-on-BEAM program (smalt QUIC plane) in
`docs/jira/v26.11.5/`. Ledger refreshed 2026-11-04 by L58 from an on-disk
receipt census (`receipts/` read at use time, not from memory).

Standing: PARTIAL_ALIVE — 24 lane receipts landed; QUIC phase-2, p09 shm,
and KD-90 remain open.

## Charter

Land the AoQ plane as a NEW BEAM plane in smalt (not a posh retrofit), on the
TLS-twin additive-listener dispatch pattern: a pinned-port Bandit listener
feeding a fixed worker pool over a framed wire protocol, with zero-copy Rust
NIF resource binaries behind a fail-closed boundary and a staged transport
decision (gen_udp + iovec framing in phase 1, Rust QUIC via quinn in the NIF
boundary in phase 2).

## Landed artifacts

| Lane | Artifact | Commit | Standing |
|---|---|---|---|
| LANE-01 | `aq-architecture-spec.md` | `6034afac` | LANDED (spec; fixes `48a4faf8`, `25dd40df`) |
| LANE-02 | `aq-nif-boundary-spec.md` | `fa2e15f1` | LANDED (spec) |
| LANE-03 | `aq-quic-transport-decision.md` | `e8019de2` | LANDED (spec; DECIDED) |
| L17 | milestone docs index | `8419dd61`/`657f9c32` | LANDED (docs) |
| L58 | this ledger refresh | this commit | LANDED (docs) |

AoQ implementation wave (all receipts in `receipts/`, Standing read per file
on disk 2026-11-04):

| Lane | Artifact | Commit | Receipt Standing |
|---|---|---|---|
| L9 | VM flags surface (+sbt/+sbwt/+hms, fail-closed court) | `1c3ed427` | ALIVE |
| L11 | AoQ supervisor skeleton, NIF behaviour seam | `73eeeee2` | ALIVE |
| L12r | bin_opt gate + non-vacuity shim court | `91bc8f4e` | ALIVE |
| L13 | framing-law court + egress fence (64B RefcBinary) | `41f43a31` | ALIVE |
| L15 | Cursor atomics layout + receipt standing flip | `7a16215c` | ALIVE |
| L16 | KV7 BEAM-oracle live leg court (six ops) | `db2dd356` | ALIVE |
| L19 | slab-frame NIF surface 1 (cgap `dfd9ae4f`) | `5cedb493` | ALIVE |
| L23r | aq_slab_window NIF surface 2 (cgap-only) | cgap `57521ea6` | ALIVE |
| L24 | receipt-standing lint port (`scripts/receipt_standing_lint.py`) | `3dc479e0` | ALIVE |
| L28 | `:aoq` plane name admission (profile flips AoQ gate) | `bc2098b9` | PARTIAL_ALIVE |
| L29 | AOQ fences wired into full court chain | `3dc479e0` | PARTIAL_ALIVE |
| L32 | KD-178 broker-restart socket lifetime link | `824a55da` | PASS |
| L34 | KD-176 close token + entry-cap shim court | `890e895e` | PASS |
| L35 | KD-188 storage managementPolicies route (9/9) | `e0be5327` | PASS |
| L37 | KD-50 SB queue camelCase readback fence | `b11f18c4` | PASS |
| L38 | epoch-rotate handler for frame type 0x03 | `e00431c6` | PASS |
| L41 | bin-opt gate fix in frame.ex (context reuse) | `15ff8fe5` | PASS |
| L42 | KD-99 RS256+JWKS falsifier court | `db51f6ec` | PASS |
| L44 | KD-130 close — container re-create 409 | `ae38ee23` | PASS |
| L46 | first AoQ bench lane (listener→pool→worker) | `00bd0a47` | ALIVE |
| L47 | census fence — 7 internal-tier files registered | `a6e965ff` | PASS |
| L52 | bundle boot write via Tables.boot/1 | `a3c91d64` | PASS |
| L53 | substrate readiness poll, timeout as budget | `358fe84c` | PASS |
| L54 | KD-189 legal-hold PUT header-only | `00f3877d` | PASS |

## Cross-repo receipt index (fleet-wide)

Sibling repos' v26.11.5 receipts (read on disk 2026-11-04; commits cited from
each repo's own log):

**cgap** — `docs/jira/v26.11.5/receipts/` (7 receipts):

| Lane | Artifact | Commit | Standing |
|---|---|---|---|
| L14 | pqc_seal composite seal/open (ML-DSA-65 + AEAD) | `92fa5f0b` | PARTIAL_ALIVE |
| L21 | receipt-standing lint port + backfill | `8d15fcca` | PASS |
| L25 | pqc_seal mutation re-wave CLOSED (429-death residue) | `11f8640b` | PASS |
| L27 | KD-2 claims rows republished + ratio fence | `14bcc036` | PASS |
| L36 | mechanical rustfmt convergence, 90 files | `b3fae1f9` | PARTIAL |
| L40 | zero-warning clippy pass (4 crates) | `1a84bf66` | UNVERIFIED |
| w3r | RejBoundedPoly centered-rep fix — KATs green | `be78ae34` | PASS |

**arcus** — `docs/jira/v26.11.5/receipts/` (5 receipts):

| Lane | Artifact | Commit | Standing |
|---|---|---|---|
| L18 | alloc census over ZP-19 hot-path surfaces | `ec764b8` | PASS |
| L22 | receipt-standing-lint Gate 3 port | `eaec36e` | PASS |
| L30 | UDS transit probe hardening (load-contention) | `47f351e` | ALIVE |
| L33 | chachaSeal/Open alloc reductions (4→1 / 3→1) | `e47f79a` | PASS |
| L39 | wire-shm-exact 16B ringbuf framing SPSC | `147325a` | ALIVE |

## Open items

- **QUIC phase-2** — Rust `quinn` QUIC state machine inside the LANE-02 NIF
  boundary per `aq-quic-transport-decision.md`. Phase 1 (gen_udp + iovec
  framing) is landed and benched (L46); phase-2 remains not started.
- **p09 shm** — parked on the cgap 64B framing decision (operator call).
- **KD-90** — open; operator dependency call pending.
