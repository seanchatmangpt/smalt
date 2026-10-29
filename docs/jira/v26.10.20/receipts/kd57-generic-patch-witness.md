# KD-57 witness — ARM generic PATCH (updateByName/updateById) (FIX)

**Standing:** ALIVE (fix landed, wire-witnessed; FLIP-ELIGIBLE)

Row: KD-57 — PATCH on generic resource or /{resourceId} fell to the
diagnosticSettings-only glob -> 404 RouteNotFound.
Subject: `lib/smalt/arm_writer` — scratch that: `lib/smalt/arm_gateway/router.ex`

## Fix (surgical, `# KD-COVERS: KD-57`)

- `patch "/subscriptions/:sub_id/resourceGroups/:rg_name/providers/:provider_ns/:resource_type/:resource_name"`
  declared next to the generic GET (before the globs; Plug matches in
  declaration order).
- `handle_resource_patch/4`: refusal tier mirrors PUT (api-version ->
  GraphLaw admission -> fail-closed properties-member fence -> existence 404)
  minus full-shape validation (a partial body legitimately omits required
  members). Merge law: `properties` merge key-wise into the stored record,
  `tags`/`sku` replace when present; location/id/name immutable. Policy.enforce/2
  rides the same gate as PUT ({:deny, body} -> 400). Missing resource 404
  ResourceNotFound.
- `merge_patch_body/2` helper carries the merge law next to the handler.

## Evidence (lane K4 substrate on :39551, 2026-10-21)

```
== KD57 PATCH tags+props (JSON content-type)
tags {'b': '2'} access False        # tags replaced, properties merged
== KD57 PATCH missing (404)
404
== KD57 PATCH bad props member (400)
400
== KD57 PATCH future api-version 2099-01-01 (400)
400
== KD57 PATCH sku (updateById form)
sku {'name': 'Premium_LRS'}         # sku replaced
```

Row falsifier (updateById -> 200 patched body) passes.

## Wire note (pre-existing, NOT introduced by this lane)

curl `-d` without an explicit `Content-Type: application/json` sends
`application/x-www-form-urlencoded`; Plug's urlencoded parser consumes the JSON
as one garbage pair and the PATCH merges nothing (200 no-op). PUT has the
identical behavior — masked by defaults hydration (witnessed on the live
substrate: a no-CT storage PUT silently gets sku Standard_LRS instead of the
requested Premium_LRS). A potential future KD candidate (SDKs always send
application/json, so no SDK divergence today); lane K4 made no change to this
shared behavior.

## Regression check

`MIX_BUILD_ROOT=_build-k4 mix test test/integration/namespace_put_test.exs
test/integration/arm_dcr_test.exs` -> 8 tests, 0 failures. Error-corpus suite
failures are concurrent-lane surfaces (cosmos TTL, bridge, census, dist-join),
not the PATCH route.

## Flip

FLIP-ELIGIBLE (dry-run only; flip via `scripts/kd_flip.py --apply`, gated on
receipt mtime).

Verdict: PASS (falsifier of the row executed on the wire; output above).
