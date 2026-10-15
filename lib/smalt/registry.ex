# Substrate Registry — projected from smalt-substrate-pack ontology (SMALT v26.10.14).
# Source of truth: ggen-marketplace/packs/smalt-substrate-pack/ontology.ttl
# DO NOT hand-edit. Regenerate with: mix smalt.gen
defmodule Smalt.Registry do
  @moduledoc """
  Projected registry of admitted resource types, per-type SHACL shape
  bindings, and supported api-versions. Projected first-class (no
  generated/ directory) from the smalt-substrate-pack ontology.
  """

  @admitted_resource_types [
    "Microsoft.App/containerApps",
    "Microsoft.Attestation/attestationProviders",
    "Microsoft.Authorization/roleAssignments",
    "Microsoft.Compute/diskEncryptionSets",
    "Microsoft.Compute/disks",
    "Microsoft.Compute/virtualMachines",
    "Microsoft.ConfidentialLedger/ledgers",
    "Microsoft.ConfidentialLedger/managedCCFs",
    "Microsoft.ContainerService/managedClusters",
    "Microsoft.DevTestLab/schedules",
    "Microsoft.DocumentDB/databaseAccounts",
    "Microsoft.EventGrid/topics",
    "Microsoft.EventHub/namespaces",
    "Microsoft.EventHub/namespaces/eventhubs",
    "Microsoft.EventHub/namespaces/eventhubs/consumergroups",
    "Microsoft.Insights/diagnosticSettings",
    "Microsoft.KeyVault/managedHSMs",
    "Microsoft.KeyVault/vaults",
    "Microsoft.KeyVault/vaults/keys",
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
    "Microsoft.Storage/storageAccounts",
    "Microsoft.Storage/storageAccounts/blobServices",
    "Microsoft.Storage/storageAccounts/blobServices/containers",
    "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies"
  ]

  @type_shapes %{
    "Microsoft.App/containerApps" => "DefaultShape",
    "Microsoft.Attestation/attestationProviders" => "DefaultShape",
    "Microsoft.Authorization/roleAssignments" => "DefaultShape",
    "Microsoft.Compute/diskEncryptionSets" => "DefaultShape",
    "Microsoft.Compute/disks" => "DefaultShape",
    "Microsoft.Compute/virtualMachines" => "VirtualMachineShape",
    "Microsoft.ConfidentialLedger/ledgers" => "DefaultShape",
    "Microsoft.ConfidentialLedger/managedCCFs" => "DefaultShape",
    "Microsoft.ContainerService/managedClusters" => "DefaultShape",
    "Microsoft.DevTestLab/schedules" => "DefaultShape",
    "Microsoft.DocumentDB/databaseAccounts" => "CosmosAccountShape",
    "Microsoft.EventGrid/topics" => "DefaultShape",
    "Microsoft.EventHub/namespaces" => "DefaultShape",
    "Microsoft.EventHub/namespaces/eventhubs" => "DefaultShape",
    "Microsoft.EventHub/namespaces/eventhubs/consumergroups" => "DefaultShape",
    "Microsoft.Insights/diagnosticSettings" => "DefaultShape",
    "Microsoft.KeyVault/managedHSMs" => "ManagedHsmShape",
    "Microsoft.KeyVault/vaults" => "KeyVaultShape",
    "Microsoft.KeyVault/vaults/keys" => "DefaultShape",
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
    "Microsoft.Storage/storageAccounts" => "StorageAccountShape",
    "Microsoft.Storage/storageAccounts/blobServices" => "DefaultShape",
    "Microsoft.Storage/storageAccounts/blobServices/containers" => "DefaultShape",
    "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies" => "DefaultShape"
  }

  @api_versions %{
    "Microsoft.App/containerApps" => "2023-05-01",
    "Microsoft.Attestation/attestationProviders" => "2020-10-01",
    "Microsoft.Authorization/roleAssignments" => "2022-04-01",
    "Microsoft.Compute/diskEncryptionSets" => "2021-04-01",
    "Microsoft.Compute/disks" => "2021-04-01",
    "Microsoft.Compute/virtualMachines" => "2021-04-01",
    "Microsoft.ConfidentialLedger/ledgers" => "2020-12-01-preview",
    "Microsoft.ConfidentialLedger/managedCCFs" => "2023-06-27-preview",
    "Microsoft.ContainerService/managedClusters" => "2023-02-01",
    "Microsoft.DevTestLab/schedules" => "2018-09-15",
    "Microsoft.DocumentDB/databaseAccounts" => "2021-04-01",
    "Microsoft.EventGrid/topics" => "2021-04-01",
    "Microsoft.EventHub/namespaces" => "2021-04-01",
    "Microsoft.EventHub/namespaces/eventhubs" => "2021-04-01",
    "Microsoft.EventHub/namespaces/eventhubs/consumergroups" => "2021-04-01",
    "Microsoft.Insights/diagnosticSettings" => "2021-05-01-preview",
    "Microsoft.KeyVault/managedHSMs" => "2021-04-01",
    "Microsoft.KeyVault/vaults" => "2021-04-01",
    "Microsoft.KeyVault/vaults/keys" => "2023-07-01",
    "Microsoft.Network/networkInterfaces" => "2021-04-01",
    "Microsoft.Network/networkSecurityGroups" => "2021-04-01",
    "Microsoft.Network/privateDnsZones" => "2018-09-01",
    "Microsoft.Network/privateDnsZones/virtualNetworkLinks" => "2018-09-01",
    "Microsoft.Network/privateEndpoints" => "2021-04-01",
    "Microsoft.Network/subnets" => "2021-04-01",
    "Microsoft.Network/virtualNetworks" => "2021-04-01",
    "Microsoft.OperationalInsights/workspaces" => "2020-08-01",
    "Microsoft.Purview/accounts" => "2021-05-01",
    "Microsoft.Resources/resourceGroups" => "2021-04-01",
    "Microsoft.SecurityInsights/onboardingStates" => "2021-04-01",
    "Microsoft.ServiceBus/namespaces" => "2021-04-01",
    "Microsoft.ServiceBus/namespaces/queues" => "2021-04-01",
    "Microsoft.ServiceBus/namespaces/topics" => "2021-04-01",
    "Microsoft.ServiceBus/namespaces/topics/subscriptions" => "2021-04-01",
    "Microsoft.Storage/storageAccounts" => "2021-04-01",
    "Microsoft.Storage/storageAccounts/blobServices" => "2021-04-01",
    "Microsoft.Storage/storageAccounts/blobServices/containers" => "2023-05-01",
    "Microsoft.Storage/storageAccounts/blobServices/containers/immutabilityPolicies" => "2023-05-01"
  }

  def admitted_resource_types, do: @admitted_resource_types
  def type_shapes, do: @type_shapes
  def api_versions, do: @api_versions
  def shape_for(type), do: Map.get(@type_shapes, type)
  def latest_version(type), do: Map.get(@api_versions, type)
  def admitted?(type), do: type in @admitted_resource_types
  def control_plane_port, do: 9443
  def data_plane_port, do: 8443
  def amqp_port, do: 5672
  def event_hubs_port, do: 5673
end
