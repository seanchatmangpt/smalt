# Substrate Registry
# Auto-projected from smalt-substrate-pack ontology via ggen_igniter.sync.
# DO NOT EDIT — regenerate with `mix smalt.gen`.
# Ports: 9443 (ARM REST), 8443 (Cosmos/KeyVault), 5672 (AMQP SB), 5673 (Event Hubs)
defmodule Smalt.Registry do
  @moduledoc """
  Machine-generated registry of admitted resource types, per-type shapes,
  and supported api-versions. Source of truth:
  ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl
  """

  # Canonical ordering: rows are sorted by resourceType at render time so the
  # artifact is independent of SPARQL engine row order (the `sparql` hex
  # engine does not honor ORDER BY — see GgenIgniter.Query's moduledoc).
  # Replay identity is fenced by the Smalt.Registry.ReplayIdentity module
  # (SHIM-COURT-clean template; replay must be byte-identical).

  @admitted_resource_types [
    "Microsoft.App/containerApps",
    "Microsoft.Attestation/attestationProviders",
    "Microsoft.Authorization/locks",
    "Microsoft.Authorization/policyExemptions",
    "Microsoft.Authorization/policyRemediations",
    "Microsoft.Authorization/policySetDefinitions",
    "Microsoft.Authorization/roleAssignments",
    "Microsoft.Compute/diskEncryptionSets",
    "Microsoft.Compute/disks",
    "Microsoft.Compute/virtualMachines",
    "Microsoft.ConfidentialLedger/ledgers",
    "Microsoft.ConfidentialLedger/managedCCFs",
    "Microsoft.ContainerRegistry/registries",
    "Microsoft.ContainerRegistry/registries/webhooks",
    "Microsoft.ContainerService/managedClusters",
    "Microsoft.DevTestLab/schedules",
    "Microsoft.DocumentDB/databaseAccounts",
    "Microsoft.DocumentDB/databaseAccounts/sqlContainers",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases",
    "Microsoft.EventGrid/systemTopics",
    "Microsoft.EventGrid/systemTopics/eventSubscriptions",
    "Microsoft.EventGrid/topics",
    "Microsoft.EventHub/namespaces",
    "Microsoft.EventHub/namespaces/eventhubs",
    "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
    "Microsoft.Insights/dataCollectionRules",
    "Microsoft.Insights/diagnosticSettings",
    "Microsoft.KeyVault/managedHSMs",
    "Microsoft.KeyVault/vaults",
    "Microsoft.KeyVault/vaults/keys",
    "Microsoft.KeyVault/vaults/secrets",
    "Microsoft.ManagedIdentity/federatedIdentityCredentials",
    "Microsoft.ManagedIdentity/userAssignedIdentities",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials",
    "Microsoft.Network/networkInterfaces",
    "Microsoft.Network/networkSecurityGroups",
    "Microsoft.Network/privateDnsZones",
    "Microsoft.Network/privateDnsZones/virtualNetworkLinks",
    "Microsoft.Network/privateEndpoints",
    "Microsoft.Network/subnets",
    "Microsoft.Network/virtualNetworks",
    "Microsoft.OperationalInsights/workspaces",
    "Microsoft.Purview/accounts",
    "Microsoft.Resources/resourceGroups",
    "Microsoft.SecurityInsights/onboardingStates",
    "Microsoft.ServiceBus/namespaces",
    "Microsoft.ServiceBus/namespaces/queues",
    "Microsoft.ServiceBus/namespaces/topics",
    "Microsoft.ServiceBus/namespaces/topics/subscriptions",
    "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules",
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Storage/storageAccounts/blobServices",
    "Microsoft.Storage/storageAccounts/blobServices/containers",
    "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies"
  ]

  @type_shapes %{
    "Microsoft.App/containerApps" => "DefaultShape",
    "Microsoft.Attestation/attestationProviders" => "DefaultShape",
    "Microsoft.Authorization/locks" => "DefaultShape",
    "Microsoft.Authorization/policyExemptions" => "DefaultShape",
    "Microsoft.Authorization/policyRemediations" => "DefaultShape",
    "Microsoft.Authorization/policySetDefinitions" => "DefaultShape",
    "Microsoft.Authorization/roleAssignments" => "DefaultShape",
    "Microsoft.Compute/diskEncryptionSets" => "DefaultShape",
    "Microsoft.Compute/disks" => "DefaultShape",
    "Microsoft.Compute/virtualMachines" => "VirtualMachineShape",
    "Microsoft.ConfidentialLedger/ledgers" => "DefaultShape",
    "Microsoft.ConfidentialLedger/managedCCFs" => "DefaultShape",
    "Microsoft.ContainerRegistry/registries" => "DefaultShape",
    "Microsoft.ContainerRegistry/registries/webhooks" => "DefaultShape",
    "Microsoft.ContainerService/managedClusters" => "DefaultShape",
    "Microsoft.DevTestLab/schedules" => "DefaultShape",
    "Microsoft.DocumentDB/databaseAccounts" => "CosmosAccountShape",
    "Microsoft.DocumentDB/databaseAccounts/sqlContainers" => "SqlContainerShape",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases" => "SqlDatabaseShape",
    "Microsoft.EventGrid/systemTopics" => "DefaultShape",
    "Microsoft.EventGrid/systemTopics/eventSubscriptions" => "DefaultShape",
    "Microsoft.EventGrid/topics" => "DefaultShape",
    "Microsoft.EventHub/namespaces" => "DefaultShape",
    "Microsoft.EventHub/namespaces/eventhubs" => "DefaultShape",
    "Microsoft.EventHub/namespaces/eventhubs/consumergroups" => "DefaultShape",
    "Microsoft.Insights/dataCollectionRules" => "DefaultShape",
    "Microsoft.Insights/diagnosticSettings" => "DefaultShape",
    "Microsoft.KeyVault/managedHSMs" => "ManagedHsmShape",
    "Microsoft.KeyVault/vaults" => "KeyVaultShape",
    "Microsoft.KeyVault/vaults/keys" => "DefaultShape",
    "Microsoft.KeyVault/vaults/secrets" => "KeyVaultSecretShape",
    "Microsoft.ManagedIdentity/federatedIdentityCredentials" => "DefaultShape",
    "Microsoft.ManagedIdentity/userAssignedIdentities" => "DefaultShape",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials" =>
      "DefaultShape",
    "Microsoft.Network/networkInterfaces" => "DefaultShape",
    "Microsoft.Network/networkSecurityGroups" => "NsgShape",
    "Microsoft.Network/privateDnsZones" => "DefaultShape",
    "Microsoft.Network/privateDnsZones/virtualNetworkLinks" => "DefaultShape",
    "Microsoft.Network/privateEndpoints" => "DefaultShape",
    "Microsoft.Network/subnets" => "SubnetShape",
    "Microsoft.Network/virtualNetworks" => "VNetShape",
    "Microsoft.OperationalInsights/workspaces" => "DefaultShape",
    "Microsoft.Purview/accounts" => "DefaultShape",
    "Microsoft.Resources/resourceGroups" => "ResourceGroupShape",
    "Microsoft.SecurityInsights/onboardingStates" => "DefaultShape",
    "Microsoft.ServiceBus/namespaces" => "ServiceBusNamespaceShape",
    "Microsoft.ServiceBus/namespaces/queues" => "DefaultShape",
    "Microsoft.ServiceBus/namespaces/topics" => "DefaultShape",
    "Microsoft.ServiceBus/namespaces/topics/subscriptions" => "DefaultShape",
    "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules" => "DefaultShape",
    "Microsoft.Storage/storageAccounts" => "StorageAccountShape",
    "Microsoft.Storage/storageAccounts/blobServices" => "DefaultShape",
    "Microsoft.Storage/storageAccounts/blobServices/containers" => "DefaultShape",
    "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies" =>
      "DefaultShape"
  }

  @api_versions %{
    "Microsoft.App/containerApps" => "2023-05-01",
    "Microsoft.Attestation/attestationProviders" => "2020-10-01",
    "Microsoft.Authorization/locks" => "2020-05-01",
    "Microsoft.Authorization/policyExemptions" => "2022-07-01",
    "Microsoft.Authorization/policyRemediations" => "2021-10-01",
    "Microsoft.Authorization/policySetDefinitions" => "2023-04-01",
    "Microsoft.Authorization/roleAssignments" => "2022-04-01",
    "Microsoft.Compute/diskEncryptionSets" => "2021-04-01",
    "Microsoft.Compute/disks" => "2021-04-01",
    "Microsoft.Compute/virtualMachines" => "2021-04-01",
    "Microsoft.ConfidentialLedger/ledgers" => "2020-12-01-preview",
    "Microsoft.ConfidentialLedger/managedCCFs" => "2023-06-27-preview",
    "Microsoft.ContainerRegistry/registries" => "2023-06-01",
    "Microsoft.ContainerRegistry/registries/webhooks" => "2023-06-01",
    "Microsoft.ContainerService/managedClusters" => "2023-02-01",
    "Microsoft.DevTestLab/schedules" => "2018-09-15",
    "Microsoft.DocumentDB/databaseAccounts" => "2024-08-15",
    "Microsoft.DocumentDB/databaseAccounts/sqlContainers" => "2023-05-01",
    "Microsoft.DocumentDB/databaseAccounts/sqlDatabases" => "2023-05-01",
    "Microsoft.EventGrid/systemTopics" => "2022-06-15",
    "Microsoft.EventGrid/systemTopics/eventSubscriptions" => "2022-06-15",
    "Microsoft.EventGrid/topics" => "2021-04-01",
    "Microsoft.EventHub/namespaces" => "2024-01-01",
    "Microsoft.EventHub/namespaces/eventhubs" => "2024-01-01",
    "Microsoft.EventHub/namespaces/eventhubs/consumergroups" => "2021-04-01",
    "Microsoft.Insights/dataCollectionRules" => "2022-06-01",
    "Microsoft.Insights/diagnosticSettings" => "2021-05-01-preview",
    "Microsoft.KeyVault/managedHSMs" => "2021-04-01",
    "Microsoft.KeyVault/vaults" => "2023-02-01",
    "Microsoft.KeyVault/vaults/keys" => "2023-07-01",
    "Microsoft.KeyVault/vaults/secrets" => "2023-07-01",
    "Microsoft.ManagedIdentity/federatedIdentityCredentials" => "2023-01-31",
    "Microsoft.ManagedIdentity/userAssignedIdentities" => "2023-04-01",
    "Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials" =>
      "2023-01-31",
    "Microsoft.Network/networkInterfaces" => "2021-04-01",
    "Microsoft.Network/networkSecurityGroups" => "2021-04-01",
    "Microsoft.Network/privateDnsZones" => "2018-09-01",
    "Microsoft.Network/privateDnsZones/virtualNetworkLinks" => "2018-09-01",
    "Microsoft.Network/privateEndpoints" => "2021-04-01",
    "Microsoft.Network/subnets" => "2021-04-01",
    "Microsoft.Network/virtualNetworks" => "2021-04-01",
    "Microsoft.OperationalInsights/workspaces" => "2020-08-01",
    "Microsoft.Purview/accounts" => "2021-05-01",
    "Microsoft.Resources/resourceGroups" => "2023-07-01",
    "Microsoft.SecurityInsights/onboardingStates" => "2021-04-01",
    "Microsoft.ServiceBus/namespaces" => "2024-01-01",
    "Microsoft.ServiceBus/namespaces/queues" => "2024-01-01",
    "Microsoft.ServiceBus/namespaces/topics" => "2021-04-01",
    "Microsoft.ServiceBus/namespaces/topics/subscriptions" => "2021-04-01",
    "Microsoft.ServiceBus/namespaces/topics/subscriptions/rules" => "2021-04-01",
    "Microsoft.Storage/storageAccounts" => "2023-05-01",
    "Microsoft.Storage/storageAccounts/blobServices" => "2023-05-01",
    "Microsoft.Storage/storageAccounts/blobServices/containers" => "2023-05-01",
    "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies" =>
      "2023-05-01"
  }

  # KD-78 admission lattice: the per-type ordered api-version lattice lives in
  # the ontology (smalt:apiVersion = lattice top, smalt:admittedVersion =
  # ordered witness rows). Informational only — the admission RULE is the
  # monotonic comparison in admitted_version?/2 below, against the top.
  def admitted_resource_types, do: @admitted_resource_types
  def type_shapes, do: @type_shapes
  def api_versions, do: @api_versions
  def shape_for(type), do: Map.get(@type_shapes, type)
  def latest_version(type), do: Map.get(@api_versions, type)
  def admitted?(type), do: type in @admitted_resource_types

  # Monotonic api-version admission (KD-78): base(V) as date <= latest as date.
  # Lattice = half-open interval (-inf, latest]. Malformed versions are never
  # admitted. This is the projection of the ontology's smalt:admitsVersion
  # derived predicate — check_version/3 must call THIS, never hand-compare.
  def admitted_version?(type, version) when is_binary(type) and is_binary(version) do
    case latest_version(type) do
      nil ->
        false

      latest when is_binary(latest) ->
        with {:ok, v} <- version |> version_base() |> Date.from_iso8601(),
             {:ok, l} <- Date.from_iso8601(latest) do
          Date.compare(v, l) in [:lt, :eq]
        else
          _ -> false
        end
    end
  end

  def admitted_version?(_type, _version), do: false

  defp version_base(version), do: hd(String.split(version, "-preview"))

  def control_plane_port, do: 9443
  def data_plane_port, do: 8443
  def amqp_port, do: Application.get_env(:smalt, :amqp_port, 5672)
  def event_hubs_port, do: Application.get_env(:smalt, :event_hubs_port, 5673)
  # GGEN-CACHE lane r11: Redis RESP2/RESP3 wire listener (AzureCache wire
  # facade, Smalt.DataPlane.RedisWire). Runtime accessor mirrors
  # RedisWire.configured_port/0; the default feeds the env-independent
  # canonical capability document (R83 disclosure).
  def redis_port, do: Application.get_env(:smalt, :redis_port, 6380)
  # Canonical defaults for env-independent documents (docs/capabilities.json):
  # the capability surface is the substrate contract, not the runtime override.
  def amqp_port_default, do: 5672
  def event_hubs_port_default, do: 5673
  def redis_port_default, do: 6380
end
