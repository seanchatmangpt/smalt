# how to add a config key

There is exactly one lawful path. `lib/smalt/config.ex` is a generated
projection — hand-editing it is destroyed on the next regen, and the census
is a closed set fenced by a test.

By the end you will have: added the key to the ontology, regenerated all
six projected artifacts, and updated the census pin with a real diff.

## What you need

- The smalt repo; the sibling pack checkout
  `../ggen-marketplace/packs/smalt-substrate-pack` (the ontology lives
  there, not in this repo).
- `mix smalt.gen` (root justfile `gen` recipe) requires the pack dir.

## The law in one paragraph

`Smalt.Config` is auto-projected from the smalt-substrate-pack ontology
`smalt:ConfigKey` closed census via `queries/config_keys.rq` through
`templates/config.ex.eex`. DO NOT HAND-EDIT; regenerate with `mix smalt.gen`.
Replay identity is fenced by `test/config_replay_identity_test.exs`, which
pins the census CLOSED at 56 keys with coverage and bijection gates — the
ontology default is the ONLY copy of the in-code default going forward.

## Step 1: add the key to the ontology

In
`../ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl`, add a
`smalt:ConfigKey` individual: name (atom), type, default, secret flag,
surface, `env_var` (`SMALT_*` env var name, or nil), and override class
(the accessor must mirror its call sites' override semantics exactly).

## Step 2: regenerate

```bash
just gen        # mix smalt.gen
```

The task runs six stanzas (`lib/mix/tasks/smalt.gen.ex`): registry,
event_registry, store_tables, cascade_edges, config.ex, and the semconv
registry (own pack). Each stanza is a forced `Mix.Task.rerun` (an alias
invoking `ggen_igniter.sync` twice only executes the first — witnessed), and
each render is `mix format`ed. `lib/smalt/config.ex` now contains your
accessor.

## Step 3: update the census pin

`test/config_replay_identity_test.exs` pins census CLOSED at 56. A new key
makes the live census 57 — the gate FAILS, and that is the point: the pin
moves only with the ontology diff, never silently. Update the pin in the
same change (the test comment says: "census pin updated with the ticket, not
silently drifted").

## Step 4: override semantics

Match the generated accessor's override semantics to its call sites
(ontology `smalt:override` class). Runtime env overrides (`SMALT_*` env
vars) are resolved at runtime-config time via `config/runtime.exs`; the
ontology's `env_var` field names that var. Plane selection
(`SMALT_PLANES`) is the worked example — see
`docs/tutorials/planes-profiles.md`.

## Step 5: verify

```bash
mix test test/config_replay_identity_test.exs
```

Passes only with ontology, projection, and pin in agreement.

## See Also

- `lib/smalt/config.ex` (generated projection, header law)
- `lib/mix/tasks/smalt.gen.ex` (six-stanza regen)
- `test/config_replay_identity_test.exs` (census pin + bijection gate)
- `docs/explanation/ggen-projection-law.md` (projection rationale)
- `docs/tutorials/planes-profiles.md` (worked key: `SMALT_PLANES`)
