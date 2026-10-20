# C15 — Atlas v2 fidelity raise (purview_atlas.ex)

- Lane: ERRC RAISE, C15
- File ownership: `lib/smalt/data_plane/purview_atlas.ex` (exclusive)
- Standing: ALIVE
- Context: solo

## What landed

`Smalt.DataPlane.Purview` (lib/smalt/data_plane/purview_atlas.ex):

- Typedef/classDef registry (`TYPEDEF:`/`CLASSDEF:` keyspace in
  `:smalt_purview_entities`): `register_typedef/2`, `register_classdef/2`,
  `registered_type?/1`, `list_typedefs/0`; builtins
  `Referenceable Asset DataSet Process Deployment Database Table Column View smalt_table Unknown`.
- Type validation: unknown/missing `typeName` on create/bulk -> typed
  `400 ATLAS-400-CLASS` (real-Atlas face), atomic (whole-list validated before
  any `Store.put`).
- Classifications: `add_classifications/3`
  (POST /entity/guid/classifications shape — body is a LIST), `bulk_classification/2`
  (POST /entity/bulk/classification shape), classDef-validated, 404
  `ATLAS-404-00-005` on any missing guid with no partial attach.
- Process lineage: `Process` entities with `relationshipAttributes`
  input/output lists mint `Process.Input`/`Process.Output` edges at create,
  bulk create, and PUT-style update; `update_entities/2` implements
  PUT /entity/bulk merge semantics (patches may omit typeName — they inherit
  the stored type; carried typeName is validated).
- Honest UNSUPPORTED: supertype/attributeDefs stored but not enforced
  (type NAME validated only); no glossary surface named on this router — none
  implemented.

## Witness (mix run, real output)

`mix run --no-start tmp/c15_atlas_witness.exs` equivalent —
`elixir -pa _build-lane-c15/dev/lib/smalt/ebin -e 'Code.compile_file(...)' -r tmp/c15_atlas_witness.exs`:

```
== C15 Atlas witness ==
1. unknown typeName on create:  code: "ATLAS-400-CLASS"  -> PASS
2. register typedefs + create two entities + a Process (guids minted)
3. lineage GET (output) from source: both hops
   [src->proc:Process.Input, proc->dst:Process.Output] -> PASS
   guids in map: 3 -> PASS
4. lineage (input) from target: 2 relations -> PASS
5. classification: unregistered -> ATLAS-400-CLASS -> PASS; registered attach -> PASS
6. missing entity -> ATLAS-404-00-005 -> PASS; bulk_classification attach -> PASS
7. update_entities re-mint: update 200 mutated=1 -> PASS;
   lineage after update still 2 relations -> PASS
8. unknown guid in bulk update -> 404 no partial -> PASS
== DONE ==  (11/11 PASS)
```

## Compile gate

```
MIX_BUILD_ROOT=_build-lane-c15 mix compile  -> "Generated smalt app", 0 warnings
   from purview_atlas.ex
MIX_BUILD_ROOT=_build-lane-c15 MIX_ENV=test mix run --no-start tmp/c15_contract_witness.exs
pass=true checks=7
```

Existing `Smalt.RuntimeContracts.PurviewAtlas` contract: `pass=true checks=7`
(no regression; its `smalt_table`/`Unknown` typeNames are builtins under the
new validation).

## Disclosures (compile-freeze SLA)

Shared tree churned mid-flight on OTHER lanes' in-flight files
(kql.ex `_pos` errors, event_grid_webhook.ex, ggen_igniter complete.ex /
execute.ex). I applied NO unblock fixes — each owner fixed their own file
within the SLA window (verified by retrying compile until green).

## Falsifier

Re-run `tmp/c15_atlas_witness.exs` after reverting the diff: step 1 and 5
would return 201 (no validation) instead of typed 400 — the flip is the
non-vacuity proof.
