# v26.11.6 — Final per-repo receipts (wave finale, lane 17)

Standing: PARTIAL_ALIVE — authored 2026-11-04 at wave finale. smalt is
receipted below and in the wave docs; the peer repos' wave work is
in-tree and uncommitted in each repo's working tree (their own
coordinators own those git transitions; this lane holds no write
authority outside smalt).

## ggen-marketplace (kafka-wire-pack, L73)

- Subject: `/Users/sac/ggen-marketplace` (canonical checkout).
- Landed in-tree, uncommitted: `packs/kafka-wire-pack/` (new pack:
  ontology.ttl, pack.toml, gate-court.toml, gates/, templates/,
  witnesses/, qualification/) plus aoq-pack additions (partition/cursor/
  wrap gates + pass/fail witnesses), smalt-substrate-pack ontology
  rider, qualification/baseline.json, and the msct/kudzu verifier
  riders.
- Receipt: none found in the repo (no `docs/jira/v26.11.6/`); the L15
  kafka-wire-pack receipt named by the charter does not exist on disk —
  registered as receipt-pending; baseline/active-list changes
  (marketplace.active.toml, qualification/baseline.json) are in-tree.
- Falsifier shape: pack renders a face smalt's `wire.ex` does not serve
  → pack refuses or is retired; qualification baseline is the gate.
- Open item: a landing coordinator with ggen-marketplace write
  authority runs the pack qualification gate, then commits with the
  same quiescence+gates law.

## cgap (L3/L13/L7-surface)

- Subject: /Users/sac/cgap (canonical checkout).
- Landed in-tree, uncommitted: cgap-aoq crate changes (chain, kem,
  session, pin_table, verify, writer, error, lib) + tests (ab8_sweep,
  af30_cage_match, alloc_density_census, aoq1_codec_court,
  cbmqs_gates/runner, chain_bench/courts, corridor_join_court,
  macro_* tests) + Cargo.lock + .ggen/freeze blake3 rows.
- PQC commit order (registered, not executed — no cgap write authority
  in this lane): clippy → L56 → v3-courts → KEM → KATs.
- Export-#[no_mangle] KD candidate: minted in smalt as KD-192 (smalt
  `docs/jira/v26.11.6/KNOWN_DIVERGENCES.md`); cgap-side mint pending a
  cgap lane.
- Open item: Seal-flag gitpack-0x08 (KD-195) — cgap ticket tracked
  cgap-side; arcus L14 receipt is the evidence pointer.

## arcus (L72 / L14)

- Subject: `/Users/sac/arcus` (canonical checkout).
- Landed in-tree, uncommitted: `internal/messaging/` (hand-law codec:
  errors/crc/header/records/batch/encode/encode_batch + golden hex
  fixtures + CRC bit-flip falsifier + KD-180/KD-174 faces),
  `internal/ingress/{auth,aws,gcp,kafka}/`, `internal/egress/kafka/`,
  `internal/ringbuf/cabi.go`, `scripts/courts/` (aws msk/sqs, gcp
  pubsub, kinesis py courts + anti_vacuity_falsifier.sh), adapter
  (aoq_ipc.go + test), flight ops, main.go, ggen.lock, ontologies.
- Receipt: `/Users/sac/arcus/docs/jira/v26.11.5/receipts/l14-kafka-adapter.md`
  (PARTIAL_ALIVE; in-tree, uncommitted).
- Open item: Seal-flag gitpack-0x08 — S14 seed registered in smalt
  `../v26.11.5/strata-backlog.md`; cgap ticket closure flips it.
- Open item: Seal-flag gitpack-0x08 — S14 seed registered in smalt
  `../v26.11.5/strata-backlog.md`; cgap ticket closure flips it.

## Landing law (all repos)

Every commit sequence is quiescence-gated, explicit paths, `-F <file>`,
no rebase/force-push, push + `git ls-remote` verify with bounded retry
×3. smalt is the only repo this lane lands; peer-repo work stays
in-tree for their coordinators.
