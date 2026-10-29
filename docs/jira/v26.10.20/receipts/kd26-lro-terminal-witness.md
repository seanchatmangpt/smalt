# KD-26 witness — ARM LRO terminal provisioningState (stale-row disposition)

**Standing:** CLOSED (KD-26 row OBSOLETE — row evidence stale, matches the AUD-3 note at
KNOWN_DIVERGENCES.md:115-116 that R:623-624 already writes provisioningState)

Row: KD-26 — created storageAccount lacks `provisioningState` post-LRO.
Subject: `lib/smalt/arm_gateway/router.ex` (build_resource_record: properties
member gets `Map.put("provisioningState", "Succeeded")`)

## Disposition

OBSOLETE. Every persisted generic resource record carries
`properties.provisioningState = "Succeeded"` (build_resource_record, pre-existing
code). Witnessed post-LRO on the live wire.

## Evidence (live wire, lane K4 substrate on :39551, 2026-10-21)

```
== KD26 GET storage account post-LRO
props keys: ['allowBlobPublicAccess', 'minimumTlsVersion', 'networkAcls',
             'primaryEndpoints', 'provisioningState', 'supportsHttpsTrafficOnly']
provisioningState: Succeeded
```

SDK state=None premise no longer reproduces. Close condition ("render
provisioningState at LRO terminal") met.

## Flip

FLIP-ELIGIBLE (dry-run; flip via kd_flip.py --apply only).

## RE-WITNESS addendum (BK-REWIT2 lane, 2026-10-22)

```
$ grep -n '"provisioningState" => "Succeeded"' lib/smalt/arm_gateway/router.ex
803:      "properties" => %{"provisioningState" => "Succeeded"},
1675:      "properties" => %{"provisioningState" => "Succeeded"},
5353:          "provisioningState" => "Succeeded",
5522:        "provisioningState" => "Succeeded",
exit=0
$ MIX_BUILD_ROOT=_build-rewit2 mix compile   # shared probe
exit=0
```

Four render sites present including build_resource_record; close condition
("render provisioningState at LRO terminal") holds on the compiled surface.
Standing unchanged: OBSOLETE. exit=0
