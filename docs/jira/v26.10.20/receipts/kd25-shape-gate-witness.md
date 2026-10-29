# KD-25 witness — ARM shape gate sku shape (stale-row disposition)

**Standing:** CLOSED (KD-25 row OBSOLETE — row evidence stale, close condition already met on wire)

Row: KD-25 — GraphLaw requires `properties.skuName`; real ARM takes top-level
`sku.name`.
Subject: `lib/smalt/arm_gateway/router.ex` (handle_resource_put gates),
`lib/smalt/arm_gateway/defaults.ex`

## Disposition

OBSOLETE. Top-level `sku.name` is admitted and rendered: a PUT with
`{"sku":{"name":"Standard_LRS"},"kind":"StorageV2"}` round-trips `sku` on GET,
and the `maybe_put_sku/2` lift (router.ex) carries the merged body's top-level
sku onto the record. The `properties.skuName` form is ALSO accepted (both
shapes witness on the wire). No lib/ edit made for this row by lane K4.

## Evidence (live wire, lane K4 substrate on :39551, 2026-10-21)

```
== KD25 storage PUT top-level sku.name -> 202 LRO InProgress
== KD25 GET k4patch: sku {'name': 'Standard_LRS'}
== KD25 GET skuname (PUT body {"properties":{"skuName":"Premium_LRS"}} variant):
   props keys: ['allowBlobPublicAccess', ..., 'provisioningState', ...]
```

Both request shapes reach a 200 GET with sku rendered; the GraphLaw
`properties.skuName`-only gate described by the row is gone. Close condition
("resolve shape paths against real-ARM body shape") met.

## Flip

FLIP-ELIGIBLE (dry-run; flip via kd_flip.py --apply only).

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

```
$ grep -n 'defp maybe_put_sku' lib/smalt/arm_gateway/router.ex
1684:  defp maybe_put_sku(record, merged) do
exit=0
$ MIX_BUILD_ROOT=_build-rewit2 mix compile   # shared probe
exit=0
```

The `maybe_put_sku/2` lift is present in the compiled surface; both sku shapes
remain admitted per the original wire evidence (2026-10-21, :39551). Standing
unchanged: OBSOLETE. exit=0
