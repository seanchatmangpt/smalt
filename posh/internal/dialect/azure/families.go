// First MOVE families for the v26.10.31 inversion (wave-2 lane 13): the
// declarative route rows for the Azure provider families the wave-1
// digest classifies MOVE. Generic CRUD catch-all, locks, RBAC decision
// engine, tags merge, ResourceGraph, LRO state machine, health STAY core.
//
// RouteOp keys are declared here; ops are admitted by
// RegisterFirstFamilies — an op absent from the registry fails closed at
// Resolve.
package azure

// firstFamilyRoutes returns the ordered route rows for the first MOVE
// families. Order is load-bearing: first-match-in-order.
func firstFamilyRoutes() []Route {
	rows := []Route{}
	add := func(method string, segs []string, family, op string) {
		rows = append(rows, Route{Method: method, Segments: [][]string{segs}, Family: family, RouteOp: op})
	}

	add("*", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Web", "sites", ":site"}, "functions", "azure.functions.site")
	add("*", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.App", "containerApps", ":app"}, "containerapps", "azure.containerapps.app")
	add("*", []string{"acr", ":registry", "v2", "_catalog"}, "acr", "azure.acr.catalog")
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Network", "dnsZones", ":zone"}, "dns", "azure.dns.zone.get")
	add("PUT", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Network", "dnsZones", ":zone"}, "dns", "azure.dns.zone.put")
	add("DELETE", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Network", "dnsZones", ":zone"}, "dns", "azure.dns.zone.delete")
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.EventGrid", "topics", ":topic"}, "eventgrid", "azure.eventgrid.topic.get")
	add("POST", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.EventGrid", "topics", ":topic", "getEvents"}, "eventgrid", "azure.eventgrid.topic.getEvents")
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.KeyVault", "vaults", ":vault"}, "armkv", "azure.armkv.vault.get")
	add("PUT", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.KeyVault", "vaults", ":vault"}, "armkv", "azure.armkv.vault.put")
	add("DELETE", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.KeyVault", "vaults", ":vault"}, "armkv", "azure.armkv.vault.delete")
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Storage", "storageAccounts", ":acct"}, "storage", "azure.storage.account.get")
	add("PUT", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Storage", "storageAccounts", ":acct"}, "storage", "azure.storage.account.put")
	add("DELETE", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Storage", "storageAccounts", ":acct"}, "storage", "azure.storage.account.delete")
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.ServiceBus", "namespaces", ":ns"}, "sbmgmt", "azure.sbmgmt.namespace.get")
	add("PUT", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.ServiceBus", "namespaces", ":ns"}, "sbmgmt", "azure.sbmgmt.namespace.put")
	add("DELETE", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.ServiceBus", "namespaces", ":ns"}, "sbmgmt", "azure.sbmgmt.namespace.delete")
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.EventHub", "namespaces", ":ns"}, "ehmgmt", "azure.ehmgmt.namespace.get")
	add("PUT", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.EventHub", "namespaces", ":ns"}, "ehmgmt", "azure.ehmgmt.namespace.put")
	add("DELETE", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.EventHub", "namespaces", ":ns"}, "ehmgmt", "azure.ehmgmt.namespace.delete")
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.DocumentDB", "databaseAccounts", ":acct"}, "cosmosmgmt", "azure.cosmosmgmt.account.get")
	add("PUT", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.DocumentDB", "databaseAccounts", ":acct"}, "cosmosmgmt", "azure.cosmosmgmt.account.put")
	add("DELETE", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.DocumentDB", "databaseAccounts", ":acct"}, "cosmosmgmt", "azure.cosmosmgmt.account.delete")
	return rows
}
