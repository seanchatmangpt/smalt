defmodule Smalt.AshGen.Registry do
  @moduledoc """
  {provider, type_path} -> {resource_module, api_version} for the projected
  Ash surface. DO NOT EDIT — regenerate with `mix smalt.gen.ash <ontology.ttl>`.
  """

  @mapping %{
    {"Microsoft.Network", "networkManagers/securityUserConfigurations/ruleCollections"} =>
      {Smalt.Network.RuleCollection, "2026-03-01"},
    {"Microsoft.Network", "networkSecurityPerimeters/resourceAssociations"} =>
      {Smalt.Network.ResourceAssociation, "2026-03-01"},
    {"Microsoft.Network", "networkVirtualAppliances/virtualApplianceSites"} =>
      {Smalt.Network.VirtualApplianceSite, "2026-03-01"},
    {"Microsoft.Network", "loadBalancers"} => {Smalt.Network.LoadBalancer, "2026-03-01"},
    {"Microsoft.Network", "loadBalancers/frontendIPConfigurations"} =>
      {Smalt.Network.FrontendIPConfiguration, "2026-03-01"},
    {"Microsoft.Network", "ddosProtectionPlans"} =>
      {Smalt.Network.DdosProtectionPlan, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/securityAdminConfigurations/ruleCollections/rules"} =>
      {Smalt.Network.Rule, "2026-03-01"},
    {"Microsoft.Network", "networkVirtualAppliances"} =>
      {Smalt.Network.NetworkVirtualAppliance, "2026-03-01"},
    {"Microsoft.Network", "routeFilters/routeFilterRules"} =>
      {Smalt.Network.RouteFilterRule, "2026-03-01"},
    {"Microsoft.Network", "loadBalancers/outboundRules"} =>
      {Smalt.Network.OutboundRule, "2026-03-01"},
    {"Microsoft.Network", "frontDoors/rulesEngines"} => {Smalt.Network.RulesEngine, "2026-04-01"},
    {"Microsoft.Network", "vpnServerConfigurations"} =>
      {Smalt.Network.VpnServerConfiguration, "2026-03-01"},
    {"Microsoft.Network", "networkSecurityPerimeters/profiles/accessRules"} =>
      {Smalt.Network.AccessRule, "2026-03-01"},
    {"Microsoft.Network", "networkSecurityPerimeters/loggingConfigurations"} =>
      {Smalt.Network.LoggingConfiguration, "2026-03-01"},
    {"Microsoft.Network", "trafficmanagerprofiles/AzureEndpoints"} =>
      {Smalt.Network.AzureEndpoint, "2026-09-01"},
    {"Microsoft.Network", "networkVirtualAppliances/inboundSecurityRules"} =>
      {Smalt.Network.InboundSecurityRule, "2026-03-01"},
    {"Microsoft.Network", "dnsForwardingRulesets"} =>
      {Smalt.Network.DnsForwardingRuleset, "2025-05-01"},
    {"Microsoft.Network", "expressRoutePorts/authorizations"} =>
      {Smalt.Network.Authorization, "2026-03-01"},
    {"Microsoft.Network", "natGateways"} => {Smalt.Network.NatGateway, "2026-03-01"},
    {"Microsoft.Network", "NetworkExperimentProfiles"} =>
      {Smalt.Network.NetworkExperimentProfile, "2026-04-01"},
    {"Microsoft.Network", "virtualHubs/hubRouteTables"} =>
      {Smalt.Network.HubRouteTable, "2026-03-01"},
    {"Microsoft.Network", "dnsForwardingRulesets/forwardingRules"} =>
      {Smalt.Network.ForwardingRule, "2025-05-01"},
    {"Microsoft.Network", "FrontDoorWebApplicationFirewallPolicies"} =>
      {Smalt.Network.FrontDoorWebApplicationFirewallPolicy, "2026-04-01"},
    {"Microsoft.Network", "expressRouteCircuits/authorizations"} =>
      {Smalt.Network.Authorization, "2026-03-01"},
    {"Microsoft.Network", "azureWebCategories"} => {Smalt.Network.AzureWebCategory, "2026-03-01"},
    {"Microsoft.Network", "authenticationPolicies"} =>
      {Smalt.Network.AuthenticationPolicy, "2026-03-01"},
    {"Microsoft.Network", "dnsResolverPolicies"} =>
      {Smalt.Network.DnsResolverPolicy, "2025-05-01"},
    {"Microsoft.Network", "vpnServerConfigurations/configurationPolicyGroups"} =>
      {Smalt.Network.ConfigurationPolicyGroup, "2026-03-01"},
    {"Microsoft.Network", "virtualRouters"} => {Smalt.Network.VirtualRouter, "2026-03-01"},
    {"Microsoft.Network", "interconnectGroups/subgroups"} =>
      {Smalt.Network.Subgroup, "2026-03-01"},
    {"Microsoft.Network", "ApplicationGatewayWebApplicationFirewallPolicies"} =>
      {Smalt.Network.ApplicationGatewayWebApplicationFirewallPolicy, "2026-03-01"},
    {"Microsoft.Network", "virtualHubs/bgpConnections"} =>
      {Smalt.Network.BgpConnection, "2026-03-01"},
    {"Microsoft.Network", "dnsZones"} => {Smalt.Network.DnsZone, "2018-05-01"},
    {"Microsoft.Network", "privateDnsZones/CNAME"} => {Smalt.Network.CNAME, "2024-06-01"},
    {"Microsoft.Network", "interfaceEndpoints"} =>
      {Smalt.Network.InterfaceEndpoint, "2019-02-01"},
    {"Microsoft.Network", "applicationGateways"} =>
      {Smalt.Network.ApplicationGateway, "2026-03-01"},
    {"Microsoft.Network", "virtualnetworks/subnets"} => {Smalt.Network.Subnet, "2015-06-15"},
    {"Microsoft.Network", "vpnGateways/vpnConnections"} =>
      {Smalt.Network.VpnConnection, "2026-03-01"},
    {"Microsoft.Network", "virtualNetworks/virtualNetworkPeerings"} =>
      {Smalt.Network.VirtualNetworkPeering, "2026-03-01"},
    {"Microsoft.Network", "privateLinkServices/privateEndpointConnections"} =>
      {Smalt.Network.PrivateEndpointConnection, "2026-03-01"},
    {"Microsoft.Network", "networkManagers"} => {Smalt.Network.NetworkManager, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/verifierWorkspaces/reachabilityAnalysisRuns"} =>
      {Smalt.Network.ReachabilityAnalysisRun, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/ipamPools"} => {Smalt.Network.IpamPool, "2026-03-01"},
    {"Microsoft.Network", "privateDnsZones/AAAA"} => {Smalt.Network.AAAA, "2024-06-01"},
    {"Microsoft.Network", "dnsForwardingRulesets/virtualNetworkLinks"} =>
      {Smalt.Network.VirtualNetworkLink, "2025-05-01"},
    {"Microsoft.Network", "interconnectGroups"} =>
      {Smalt.Network.InterconnectGroup, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/networkGroups"} =>
      {Smalt.Network.NetworkGroup, "2026-03-01"},
    {"Microsoft.Network", "virtualNetworkGateways/natRules"} =>
      {Smalt.Network.NatRule, "2026-03-01"},
    {"Microsoft.Network", "privateDnsZones"} => {Smalt.Network.PrivateDnsZone, "2024-06-01"},
    {"Microsoft.Network", "expressRouteCrossConnections/peerings"} =>
      {Smalt.Network.Peering, "2026-03-01"},
    {"Microsoft.Network", "ExpressRoutePorts/links"} => {Smalt.Network.Link, "2025-03-01"},
    {"Microsoft.Network", "privateDnsZones/PTR"} => {Smalt.Network.PTR, "2024-06-01"},
    {"Microsoft.Network", "dnszones/SOA"} => {Smalt.Network.SOA, "2015-05-04-preview"},
    {"Microsoft.Network", "customIpPrefixes"} => {Smalt.Network.CustomIpPrefix, "2026-03-01"},
    {"Microsoft.Network", "networkInterfaces/ipConfigurations"} =>
      {Smalt.Network.IpConfiguration, "2026-03-01"},
    {"Microsoft.Network", "firewallPolicies"} => {Smalt.Network.FirewallPolicy, "2026-03-01"},
    {"Microsoft.Network", "firstPartyServiceTags"} =>
      {Smalt.Network.FirstPartyServiceTag, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/securityUserConfigurations/ruleCollections/rules"} =>
      {Smalt.Network.Rule, "2026-03-01"},
    {"Microsoft.Network", "dnszones/AAAA"} => {Smalt.Network.AAAA, "2015-05-04-preview"},
    {"Microsoft.Network", "networkWatchers/connectionMonitors"} =>
      {Smalt.Network.ConnectionMonitor, "2026-03-01"},
    {"Microsoft.Network", "IpAllocations"} => {Smalt.Network.IpAllocation, "2026-03-01"},
    {"Microsoft.Network", "virtualNetworkTaps"} =>
      {Smalt.Network.VirtualNetworkTap, "2026-03-01"},
    {"Microsoft.Network", "dnsResolverPolicies/dnsSecurityRules"} =>
      {Smalt.Network.DnsSecurityRule, "2025-05-01"},
    {"Microsoft.Network", "frontDoors/frontendEndpoints"} =>
      {Smalt.Network.FrontendEndpoint, "2026-04-01"},
    {"Microsoft.Network", "loadBalancers/backendAddressPools"} =>
      {Smalt.Network.BackendAddressPool, "2026-03-01"},
    {"Microsoft.Network", "routeTables"} => {Smalt.Network.RouteTable, "2026-03-01"},
    {"Microsoft.Network", "trafficmanagerprofiles/ExternalEndpoints"} =>
      {Smalt.Network.ExternalEndpoint, "2026-09-01"},
    {"Microsoft.Network", "privateTrafficManagerProfiles"} =>
      {Smalt.Network.PrivateTrafficManagerProfile, "2026-10-01-preview"},
    {"Microsoft.Network", "ipGroups"} => {Smalt.Network.IpGroup, "2026-03-01"},
    {"Microsoft.Network", "firewallPolicies/ruleCollectionGroups/ruleCollectionGroupDrafts"} =>
      {Smalt.Network.RuleCollectionGroupDraft, "2026-03-01"},
    {"Microsoft.Network", "firewallPolicies/signatureOverrides"} =>
      {Smalt.Network.SignatureOverride, "2026-03-01"},
    {"Microsoft.Network", "applicationGateways/privateEndpointConnections"} =>
      {Smalt.Network.PrivateEndpointConnection, "2026-03-01"},
    {"Microsoft.Network", "dnsResolvers/outboundEndpoints"} =>
      {Smalt.Network.OutboundEndpoint, "2025-05-01"},
    {"Microsoft.Network", "applicationGatewayAvailableSslOptions"} =>
      {Smalt.Network.ApplicationGatewayAvailableSslOption, "2026-03-01"},
    {"Microsoft.Network", "privateEndpoints"} => {Smalt.Network.PrivateEndpoint, "2026-03-01"},
    {"Microsoft.Network", "networkManagerConnections"} =>
      {Smalt.Network.NetworkManagerConnection, "2026-03-01"},
    {"Microsoft.Network", "privateDnsZones/A"} => {Smalt.Network.A, "2024-06-01"},
    {"Microsoft.Network", "vpnGateways/natRules"} => {Smalt.Network.NatRule, "2026-03-01"},
    {"Microsoft.Network", "NetworkExperimentProfiles/Experiments"} =>
      {Smalt.Network.Experiment, "2026-04-01"},
    {"Microsoft.Network", "expressRouteCircuits/peerings/peerConnections"} =>
      {Smalt.Network.PeerConnection, "2026-03-01"},
    {"Microsoft.Network", "dnsZones/DS"} => {Smalt.Network.DS, "2023-07-01-preview"},
    {"Microsoft.Network", "virtualRouters/peerings"} => {Smalt.Network.Peering, "2026-03-01"},
    {"Microsoft.Network", "dnsZones/dnssecConfigs"} =>
      {Smalt.Network.DnssecConfig, "2023-07-01-preview"},
    {"Microsoft.Network", "dnsResolverPolicies/virtualNetworkLinks"} =>
      {Smalt.Network.VirtualNetworkLink, "2025-05-01"},
    {"Microsoft.Network", "networkSecurityPerimeters/links"} =>
      {Smalt.Network.Link, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/routingConfigurations/ruleCollections/rules"} =>
      {Smalt.Network.Rule, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/verifierWorkspaces"} =>
      {Smalt.Network.VerifierWorkspace, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/securityAdminConfigurations/ruleCollections"} =>
      {Smalt.Network.RuleCollection, "2026-03-01"},
    {"Microsoft.Network", "serviceGateways"} => {Smalt.Network.ServiceGateway, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/ipamPools/staticCidrs"} =>
      {Smalt.Network.StaticCidr, "2026-03-01"},
    {"Microsoft.Network", "vpnGateways"} => {Smalt.Network.VpnGateway, "2026-03-01"},
    {"Microsoft.Network", "privateDnsZones/TXT"} => {Smalt.Network.TXT, "2024-06-01"},
    {"Microsoft.Network", "networkManagers/routingConfigurations/ruleCollections"} =>
      {Smalt.Network.RuleCollection, "2026-03-01"},
    {"Microsoft.Network", "virtualHubs/hubVirtualNetworkConnections"} =>
      {Smalt.Network.HubVirtualNetworkConnection, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/securityAdminConfigurations"} =>
      {Smalt.Network.SecurityAdminConfiguration, "2026-03-01"},
    {"Microsoft.Network", "networkWatchers/connectionAnalyzers"} =>
      {Smalt.Network.ConnectionAnalyzer, "2026-03-01"},
    {"Microsoft.Network", "securityPartnerProviders"} =>
      {Smalt.Network.SecurityPartnerProvider, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/commits"} => {Smalt.Network.Commit, "2026-03-01"},
    {"Microsoft.Network", "privateDnsZones/MX"} => {Smalt.Network.MX, "2024-06-01"},
    {"Microsoft.Network", "routeFilters"} => {Smalt.Network.RouteFilter, "2026-03-01"},
    {"Microsoft.Network", "serviceEndpointPolicies"} =>
      {Smalt.Network.ServiceEndpointPolicy, "2026-03-01"},
    {"Microsoft.Network", "trafficmanagerprofiles/NestedEndpoints"} =>
      {Smalt.Network.NestedEndpoint, "2026-09-01"},
    {"Microsoft.Network", "firewallPolicies/kubeSelectorGroups"} =>
      {Smalt.Network.KubeSelectorGroup, "2026-03-01"},
    {"Microsoft.Network", "privateTrafficManagerProfiles/endpoints"} =>
      {Smalt.Network.Endpoint, "2026-10-01-preview"},
    {"Microsoft.Network", "privateDnsZones/virtualNetworkLinks"} =>
      {Smalt.Network.VirtualNetworkLink, "2024-06-01"},
    {"Microsoft.Network", "vpnGateways/vpnConnections/vpnLinkConnections"} =>
      {Smalt.Network.VpnLinkConnection, "2026-03-01"},
    {"Microsoft.Network", "localNetworkGateways"} =>
      {Smalt.Network.LocalNetworkGateway, "2026-03-01"},
    {"Microsoft.Network", "locations/applicationGatewayWafDynamicManifests"} =>
      {Smalt.Network.ApplicationGatewayWafDynamicManifest, "2026-03-01"},
    {"Microsoft.Network", "expressRouteGateways/expressRouteConnections"} =>
      {Smalt.Network.ExpressRouteConnection, "2026-03-01"},
    {"Microsoft.Network", "trafficmanagerprofiles"} =>
      {Smalt.Network.Trafficmanagerprofile, "2026-09-01"},
    {"Microsoft.Network", "cloudServiceSlots"} => {Smalt.Network.CloudServiceSlot, "2026-03-01"},
    {"Microsoft.Network", "virtualWans"} => {Smalt.Network.VirtualWan, "2026-03-01"},
    {"Microsoft.Network", "dnsZones/TLSA"} => {Smalt.Network.TLSA, "2023-07-01-preview"},
    {"Microsoft.Network", "expressRouteLags/authorizations"} =>
      {Smalt.Network.Authorization, "2026-03-01"},
    {"Microsoft.Network", "dnsResolvers"} => {Smalt.Network.DnsResolver, "2025-05-01"},
    {"Microsoft.Network", "trafficManagerUserMetricsKeys"} =>
      {Smalt.Network.TrafficManagerUserMetricsKey, "2026-09-01"},
    {"Microsoft.Network", "applicationSecurityGroups"} =>
      {Smalt.Network.ApplicationSecurityGroup, "2026-03-01"},
    {"Microsoft.Network", "privateDnsZones/SOA"} => {Smalt.Network.SOA, "2024-06-01"},
    {"Microsoft.Network", "networkSecurityGroups"} =>
      {Smalt.Network.NetworkSecurityGroup, "2026-03-01"},
    {"Microsoft.Network", "expressRouteCircuits/peerings/connections"} =>
      {Smalt.Network.Connection, "2026-03-01"},
    {"Microsoft.Network", "networkSecurityPerimeters/profiles"} =>
      {Smalt.Network.Profile, "2026-03-01"},
    {"Microsoft.Network", "ExpressRoutePortsLocations"} =>
      {Smalt.Network.ExpressRoutePortsLocation, "2026-03-01"},
    {"Microsoft.Network", "expressRouteLags"} => {Smalt.Network.ExpressRouteLag, "2026-03-01"},
    {"Microsoft.Network", "privateTrafficManagerProfiles/healthPolicies"} =>
      {Smalt.Network.HealthPolicy, "2026-10-01-preview"},
    {"Microsoft.Network", "applicationSecurityGroups/addressPrefixSets"} =>
      {Smalt.Network.AddressPrefixSet, "2026-03-01"},
    {"Microsoft.Network", "virtualHubs/ipConfigurations"} =>
      {Smalt.Network.IpConfiguration, "2026-03-01"},
    {"Microsoft.Network", "publicIPPrefixes"} => {Smalt.Network.PublicIPPrefix, "2026-03-01"},
    {"Microsoft.Network", "expressRouteProviderPorts"} =>
      {Smalt.Network.ExpressRouteProviderPort, "2026-03-01"},
    {"Microsoft.Network", "virtualNetworks/subnets"} => {Smalt.Network.Subnet, "2026-03-01"},
    {"Microsoft.Network", "expressRouteCrossConnections"} =>
      {Smalt.Network.ExpressRouteCrossConnection, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/connectivityConfigurations"} =>
      {Smalt.Network.ConnectivityConfiguration, "2026-03-01"},
    {"Microsoft.Network", "networkSecurityPerimeters"} =>
      {Smalt.Network.NetworkSecurityPerimeter, "2026-03-01"},
    {"Microsoft.Network", "firewallPolicies/firewallPolicyDrafts"} =>
      {Smalt.Network.FirewallPolicyDraft, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/scopeConnections"} =>
      {Smalt.Network.ScopeConnection, "2026-03-01"},
    {"Microsoft.Network", "expressRouteGateways"} =>
      {Smalt.Network.ExpressRouteGateway, "2026-03-01"},
    {"Microsoft.Network", "serviceEndpointPolicies/serviceEndpointPolicyDefinitions"} =>
      {Smalt.Network.ServiceEndpointPolicyDefinition, "2026-03-01"},
    {"Microsoft.Network", "virtualHubs/routeTables"} => {Smalt.Network.RouteTable, "2026-03-01"},
    {"Microsoft.Network", "publicIPAddresses"} => {Smalt.Network.PublicIPAddresse, "2026-03-01"},
    {"Microsoft.Network", "virtualNetworkAppliances/capabilities"} =>
      {Smalt.Network.Capability, "2026-03-01"},
    {"Microsoft.Network", "azureFirewalls"} => {Smalt.Network.AzureFirewall, "2026-03-01"},
    {"Microsoft.Network", "vpnGateways/vpnConnections/vpnLinkConnections/sharedKeys"} =>
      {Smalt.Network.SharedKey, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/networkGroups/staticMembers"} =>
      {Smalt.Network.StaticMember, "2026-03-01"},
    {"Microsoft.Network", "networkSecurityGroups/securityRules"} =>
      {Smalt.Network.SecurityRule, "2026-03-01"},
    {"Microsoft.Network", "dnszones/TXT"} => {Smalt.Network.TXT, "2015-05-04-preview"},
    {"Microsoft.Network", "networkWatchers/flowLogs"} => {Smalt.Network.FlowLog, "2026-03-01"},
    {"Microsoft.Network", "privateLinkServices"} =>
      {Smalt.Network.PrivateLinkService, "2026-03-01"},
    {"Microsoft.Network", "firewallPolicies/ruleCollectionGroups"} =>
      {Smalt.Network.RuleCollectionGroup, "2026-03-01"},
    {"Microsoft.Network", "frontDoors"} => {Smalt.Network.FrontDoor, "2026-04-01"},
    {"Microsoft.Network", "dnsZones/CAA"} => {Smalt.Network.CAA, "2018-05-01"},
    {"Microsoft.Network", "virtualHubs/connectionPolicies"} =>
      {Smalt.Network.ConnectionPolicy, "2026-03-01"},
    {"Microsoft.Network", "virtualNetworkAppliances"} =>
      {Smalt.Network.VirtualNetworkAppliance, "2026-03-01"},
    {"Microsoft.Network", "virtualNetworks"} => {Smalt.Network.VirtualNetwork, "2026-03-01"},
    {"Microsoft.Network", "dnszones/MX"} => {Smalt.Network.MX, "2015-05-04-preview"},
    {"Microsoft.Network", "networkProfiles"} => {Smalt.Network.NetworkProfile, "2026-03-01"},
    {"Microsoft.Network", "networkSecurityPerimeters/linkReferences"} =>
      {Smalt.Network.LinkReference, "2026-03-01"},
    {"Microsoft.Network", "dnsResolverDomainLists"} =>
      {Smalt.Network.DnsResolverDomainList, "2025-05-01"},
    {"Microsoft.Network", "dnsZones/NAPTR"} => {Smalt.Network.NAPTR, "2023-07-01-preview"},
    {"Microsoft.Network", "networkVirtualApplianceSkus"} =>
      {Smalt.Network.NetworkVirtualApplianceSku, "2026-03-01"},
    {"Microsoft.Network", "topologyMaps/sites"} => {Smalt.Network.Site, "2026-10-01-preview"},
    {"Microsoft.Network", "networkManagers/securityUserConfigurations"} =>
      {Smalt.Network.SecurityUserConfiguration, "2026-03-01"},
    {"Microsoft.Network", "dnsResolvers/inboundEndpoints"} =>
      {Smalt.Network.InboundEndpoint, "2025-05-01"},
    {"Microsoft.Network", "dnszones/PTR"} => {Smalt.Network.PTR, "2015-05-04-preview"},
    {"Microsoft.Network", "topologyMaps"} => {Smalt.Network.TopologyMap, "2026-10-01-preview"},
    {"Microsoft.Network", "firewallPolicies/ruleGroups"} =>
      {Smalt.Network.RuleGroup, "2020-04-01"},
    {"Microsoft.Network", "dnszones/SRV"} => {Smalt.Network.SRV, "2015-05-04-preview"},
    {"Microsoft.Network", "privateEndpoints/privateDnsZoneGroups"} =>
      {Smalt.Network.PrivateDnsZoneGroup, "2026-03-01"},
    {"Microsoft.Network", "managementGroups/networkManagerConnections"} =>
      {Smalt.Network.NetworkManagerConnection, "2021-05-01-preview"},
    {"Microsoft.Network", "connections"} => {Smalt.Network.Connection, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/verifierWorkspaces/reachabilityAnalysisIntents"} =>
      {Smalt.Network.ReachabilityAnalysisIntent, "2026-03-01"},
    {"Microsoft.Network", "networkManagers/routingConfigurations"} =>
      {Smalt.Network.RoutingConfiguration, "2026-03-01"},
    {"Microsoft.Network", "networkWatchers/packetCaptures"} =>
      {Smalt.Network.PacketCapture, "2026-03-01"},
    {"Microsoft.Network", "networkSecurityGroups/defaultSecurityRules"} =>
      {Smalt.Network.DefaultSecurityRule, "2026-03-01"},
    {"Microsoft.Network", "networkInterfaces/tapConfigurations"} =>
      {Smalt.Network.TapConfiguration, "2026-03-01"},
    {"Microsoft.Network", "dnszones/NS"} => {Smalt.Network.NS, "2015-05-04-preview"},
    {"Microsoft.Network", "networkVirtualAppliances/networkVirtualApplianceConnections"} =>
      {Smalt.Network.NetworkVirtualApplianceConnection, "2026-03-01"},
    {"Microsoft.Network", "dnszones/A"} => {Smalt.Network.A, "2015-05-04-preview"},
    {"Microsoft.Network", "trafficManagerGeographicHierarchies"} =>
      {Smalt.Network.TrafficManagerGeographicHierarchy, "2026-09-01"},
    {"Microsoft.Network", "virtualHubs/routingIntent"} =>
      {Smalt.Network.RoutingIntent, "2026-03-01"},
    {"Microsoft.Network", "trafficmanagerprofiles/heatMaps"} =>
      {Smalt.Network.HeatMap, "2026-09-01"},
    {"Microsoft.Network", "p2svpnGateways"} => {Smalt.Network.P2svpnGateway, "2026-03-01"},
    {"Microsoft.Network", "privateTrafficManagerProfiles/probingGateways"} =>
      {Smalt.Network.ProbingGateway, "2026-02-09-preview"},
    {"Microsoft.Network", "privateDnsZones/SRV"} => {Smalt.Network.SRV, "2024-06-01"},
    {"Microsoft.Network", "vpnSites"} => {Smalt.Network.VpnSite, "2026-03-01"},
    {"Microsoft.Network", "loadBalancers/inboundNatRules"} =>
      {Smalt.Network.InboundNatRule, "2026-03-01"},
    {"Microsoft.Network", "expressRouteCircuits"} =>
      {Smalt.Network.ExpressRouteCircuit, "2026-03-01"},
    {"Microsoft.Network", "vpnSites/vpnSiteLinks"} => {Smalt.Network.VpnSiteLink, "2026-03-01"},
    {"Microsoft.Network", "ExpressRoutePorts"} => {Smalt.Network.ExpressRoutePort, "2026-03-01"},
    {"Microsoft.Network", "virtualNetworkGateways"} =>
      {Smalt.Network.VirtualNetworkGateway, "2026-03-01"},
    {"Microsoft.Network", "dscpConfigurations"} =>
      {Smalt.Network.DscpConfiguration, "2026-03-01"},
    {"Microsoft.Network", "expressRouteCircuits/peerings"} =>
      {Smalt.Network.Peering, "2026-03-01"},
    {"Microsoft.Network", "networkInterfaces"} => {Smalt.Network.NetworkInterface, "2026-03-01"},
    {"Microsoft.Network", "bastionHosts"} => {Smalt.Network.BastionHost, "2026-03-01"},
    {"Microsoft.Network", "ddosCustomPolicies"} => {Smalt.Network.DdosCustomPolicy, "2026-03-01"},
    {"Microsoft.Network", "applicationGatewayAvailableSslOptions/predefinedPolicies"} =>
      {Smalt.Network.PredefinedPolicy, "2025-03-01"},
    {"Microsoft.Network", "networkWatchers"} => {Smalt.Network.NetworkWatcher, "2026-03-01"},
    {"Microsoft.Network", "dnszones/CNAME"} => {Smalt.Network.CNAME, "2015-05-04-preview"},
    {"Microsoft.Network", "loadBalancers/probes"} => {Smalt.Network.Probe, "2026-03-01"},
    {"Microsoft.Network", "loadBalancers/loadBalancingRules"} =>
      {Smalt.Network.LoadBalancingRule, "2026-03-01"},
    {"Microsoft.Network", "virtualHubs"} => {Smalt.Network.VirtualHub, "2026-03-01"},
    {"Microsoft.Network", "virtualWans/p2sVpnServerConfigurations"} =>
      {Smalt.Network.P2sVpnServerConfiguration, "2019-07-01"},
    {"Microsoft.Network", "virtualHubs/routeMaps"} => {Smalt.Network.RouteMap, "2026-03-01"},
    {"Microsoft.Network", "routeTables/routes"} => {Smalt.Network.Route, "2026-03-01"}
  }

  @spec lookup(String.t(), String.t()) :: {module(), String.t()} | nil
  def lookup(provider, type_path) do
    Map.get(@mapping, {provider, type_path})
  end

  @spec entries() :: map()
  def entries, do: @mapping
end
