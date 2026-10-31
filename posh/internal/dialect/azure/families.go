// First MOVE families for the v26.10.31 inversion (wave-2 lane 13): the
// declarative route rows for the Azure provider families the wave-1
// digest classifies MOVE. Generic CRUD catch-all, locks, RBAC decision
// engine, tags merge, ResourceGraph, LRO state machine, health STAY core.
//
// RouteOp keys are declared here; ops are admitted by
// RegisterFirstFamilies — an op absent from the registry fails closed at
// Resolve.
package azure

// FirstFamilyRoutes returns the ordered route rows for the first MOVE
// families. Order is load-bearing: first-match-in-order.
func FirstFamilyRoutes() []Route {
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

	// --- ACI ContainerGroups & Child Routes ---
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.ContainerInstance", "containerGroups"}, "aci", "azure.aci.group.list")
	add("GET", []string{"subscriptions", ":sub", "providers", "Microsoft.ContainerInstance", "containerGroups"}, "aci", "azure.aci.group.listsub")
	add("*", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.ContainerInstance", "containerGroups", ":name"}, "aci", "azure.aci.group.item")
	add("GET", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.ContainerInstance", "containerGroups", ":name", "containers", ":container", "logs"}, "aci", "azure.aci.group.logs")

	// --- Functions & Sites Child Routes ---
	add("*", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Web", "sites", ":site", "config", "appSettings"}, "functions", "azure.functions.appsettings")
	add("POST", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Web", "sites", ":site", "listHostKeys"}, "functions", "azure.functions.listhostkeys")
	add("POST", []string{"subscriptions", ":sub", "resourcegroups", ":rg", "providers", "Microsoft.Web", "sites", ":site", "functions", ":fn", "listFunctionKeys"}, "functions", "azure.functions.listfunctionkeys")

	// --- Service Bus REST Data Plane ---
	add("POST", []string{":ns", ":queue", "messages"}, "sbdata", "azure.sbdata.send")
	add("POST", []string{":ns", ":queue", "messages", "head"}, "sbdata", "azure.sbdata.peeklock")
	add("DELETE", []string{":ns", ":queue", "messages", "head"}, "sbdata", "azure.sbdata.receive_delete")
	add("DELETE", []string{":ns", ":queue", "messages", ":seq", ":locktoken"}, "sbdata", "azure.sbdata.complete")
	add("PUT", []string{":ns", ":queue", "messages", ":seq", ":locktoken"}, "sbdata", "azure.sbdata.unlock")
	add("POST", []string{":ns", ":queue", "messages", ":seq", ":locktoken"}, "sbdata", "azure.sbdata.renew")

	// --- Event Hubs REST Data Plane ---
	add("POST", []string{":hub", "messages"}, "ehdata", "azure.ehdata.send")

	// --- Cosmos DB NoSQL Data Plane (/dbs...) ---
	add("GET", []string{"dbs"}, "cosmosdata", "azure.cosmosdata.dbs.list")
	add("POST", []string{"dbs"}, "cosmosdata", "azure.cosmosdata.dbs.create")
	add("GET", []string{"dbs", ":db"}, "cosmosdata", "azure.cosmosdata.dbs.get")
	add("DELETE", []string{"dbs", ":db"}, "cosmosdata", "azure.cosmosdata.dbs.delete")
	add("GET", []string{"dbs", ":db", "colls"}, "cosmosdata", "azure.cosmosdata.colls.list")
	add("POST", []string{"dbs", ":db", "colls"}, "cosmosdata", "azure.cosmosdata.colls.create")
	add("DELETE", []string{"dbs", ":db", "colls", ":coll"}, "cosmosdata", "azure.cosmosdata.colls.delete")
	add("GET", []string{"dbs", ":db", "colls", ":coll", "docs"}, "cosmosdata", "azure.cosmosdata.docs.list")
	add("POST", []string{"dbs", ":db", "colls", ":coll", "docs"}, "cosmosdata", "azure.cosmosdata.docs.create")
	add("GET", []string{"dbs", ":db", "colls", ":coll", "docs", ":doc"}, "cosmosdata", "azure.cosmosdata.docs.get")
	add("PUT", []string{"dbs", ":db", "colls", ":coll", "docs", ":doc"}, "cosmosdata", "azure.cosmosdata.docs.replace")
	add("DELETE", []string{"dbs", ":db", "colls", ":coll", "docs", ":doc"}, "cosmosdata", "azure.cosmosdata.docs.delete")

	// --- App Configuration REST Data Plane (/kv...) ---
	add("GET", []string{"kv"}, "appconfigdata", "azure.appconfigdata.kv.list")
	add("GET", []string{"kv", ":key"}, "appconfigdata", "azure.appconfigdata.kv.get")
	add("PUT", []string{"kv", ":key"}, "appconfigdata", "azure.appconfigdata.kv.set")
	add("DELETE", []string{"kv", ":key"}, "appconfigdata", "azure.appconfigdata.kv.delete")
	return rows
}
