# KD-59 ARM RG export/move — witness receipt (K5, v26.10.20)

**Standing:** ALIVE (fix landed + wire-witnessed)
Context: solo
Date: 2026-10-20

## Disposition: FIX (partial by design: exportTemplate routed; move = typed UNSUPPORTED)

Row: exportTemplate / moveResources / validateMoveResources -> 404.
Close condition admits routes OR typed UNSUPPORTED; falsifier "never 404".

## Change (lib/smalt/arm_gateway/router.ex, # KD-COVERS: KD-59)

- POST .../resourcegroups|resourceGroups/{rg}/exportTemplate ->
  `Smalt.Arm.ExportTemplate.export_rg/3` (the wave-6 export face, previously
  UNROUTED in lib/smalt/arm/export_template.ex). Synchronous 200 (terminal
  for ARM LRO pollers — documented boundary). RG with no exportable
  resources -> typed 404 ResourceGroupResourceNotFound.
- moveResources / validateMoveResources -> typed 400
  MoveUnsupportedResourceType (never 404).

## Witness (witness beam 39780, 2026-10-20)

    == exportTemplate empty RG (expect 404 typed)
    404 {"error":{"code":"ResourceGroupResourceNotFound",...
    == seed storage account (LRO 202), then exportTemplate
    200 {"$schema":".../2019-04-01/deploymentTemplate.json#",...,"resources":[{"apiVersion":"2023-05-01",...,"name":"k5acc",...
    == moveResources (expect 400 typed)
    400 {"error":{"code":"MoveUnsupportedResourceType",...
    == validateMoveResources
    400 MoveUnsupportedResourceType

Baseline-contrast: identical exportTemplate POST on the live substrate
pre-fix -> 404 RouteNotFound.

Verdict: PASS (exportTemplate -> 200 template / typed 404; move -> typed 400; never 404).
