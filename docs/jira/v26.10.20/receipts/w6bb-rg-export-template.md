# Receipt: w6bb — ARM Export Template face

**Standing:** ALIVE (module tier; wire mount deferred to the post-split integration window)
Context: solo
Date: 2026-10-20

## Surface

`lib/smalt/arm/export_template.ex` (NEW, exclusive lane surface) — ARM "Export
template" parity: `export_rg/3` enumerates a resource group's REAL resources
from `:smalt_resources` (resource-map rows only, registry-admitted types,
`skip_resource_types:` option) and emits the ARM template envelope
(`$schema`/`contentVersion`/`parameters`/`variables`/`resources`/`outputs`),
each entry carrying the registry api-version, stored location, and stored
properties **verbatim** (tags omitted when null/empty). 404 typed face
`ResourceGroupResourceNotFound` on an exportable-empty rg. Parameterization is
intentionally not performed (documented boundary: literal template).

## Witness (real output, replay:

`MIX_BUILD_ROOT=_build-lane-w6bb MIX_ENV=test mix run --no-start tmp/w6bb_witness.exs`)

```
L1_EXPORT_OK resources=3
L2_TYPES=["Microsoft.KeyVault/vaults", "Microsoft.Storage/storageAccounts"]
L3_SA_PROPS_VERBATIM=true
L4_SA_TAGS=true
L5_KV2_LOCATION echo exact
L6_APIVERSIONS=well-formed for all resources
L7_SCHEMA=true contentVersion=true
L8_SKIP_TYPES=1   (skip_resource_types drops the 2 vaults)
L9_ROUNDTRIP_VALIDATE_OK   (template through Deployments.validate_deployment → :valid)
L10_EMPTY_404=ResourceGroupResourceNotFound
W6BB WITNESS: DONE
```

All 10 legs PASS. The round-trip promise holds: export → validate = Succeeded.

## Compile

`_build-lane-w6bb` note: lane compile passed inside the witness runs on a
green shared-tree window (attempt 7 of the bounded poll;
rotating sibling churn before that: `sas.ex`, `key_vault_actions.ex`
mid-authoring). Zero diagnostics in `export_template.ex`.

## Compile-freeze unblock disclosures (SLA, other lanes' files)

- `lib/smalt/data_plane/key_vault_actions.ex:1940` — restored a corruption-ate
  `case` form on `Store.get(:smalt_vault_keys, {name, version})` (unclosed
  delimiter + `:error ->` jammed on the same line). A subsequent owner rewrite
  superseded this fix mid-lane; final on-disk form is the owner's.
- My own helper draft (kw_wrap RFC-3394) was also superseded by the owner's
  rewrite — I stood down per the SLA (owner was actively rewriting; my edit
  collided and was refused cleanly by the file-state gate).

## Falsifier

Green under a broken enumerator would be vacuous: L8 proves the skip option
filters (1 of 3 resources with the two vault types skipped); L9 proves the
emitted template validates through the real Deployments.validate_deployment.
Re-running the witness on a mutated enumerator that emits 0 resources would
flip L8/L10 red.

## Cleanup

`_build-lane-w6bb` and `tmp/w6bb_witness.exs` left for coordinator lane-clean.
No git operations.
