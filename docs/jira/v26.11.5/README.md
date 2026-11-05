# v26.11.5 — AoQ Milestone Index

Milestone pointer file for the AoQ-on-BEAM program (smalt QUIC plane) in
`docs/jira/v26.11.5/`.

## Charter

Land the AoQ plane as a NEW BEAM plane in smalt (not a posh retrofit), on the
TLS-twin additive-listener dispatch pattern: a pinned-port Bandit listener
feeding a fixed worker pool over a framed wire protocol, with zero-copy Rust
NIF resource binaries behind a fail-closed boundary and a staged transport
decision (gen_udp + iovec framing in phase 1, Rust QUIC via quinn in the NIF
boundary in phase 2). Spec-first milestone: the three landed artifacts are
design records grounded in real code (cgap `wire-shm` ring, `cgap-beam`
resource ABI, smalt `lib/smalt/posh` census); implementation lanes follow.

## Landed artifacts

| Lane | Artifact | Commit | Standing |
|---|---|---|---|
| LANE-01 | `aq-architecture-spec.md` | `6034afac` | LANDED (spec; fixes `48a4faf8`, `25dd40df`) |
| LANE-02 | `aq-nif-boundary-spec.md` | `fa2e15f1` | LANDED (spec) |
| LANE-03 | `aq-quic-transport-decision.md` | `e8019de2` | LANDED (spec; DECIDED) |

Lane leases: `docs/jira/v26.11.5/_LANES.md`.

## Open items (spec'd, not yet implemented)

- **AoQ listener wiring** — `Smalt.Aoq.Supervisor` / `Smalt.Aoq.Listener` /
  worker pool per `aq-architecture-spec.md` §1 are not mounted in
  `lib/smalt/plane/data_supervisor.ex`; only a partial untracked
  `lib/smalt/aoq/` (flags, frame, scheduler) exists on disk, unlanded.
- **NIF implementation** — per `aq-nif-boundary-spec.md`: the zero-copy
  resource-binary NIF families (wire-shm ring view, NifHolder refcount
  discipline) are spec-only; no AoQ NIF ships in smalt or cgap yet.
- **QUIC phase-2** — per `aq-quic-transport-decision.md`: phase 1 is
  gen_udp + iovec framing; the Rust `quinn` QUIC state machine inside the
  LANE-02 NIF boundary is the deferred phase-2 target. Not started.
