# Gap 13 phase-1 core-class shard — projection table (lane M13)

Draft shard: `13-phase1-core-classes.ttl` (same dir). NOT canonical — lane 8
owns `priv/ontologies/public-cloud-core.ttl`. This notes file is the
58/57-accounting receipt; the ttl carries zero wire strings by the split law.

## Census correction (typed, not silent)

Gap-13 H4 claims "the 58 admitted types". Disk this session (2026-10-30):
**57** — `lib/smalt/registry.ex:18-76` `@admitted_resource_types` enumerates
57 entries. The 58 figure is a stale receipt-cited count. Accounting:
**57/57 mapped + 1 typed correction row = the 58-row population accounted**.
No type silently dropped; no UNSUPPORTED row needed.

## Projection table (57/57, one core class each)

Derivation law: gap-13 H4 family table applied to the registry list
(READ-ONLY; registry.ex not edited or regenerated). Mechanically derived and
count-verified this session (script asserted len==57 and total coverage with
a disjoint prefix law — Authorization is split: roleAssignments/roleDefinitions
-> IdentityPrincipal; locks/policy* -> GovernanceSurface).

| # | Admitted type (dialect string, cited read-only from registry.ex) | Core class |
|---|---|---|
| 1 | `Microsoft.App/containerApps` | tosca:ContainerWorkload |
| 2 | `Microsoft.App/managedEnvironments` | tosca:ContainerWorkload |
| 3 | `Microsoft.Attestation/attestationProviders` | tosca:TrustAnchor |
| 4 | `Microsoft.Authorization/locks` | tosca:GovernanceSurface |
| 5 | `Microsoft.Authorization/policyExemptions` | tosca:GovernanceSurface |
| 6 | `Microsoft.Authorization/policyRemediations` | tosca:GovernanceSurface |
| 7 | `Microsoft.Authorization/policySetDefinitions` | tosca:GovernanceSurface |
| 8 | `Microsoft.Authorization/roleAssignments` | tosca:IdentityPrincipal |
| 9 | `Microsoft.Authorization/roleDefinitions` | tosca:IdentityPrincipal |
| 10 | `Microsoft.Compute/diskEncryptionSets` | tosca:ComputeEnvironment
| 11 | `Microsoft.Compute/disks` | tosca:ComputeEnvironment
| 12 | `Microsoft.Compute/virtualMachines` | tosca:ComputeEnvironment
| 13 | `Microsoft.ConfidentialLedger/ledgers` | tosca:TrustAnchor |
| 14 | `Microsoft.ConfidentialLedger/managedCCFs` | tosca:TrustAnchor |
| 15 | `Microsoft.ContainerRegistry/registries` | tosca:ObjectRegistry |
| 16 | `Microsoft.ContainerRegistry/registries/webhooks` | tosca:ObjectRegistry |
| 17 | `Microsoft.ContainerService/managedClusters` | tosca:ContainerWorkload |
| 18 | `Microsoft.DevTestLab/schedules` | tosca:ContainerWorkload |
| 19 | `Microsoft.DocumentDB/databaseAccounts` | tosca:DataStore |
| 20 | `Microsoft.DocumentDB/databaseAccounts/sqlContainers` | tosca:DataStore |
| 21 | `Microsoft.DocumentDB/databaseAccounts/sqlDatabases` | tosca:DataStore |
| 22 | `Microsoft.EventGrid/systemTopics` | tosca:MessageHub |
| 23 | `Microsoft.EventGrid/systemTopics/eventSubscriptions` | tosca:MessageHub |
| 24 | `Microsoft.EventGrid/topics` | tosca:MessageHub |
| 25 | `Microsoft.EventHub/namespaces` | tosca:MessageHub |
| 26 | `Microsoft.EventHub/namespaces/eventhubs` | tosca:MessageHub |
| 27 | `Microsoft.EventHub/namespaces/eventhubs/consumergroups` | tosca:MessageHub |
| 28 | `Microsoft.Insights/dataCollectionRules` | tosca:GovernanceSurface |
| 29 | `Microsoft.Insights/diagnosticSettings` | tosca:GovernanceSurface |
| 30 | `Microsoft.KeyVault/managedHSMs` | tosca:SecretStore |
| 31 | `Microsoft.KeyVault/vaults` | tosca:SecretStore |
| 32 | `Microsoft.KeyVault/vaults/keys` | tosca:SecretStore |
| 33 | `Microsoft.KeyVault/vaults/secrets` | tosca:SecretStore |
| 34 | `Microsoft.ManagedIdentity/federatedIdentityCredentials` | tosca:IdentityPrincipal |
| 35 | `Microsoft.ManagedIdentity/userAssignedIdentities` | tosca:IdentityPrincipal |
| 36 | `Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials` | tosca:IdentityPrincipal |
| 37 | `Microsoft.Network/networkInterfaces` | tosca:NetworkFabric |
| 38 | `Microsoft.Network/networkSecurityGroups` | tosca:NetworkFabric |
| 39 | `Microsoft.Network/privateDnsZones` | tosca:NetworkFabric |
| 40 | `Microsoft.Network/privateDnsZones/virtualNetworkLinks` | tosca:NetworkFabric |
| 41 | `Microsoft.Network/privateEndpoints` | tosca:NetworkFabric |
| 42 | `Microsoft.Network/publicIPAddresses` | tosca:NetworkFabric |
| 43 | `Microsoft.Network/subnets` | tosca:NetworkFabric |
| 44 | `Microsoft.Network/virtualNetworks` | tosca:NetworkFabric |
| 45 | `Microsoft.OperationalInsights/workspaces` | tosca:DataStore |
| 46 | `Microsoft.Purview/accounts` | tosca:GovernanceSurface |
| 47 | `Microsoft.Resources/resourceGroups` | tosca:ObjectRegistry |
| 48 | `Microsoft.SecurityInsights/onboardingStates` | tosca:GovernanceSurface |
| 49 | `Microsoft.ServiceBus/namespaces` | tosca:MessageHub |
| 50 | `Microsoft.ServiceBus/namespaces/queues` | tosca:MessageHub |
| 51 | `Microsoft.ServiceBus/namespaces/topics` | tosca:MessageHub |
| 52 | `Microsoft.ServiceBus/namespaces/topics/subscriptions` | tosca:MessageHub |
| 53 | `Microsoft.ServiceBus/namespaces/topics/subscriptions/rules` | tosca:MessageHub |
| 54 | `Microsoft.Storage/storageAccounts` | tosca:ObjectRegistry |
| 55 | `Microsoft.Storage/storageAccounts/blobServices` | tosca:ObjectRegistry |
| 56 | `Microsoft.Storage/storageAccounts/blobServices/containers` | tosca:ObjectRegistry |
| 57 | `Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies` | tosca:ObjectRegistry |

## Coverage summary (sums to 57)

- tosca:ComputeEnvironment: 3
- tosca:ContainerWorkload: 4
- tosca:DataStore: 4
- tosca:GovernanceSurface: 8
- tosca:IdentityPrincipal: 5
- tosca:MessageHub: 11
- tosca:NetworkFabric: 8
- tosca:ObjectRegistry: 7
- tosca:SecretStore: 4
- tosca:TrustAnchor: 3

## Consistency with M2's shard (02-p1-core-ttl-shard.md)

Present and read this session. Consistency kept: (a) standards-only
namespaces (tosca:/cimi:/kmip:/sec:) matching M2's S1-S7 vocabulary law;
(b) the ttl's capability-level shape laws reference (rdfs:seeAlso) M2's
classes — tosca:ResourceEnvelope (S1), cimi:ConcurrencyLaw (S5),
cimi:EntryStatusLaw (S7/201-200 law), cimi:OperationLifecycle (S4);
(c) class hierarchy is re-parent-under-core-compatible: M2 shapes bind via
sh:property on tosca:CoreCapability, so lane 8 can merge this class layer
under the same root without re-parenting conflicts.

## Falsifiers

1. Parse: rdflib 7.6.0 parses the shard, exit 0, **64 triples**.
2. Zero proprietary IRIs: grep for `smalt.dev|Microsoft/|azure` over the ttl
   -> 0 matches (exit 1 = clean).
3. Coverage: 57/57 mapped (table above), mechanically count-verified; zero
   silent drops, zero UNSUPPORTED rows required.
4. Admission-corpus close condition: **BLOCKED-on-merge** — the phase-1
   court (mix smalt.gen emits registry_core.ex; replay-identity fence; full
   census) runs post-merge and is the open residual. This shard is a DRAFT
   input, not admitted core semantics (v26.10.31 in transition).
