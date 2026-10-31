package azure_test

import (
	"testing"

	"github.com/stretchr/testify/require"

	"smalt.dev/posh/internal/dialect/azure"
)

func TestDialect_ServiceBusWireTransforms(t *testing.T) {
	t.Parallel()

	// 1. Test BrokerProperties parsing
	validJSON := `{"MessageId":"msg-123","PartitionKey":"pk-1","SessionId":"sess-456"}`
	bp, err := azure.ParseBrokerProperties(validJSON)
	require.NoError(t, err)
	require.Equal(t, "msg-123", bp.MessageID)
	require.Equal(t, "pk-1", bp.PartitionKey)
	require.Equal(t, "sess-456", bp.SessionID)

	emptyBP, err := azure.ParseBrokerProperties("")
	require.NoError(t, err)
	require.Empty(t, emptyBP.MessageID)

	_, errInvalid := azure.ParseBrokerProperties("not-json")
	require.Error(t, errInvalid)

	// 2. Test encoding validation
	require.True(t, azure.ValidateBrokeredEncoding("application/atom+xml"))
	require.True(t, azure.ValidateBrokeredEncoding("application/xml"))
	require.True(t, azure.ValidateBrokeredEncoding(""))
	require.False(t, azure.ValidateBrokeredEncoding("application/json"))
	require.False(t, azure.ValidateBrokeredEncoding("text/plain"))
}

func TestDialect_EventHubsPartitionKeyPinion(t *testing.T) {
	t.Parallel()

	// Pinion must compute deterministic 0 or 1 partition
	p1 := azure.EventHubsPartitionKeyPinion("test-key-alpha")
	require.Contains(t, []string{"0", "1"}, p1)

	p2 := azure.EventHubsPartitionKeyPinion("test-key-alpha")
	require.Equal(t, p1, p2, "partition key pinion must be deterministic")

	p3 := azure.EventHubsPartitionKeyPinion("test-key-beta")
	require.Contains(t, []string{"0", "1"}, p3)
}

func TestDialect_CosmosPartitionKeyHeader(t *testing.T) {
	t.Parallel()

	pks, err := azure.ParseCosmosPartitionKey(`["tenant-123"]`)
	require.NoError(t, err)
	require.Equal(t, []string{"tenant-123"}, pks)

	pksCompound, err := azure.ParseCosmosPartitionKey(`["tenant-123", "matter-456"]`)
	require.NoError(t, err)
	require.Equal(t, []string{"tenant-123", "matter-456"}, pksCompound)

	_, errInvalid := azure.ParseCosmosPartitionKey(`not-an-array`)
	require.Error(t, errInvalid)
}

func TestDialect_ACILogsRefusal(t *testing.T) {
	t.Parallel()

	status, errMap := azure.RefuseACILogs()
	require.Equal(t, 400, status)
	errObj, ok := errMap["error"].(map[string]any)
	require.True(t, ok)
	require.Equal(t, "NotSupportedOnSubstrate", errObj["code"])
}

func TestDialect_ExtendedRouteResolution(t *testing.T) {
	t.Parallel()

	reg := azure.NewRegistry()
	azure.RegisterFirstFamilies(reg)

	fam, err := azure.NewFamilies(reg, azure.FirstFamilyRoutes())
	require.NoError(t, err)

	// Test direct route resolution over the registry
	route, ok := fam.ResolveRoute("POST", "/testns/orders/messages")
	require.True(t, ok)
	require.Equal(t, "sbdata", route.Family)
	require.Equal(t, "azure.sbdata.send", route.RouteOp)

	ehRoute, ok := fam.ResolveRoute("POST", "/auditevents/messages")
	require.True(t, ok)
	require.Equal(t, "ehdata", ehRoute.Family)
	require.Equal(t, "azure.ehdata.send", ehRoute.RouteOp)

	cosmosRoute, ok := fam.ResolveRoute("GET", "/dbs/courtroom/colls/matters/docs")
	require.True(t, ok)
	require.Equal(t, "cosmosdata", cosmosRoute.Family)
	require.Equal(t, "azure.cosmosdata.docs.list", cosmosRoute.RouteOp)

	aciRoute, ok := fam.ResolveRoute("GET", "/subscriptions/sub-1/resourcegroups/rg-1/providers/Microsoft.ContainerInstance/containerGroups/aci-1/containers/c1/logs")
	require.True(t, ok)
	require.Equal(t, "aci", aciRoute.Family)
	require.Equal(t, "azure.aci.group.logs", aciRoute.RouteOp)
}
