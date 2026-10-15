# Pack Integration Receipt — semantic-manufacture-epoch-pack → smalt

- **Date**: 2026-10-15
- **Packs**: `ggen-marketplace/packs/semantic-manufacture-epoch-pack` (ontology:
  `sm:Epoch`/`sm:Projection`, graph-vs-projection digest identity), with epoch
  concepts from `semantic-projection-pack` and `experience-projection-pack`
  ontologies consulted for projection-identity vocabulary.
- **Subject**: `~/smalt` @ uncommitted working tree (no git, shared
  checkout, lane-scoped files only).
- **Gate**: `mix test test/semantic_epoch_test.exs` — 5 tests, 0 failures.

## What was built

Epoch-aware semantic projection: smalt's real manufacturing state projected as
an epoch timeline.

| Module | Reads | Meaning |
|---|---|---|
| `Smalt.Projection.SemanticEpoch.timeline/1` | `.ggen_igniter/receipts/*.jsonl`, `ggen_igniter.pack.lock`, `tmp/ocel/deviations.jsonl` | one row per receipt: what was manufactured, when, from which pack digest, drift status |

Timeline shape:

    %{
      epochs: [%{id, started_at, finished_at, standing, operation, pack_name,
                 pack_digest, lock_digest, drift_status, drift, recipe_key,
                 receipt_hash}],
      pack_lock: %{pack_name => locked sha256},
      deviations: [admitted OCEL deviation records],
      deviation_count: n
    }

## Drift status law

Compared against the pack lock (the admitted digest authority):

- `:standing_drift` — receipt standing is not `alive` (e.g. `build_broken`);
  takes precedence, recorded even when the row carries no pack.
- `:no_pack` — no pack attribution on the receipt.
- `:digest_drift` — receipt `pack_digest` differs from the lock's `sha256`
  for the same pack.
- `:ok` — standing `alive` and digest matches the lock.

On the live tree this surfaces a real drift row: the one `alive`
smalt-substrate-pack receipt carries `pack_digest 3f7d1f3a…` against lock
`70a135be…` → `:digest_drift`.

## Pack concept mapping (adapted, disclosed)

- `sm:Epoch` → one receipt row (one admitted manufacture act).
- `sm:graphDigest` vs `sm:projectionDigest` identity → `lock_digest` (locked
  canonical truth) vs `pack_digest` (what was actually manufactured); drift is
  the disagreement between them.
- `GgenIgniter.EpochWatermark` law (identity stamped at an epoch, re-stamp
  over a changed tree is drift) → the lock is the stamp; a receipt digest
  disagreeing with the stamp is marked, never rewritten.

## Generated vs hand-adapted (disclosed)

- **Hand-adapted** (no templates in the epoch pack — it is ontology+gates
  only, SELECT/CONSTRUCT authority, nothing to render via `ggen_igniter sync`
  into consumer code): the whole module. The pack declares `sm:Epoch`,
  digest properties and witnesses; the Elixir projection over smalt's real
  receipt/lock/deviation files is consumer-local residue.
- Deviations are read through the real `Smalt.Ocel.DeviationAdmission.read_all/1`
  — no re-implementation.

## Timeline guarantee

`timeline/1` sorts ascending by `{started_at, id}` (`DateTime.compare` then
id tiebreak) — a total deterministic order; repeated calls over an unchanged
tree return identical timelines (asserted in tests).

## Falsifier

A test seeding a byte-copy of the real ledgers asserts count, ordering,
uniqueness, drift marking against the real lock digest, and real
deviation admission — any change to the receipt schema, lock shape, or
drift law fails `mix test test/semantic_epoch_test.exs`.
