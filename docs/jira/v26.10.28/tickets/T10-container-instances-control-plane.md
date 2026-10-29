# T-10 — Container Instances: control plane only (execution out-of-scope)

- status: CODE-COMPLETE (2026-10-29): r17, awaiting integration run
- window: v26.10.28 · maps-to: Topaz v1.13 "Container Instances — Docker-backed execution · log streaming · local ACR integration" · verdict-at-open: **GAP** (control plane) / **OUT-OF-SCOPE** (execution)
- size: **M** · depends-on: T-01 (ACR integration touches registries)

## current state (evidence)

No `Microsoft.ContainerInstance` provider in `lib/` (map row). Execution is
against smalt's design law (README: "no cloud connection, no host
configuration for the native tier"; this dev box additionally has no
Docker).

## scope

1. ARM `Microsoft.ContainerInstance/containerGroups` CRUD: PUT validates
   the real schema (containers, image, resources, ports, probes), GET
   renders `provisioningState: Succeeded` + instanceView with
   `currentState: Running` (simulated lifecycle for control-only groups).
2. `logs` action (`/containers/<name>/logs`) answers a typed, documented
   `NotSupportedOnSubstrate`-class error (fail-closed, never fake logs).
3. `imageRegistryCredentials` referencing a mounted ACR (T-01) resolve at
   PUT validation time (registry must exist; key must be one of its keys).

## non-goals

- Running containers, log streaming, ACR image pulls — permanent
  out-of-scope per the design law; the DoD is honest about this.

## Definition of Done — the Azure developer's view

Your terraform/azurerm `azurerm_container_group` resources plan and apply
cleanly against smalt: `az container create` (or the ARM SDK PUT) accepts
a real container-group body, `az container show` returns the group with
Running state and your IP/port shape, `az container list` paginates, and
`az container delete` completes its LRO. Pointing
`imageRegistryCredentials` at a registry that does not exist fails at PUT
with the same validation error Azure gives. If you ask for logs, you get a
clear typed error saying execution is not emulated — never a fabricated
log stream pretending to be your container.

## receipts required

ARM CRUD court for containerGroups; registry-credential validation receipt;
typed-not-supported logs receipt.
