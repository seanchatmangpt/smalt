# Lane 2 — EH checkpoint + AoQ cursor durable restart (v26.11.6)

Standing: PARTIAL — receipt body partially lost in-session (lane-internal
editing fault during a Standing-line relocation, 2026-11-05); only the
fragments quoted verbatim below survive. The PASS evidence body (court
output, replay receipts, owned-file proofs) is unrecoverable from this
lane and must be re-verified or re-authored by the coordinator before
any KD-190 flip cites this file.

Date: 2026-11-05. Repos: smalt (canonical) + ggen-marketplace (pack ontology).
No git transitions performed (wave law: coordinator owns git).

## Subject (owned files, all landed)

* `ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl` — `st-smalt_eh_checkpoints`
  `smalt:persisted false -> true` (line 688).
* `lib/smalt/store_tables.ex` — REGENERATED via the ggen_igniter
  render pipeline (Ontology.load! -> Graphlaw -> build_bindings -> Render +
  `mix format`; the `mix smalt.gen` stanza equivalent). `:smalt_eh_checkpoints`
  joins `persisted_tables/0` (8 persisted, was 7) and specs row

<!-- LOST: original lines 16-119 (~104 lines: remaining owned-file bullets,
     court commands/exits, replay identity, shim-court legs) -->

## Handoff to coordinator (KD-190 flip)

All three standing lines satisfied: court PASS (2/2), flip-back PROVEN
(RC=0, mutation carries through regen->compile->boot), replay-identity
byte-exact. Per L60-L: `kd_flip.py --apply` applied from the v26.10.14
canonical register — after --apply, hand-sync the v26.11.6 wave-register
row. This receipt postdates the landed shim files.
