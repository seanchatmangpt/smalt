# v26.11.5 Lane Ledger

AoQ-on-BEAM spec wave (2026-11-04). Spec-first milestone: three docs lanes
landed; implementation lanes (listener, NIF, QUIC phase-2) not yet dispatched.
Ownership is single-owner-per-file.

## Lanes

| Lane | Face | Files (disjoint) | Standing |
|---|---|---|---|
| LANE-01 | architecture spec | `aq-architecture-spec.md` | LANDED (`6034afac`, fixes `48a4faf8`/`25dd40df`) |
| LANE-02 | NIF boundary spec | `aq-nif-boundary-spec.md` | LANDED (`fa2e15f1`) |
| LANE-03 | QUIC decision record | `aq-quic-transport-decision.md` | LANDED (`e8019de2`) |
| L17 | milestone docs index | `README.md`, `_LANES.md` | LANDED (this commit) |

## Unclaimed faces (spec'd, no lane dispatched yet)

- AoQ listener wiring: `Smalt.Aoq.Supervisor`/`Listener`/worker pool mount in
  `lib/smalt/plane/data_supervisor.ex` per `aq-architecture-spec.md` §1. An
  untracked in-flight `lib/smalt/aoq/` (flags.ex, frame.ex, scheduler.ex) exists
  on disk — unlanded, unclaimed here.
- NIF implementation per `aq-nif-boundary-spec.md` (smalt NifHolder + cgap-side
  zero-copy resource binary families).
- QUIC phase-2 (Rust `quinn` inside the LANE-02 NIF boundary) per
  `aq-quic-transport-decision.md`.

## Shared seams

None yet — this wave was docs-only, one file per lane.
