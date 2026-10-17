# TS Atlas probe — Purview Catalog (Atlas v2) surface (KD-40 lane)

Standing: ALIVE (probe exit 0 on lane substrate, ports 39314-39319)
Date: 2026-10-16
Lane: 328, `MIX_BUILD_ROOT=_build-lane328`, flock `/tmp/smalt-substrate.lock`
Subject: `test/sdk-full/atlas.probe.mjs` against `lib/smalt/data_plane/purview_atlas.ex` + `lib/smalt/egress_router.ex` `/atlas/v2/*` mounts

## Command

```
MIX_BUILD_ROOT=_build-lane328 flock /tmp/smalt-substrate.lock node test/sdk-full/atlas.probe.mjs
```

## Output (final run, verbatim)

```
[ts-atlas-probe] substrate up on 39314/39315/39316/39317/39318/39319 after 1505ms

=== atlas.probe results ===
[PASS] entity create assigns guid (201) — 4a2be20d-1c61-5170-67b2-0324f1e58bff
[PASS] entity create honors supplied guid
[PASS] entity non-map body -> typed 400 ATLAS-400-00-001
[PASS] bulk create 201 with guidAssignments+mutatedEntities
[PASS] bulk over-limit 101 -> typed 400 (atomic, no partial insert)
[PASS] bulk non-array entities -> typed 400
[PASS] entity GET 200 roundtrip; unknown guid -> typed 404 ATLAS-404-00-005
[PASS] relationship POST 201 mints lineage-visible edge
[PASS] relationship missing end1/end2 -> typed 400
[PASS] lineage output depth=2 BFS over 3-node chain
[PASS] lineage bad direction -> typed 400
[DIVERGENCE] POST /atlas/v2/search/collection + GET /atlas/v2/relationship absent — GAP(atlas-search-relationship-get-absent)

total=12 pass=11 divergence=1 fail=0
```

## Rows

| Status | Probe | Detail |
|---|---|---|
| PASS | entity create assigns guid (201) | server-assigned guid `4a2be20d-...58bff` |
| PASS | entity create honors supplied guid | echoed |
| PASS | entity non-map body -> typed 400 ATLAS-400-00-001 | no 500 BadMap |
| PASS | bulk create 201 with guidAssignments+mutatedEntities | 3 entities |
| PASS | bulk over-limit 101 -> typed 400 (atomic, no partial insert) | |
| PASS | bulk non-array entities -> typed 400 | |
| PASS | entity GET 200 roundtrip; unknown guid -> typed 404 ATLAS-404-00-005 | |
| PASS | relationship POST 201 mints lineage-visible edge | end1/end2 wire shape |
| PASS | relationship missing end1/end2 -> typed 400 | |
| PASS | lineage output depth=2 BFS over 3-node chain | transitive g3->g2->g1 |
| PASS | lineage bad direction -> typed 400 | `sideways` refused |
| DIVERGENCE | `POST /atlas/v2/search/collection` + `GET /atlas/v2/relationship/:guid` absent | GAP(atlas-search-relationship-get-absent); "absent" = typed fence refusal (404 RouteNotFound, or the reserved-segment fence's 400 x-ms-version guard for unmatched GETs) |

## Gap semantics

The DIVERGENCE row asserts the gaps stay REFUSED (404/400). If they ever serve
200, the probe FAILs — flip the GAP/KD row only through the receipt-gated
process (`scripts/kd_flip.py --apply`), never silently.

## Falsifier

The DIVERGENCE row is itself the falsifier: any 200 on
`POST /atlas/v2/search/collection` or `GET /atlas/v2/relationship/:guid` flips
the row to FAIL and voids the receipt.

## Boot note

First run on the fresh `_build-lane328` root exited 2 (cold dep compile blew
the 90s boot poll deadline); after `mix deps.compile` precompile in the lane
root, boot is ~1.5s.
