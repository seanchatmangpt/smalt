# Emulation Stance: 80/20, and the KD Register as the Honesty Mechanism

Understanding-oriented. This doc explains *why* smalt emulates only part
of Azure and *why* it advertises the parts it does not. The operating
law lives in the KD register; the code lives wherever the divergence
was taken.

## The stance

smalt is an emulator, not a re-implementation. The engineering bet is
an 80/20 split: the 20% of each service's surface that real SDKs and
CLIs actually exercise (the census classes: PUT/GET/DELETE/LIST,
patch-admission, etag CAS, LRO polling, AMQP disposition, batching)
gets fidelity; the long tail gets absence — typed, named, loud absence.
The census receipts (e.g.
`docs/jira/v26.10.16/receipts/08-servicebus-census.md`,
`docs/jira/v26.10.16/receipts/r101-census-rows.md`) are the instrument
that found the 20%: every SDK-census leg that came back green on the
emulator is a vote for "this cell is in the 20%"; every divergence
found by a real-SDK probe is a vote for the KD register instead.

## Why advertise absence instead of faking presence

A divergence silently faked is worse than a divergence honestly
registered, for three reasons:

1. **A fake pass poisons every downstream green.** A consumer that
   trusts a faked cell builds on nothing. A registered divergence is
   load-bearing information: the consumer re-routes, mocks at their
   edge, or pins around it.
2. **Absence must be addressable to be closable.** A KD row carries a
   surface, divergence, evidence receipt, and close condition. The
   close condition is executable: a shim landing in `lib/` carries
   `# KD-COVERS: KD-nn`, and `scripts/kd_flip.py --apply` flips the row
   only when a PASS witness receipt postdates the shim's mtime. No
   receipt, no flip — the honesty mechanism is mechanical, not
   aspirational.
3. **The census prose count can lag the table.** The KD table is ground
   truth, so the honesty is single-sourced. (`docs/reference/kd-register.md`)

The 80/20 model shows up in concrete product decisions, each receipted:

- Cosmos throughput admits the integer-request-unit class, and the
  float-typed request-unit wire form is registered as an 80/20
  simplification, not an unseen bug
  (`docs/jira/v26.10.16/receipts/cap-cosmos-throughput.md`).
- Blob immutability/CAS parity is surfaced as a probe-verified cell,
  not an assumed one
  (`docs/jira/v26.10.16/receipts/r153-immutability-cas-parity.md`).
- api-version parity was probed, not assumed
  (`docs/jira/v26.10.16/receipts/r163-probe-apiversion-parity.md`).

## The wire-compat pinions are the stance fossilized

Some divergences went the other way: what looked like a bug was
actually pinned by a real-SDK census and became a pinion. SASL
ANONYMOUS only, sasl-outcome descriptor 0x44, attach top-level ≤14 with
locale fields omitted, .NET-GUID lock-token byte reordering, EH fixed
partitions `["0","1"]` — each was pinned by a real handshake, and each
was flagged as a cleanup candidate at least once. The stance explains
why the cleanup is refused: the census that pinned them is the
authority, and changing them regresses real handshakes. (Register:
`docs/WIRE_PARITY.md`; pinions in the repo CLAUDE.md Conventions.)

## See Also

- `docs/jira/v26.10.16/KNOWN_DIVERGENCES.md` — the register of truth
- `docs/reference/kd-register.md` — KD register + flip protocol
- `docs/WIRE_PARITY.md` — GAP tokens (open gaps named by token, closed
  only by receipt)
- `docs/explanation/two-tier-enclave.md` — the same 80/20 logic applied
  to the terraform story (native primary, wire opt-in)
