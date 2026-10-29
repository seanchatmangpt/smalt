# T-01 — Azure Container Registry: control plane + Tasks (FileTaskRunRequest / EncodedTaskRunRequest)

- status: CODE-COMPLETE (2026-10-29): r14, awaiting integration run
- window: v26.10.28 · maps-to: Topaz v1.11 "Container Registry — ACR Tasks multi-step execution" · verdict-at-open: **GAP** (entire plane)
- size: **XL** · depends-on: — · parity-leg: new `acr` suite (ARM SDK probes)

## current state (evidence)

No `Microsoft.ContainerRegistry` provider anywhere in `lib/`. The only ACR
trace is the metadata DNS suffix `"containerRegistry" => "registry.smalt.local"`
(`lib/smalt/arm_gateway/router.ex:3065`). `parity/COVERAGE_VS_TOPAZ.md` ACR
row: Topaz 42/90 documented ops vs smalt 0.

## scope

1. ARM `Microsoft.ContainerRegistry/registries` CRUD (+ `listKeys`,
   `regenerateKey`, `replications`, `webhooks`) through the existing registry
   pattern (`arm_gateway/router.ex` registry types).
2. Registry data-plane API surface (auth with the listed keys, catalog/tag
   listing over the mounted blob-backed store).
3. ACR Tasks: `runs` LRO resource — `FileTaskRunRequest` (multi-step YAML)
   and `EncodedTaskRunRequest` (base64) accepted, validated, and driven
   through a simulated run state machine (Queued → Running → Succeeded),
   with `run` GET/LIST and logs answering the run's recorded output.

## non-goals

- Executing container builds (no Docker — README design law). Run steps are
  simulated state transitions with recorded synthetic log output, typed on
  the wire exactly like real ACR's run/log shapes.
- Docker push/pull of image layers (registry HTTP V2 blob upload is a
  follow-up; catalog/tag metadata first).

## Definition of Done — the Azure developer's view

You point `az` (cloud-registered at smalt's ARM endpoint) at a resource
group and run `az acr create -n myreg --sku Basic` — it returns a registry
with `provisioningState: Succeeded` and a `loginServer` on the smalt DNS
suffix. You create a multi-step task file (`az acr task create --file
task.yaml`) and run `az acr run --file task.yaml` — the command returns a
run id; polling `az acr task runs show` walks Queued → Running → Succeeded,
and `az acr task logs` streams the recorded step output. `az acr list` and
`az acr show` answer the same shapes real Azure does, and an
`@azure/arm-containerregistry` SDK client does the same with zero code
changes. Deleting the registry answers a typed 202 LRO that completes.

## receipts required

`parity/reports/<runid>/` acr suite green-or-registered; an SDK probe file
under `verification/ts/` driving the Tasks LRO end-to-end.
