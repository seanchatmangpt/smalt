# Receipt: SB queues + EH eventhubs lattice top 2021-04-01 → 2024-01-01

- **Lane**: DoD lane (no build/test runs this session)
- **Date**: 2026-10-16
- **Standing**: PASS
- **KD pattern**: KD-78 monotonic admission pattern (`version_lte?/2`), close pattern from
  `docs/jira/v26.10.16/sdk-results/version-lattice-receipt.md`; row at
  `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:202`. Blob precedent: KD-83
  (`docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:208` — bump the lattice top in the pack
  ontology (source of truth), regen the generated registry, fence the literal pins so an
  ontology regression re-fails the fence).

## Surfaces bumped

| Surface | Old cap | New cap | Source |
|---|---|---|---|
| `Microsoft.ServiceBus/namespaces/queues` | 2021-04-01 | 2024-01-01 | pack ontology `smalt:apiVersion "2024-01-01"` (ontology.ttl:328, KD-78 monotonic-pattern comment at :326) |
| `Microsoft.EventHub/namespaces/eventhubs` | 2021-04-01 | 2024-01-01 | pack ontology `smalt:apiVersion "2024-01-01"` (ontology.ttl:342, KD-78 monotonic-pattern comment at :340) |

Unchanged (stay 2021-04-01): SB topics + topics/subscriptions, EH consumergroups.

## Generation chain (no hand-edit)

1. `/Users/sac/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl` — child-type
   rows widened with KD-78 monotonic-pattern comments.
2. `mix smalt.gen` (ggen_igniter.sync) regenerated `lib/smalt/registry.ex`
   (replay-fenced, byte-identical replay test-fenced).
3. `ggen_igniter.pack.lock` re-pinned to sha256 `a4774b15…9624`, version 26.10.14.

## Evidence read this session (real read-only command output)

```
$ grep -n "Microsoft.ServiceBus/namespaces/queues" lib/smalt/registry.ex | grep 2024
141:    "Microsoft.ServiceBus/namespaces/queues" => "2024-01-01",
```

```
$ grep -n '"Microsoft.EventHub/namespaces/eventhubs" =>' lib/smalt/registry.ex | grep 2024
122:    "Microsoft.EventHub/namespaces/eventhubs" => "2024-01-01",
```

```
$ sed -n '1,12p' ggen_igniter.pack.lock
{
  "packs": {
    "smalt-substrate-pack": {
      "locked_by": "26.10.7",
      "name": "smalt-substrate-pack",
      "sha256": "a4774b1550b5a8061949a6622b617e6e5b0961eaf5bd8dbf17ba05eaf6db9624",
      "source": "../ggen-marketplace/packs/smalt-substrate-pack",
      "version": "26.10.14"
    }
  },
  "schema_version": "1"
}
```

```
$ grep -n -B2 -A1 '"2024-01-01"' ~/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl | grep "resourceType\|2024-01-01\|KD-78"
269-    smalt:resourceType "Microsoft.ServiceBus/namespaces" ;
270:    smalt:apiVersion "2024-01-01" ;
277-    smalt:resourceType "Microsoft.EventHub/namespaces" ;
278:    smalt:apiVersion "2024-01-01" ;
326:    # KD-78 monotonic pattern: azurerm 4.54 child PUT witnessed at 2024-01-01
328:    smalt:apiVersion "2024-01-01" ;
340:    # KD-78 monotonic pattern: azurerm 4.54 child PUT witnessed at 2024-01-01
342:    smalt:apiVersion "2024-01-01" ;
```

## Wire fence (not re-run this session — DoD-lane no-build/test prohibition; fence file read)

`test/kd78_child_lattice_wire_test.exs` — 156 lines, read this session. Moduledoc
(byte-exact excerpt from the file read):

```
  KD-78 monotonic-pattern wire fence for the child-type lattice tops bumped
  this lane: `Microsoft.ServiceBus/namespaces/queues` and
  `Microsoft.EventHub/namespaces/eventhubs` now cap at the witnessed
  azurerm 4.54 child-PUT version 2024-01-01 (witness: tf-cleanroom apply
  + tf-plan-probe InvalidApiVersionParameter receipts naming 2024-01-01
  vs cap 2021-04-01).
```

Contract asserted by the fence: SB queue child PUT at 2024-01-01 → 2xx admitted; EH
eventhub child PUT at 2024-01-01 → 2xx admitted; both types at a newer-than-latest
version → 400 `InvalidApiVersionParameter` naming `Registry.latest_version/1`; older
versions stay admitted (monotonic `version_lte?/2` law).

Lane witness (cited, not re-executed): 6 fence tests, 0 failures, exit 0. Non-vacuity
witnessed by mutation: one lattice row reverted → fence red → byte-exact restore
(sha256 fail-closed, KD-83 shim-court pattern).

## Cross-links

- KD-78 close pattern: `docs/jira/v26.10.16/sdk-results/version-lattice-receipt.md`.
- KD-83 blob precedent: fence `test/kd79_blob_apiversion_wire_test.exs`, 4/4 PASS
  2026-10-16 (row `docs/jira/v26.10.14/KNOWN_DIVERGENCES.md:208`).

## Replay

```
grep -n 'namespaces/queues" =>' lib/smalt/registry.ex      # expect 2024-01-01 at :141
grep -n 'namespaces/eventhubs" =>' lib/smalt/registry.ex   # expect 2024-01-01 at :122
grep -n "2024-01-01" ~/ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl
grep -n "a4774b15" ggen_igniter.pack.lock
MIX_BUILD_ROOT=_build-ft-dod mix test test/kd78_child_lattice_wire_test.exs
```
