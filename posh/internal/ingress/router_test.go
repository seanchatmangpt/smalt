package ingress_test

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/stretchr/testify/require"
	"smalt.dev/posh/internal/ingress"
)

func TestRouter_StaticRoutes_CaseInsensitive(t *testing.T) {
	t.Parallel()
	r := ingress.NewRouter()

	called := false
	r.RegisterStatic("/metadata/endpoints", func(w http.ResponseWriter, req *http.Request, id *ingress.ARMResourceID) {
		called = true
		w.WriteHeader(http.StatusOK)
	})

	// Match exact
	h, id, ok := r.Match("/metadata/endpoints")
	require.True(t, ok)
	require.NotNil(t, h)
	require.Equal(t, "/metadata/endpoints", id.Raw)

	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/metadata/endpoints", nil)
	h(rec, req, id)
	require.True(t, called)

	// Match mixed case
	h2, _, ok2 := r.Match("/METADATA/EndPoints")
	require.True(t, ok2)
	require.NotNil(t, h2)
}

func TestRouter_ParameterizedARMRoute(t *testing.T) {
	t.Parallel()
	r := ingress.NewRouter()

	r.Register("/subscriptions/:sub/resourceGroups/:rg/providers/:provider/:type/:name",
		func(w http.ResponseWriter, req *http.Request, id *ingress.ARMResourceID) {
			w.WriteHeader(http.StatusOK)
		})

	path := "/subscriptions/1111-2222/resourcegroups/my-rg/providers/Microsoft.Storage/storageAccounts/sa101"
	h, id, ok := r.Match(path)
	require.True(t, ok)
	require.NotNil(t, h)
	require.Equal(t, "1111-2222", id.SubscriptionID)
	require.Equal(t, "my-rg", id.ResourceGroupName)
	require.Equal(t, "Microsoft.Storage", id.ProviderNamespace)
	require.Equal(t, "storageAccounts", id.ResourceType)
	require.Equal(t, "sa101", id.ResourceName)
}

func TestParseARMResourceID_Direct(t *testing.T) {
	t.Parallel()

	path := "/subscriptions/sub-123/resourceGroups/rg-abc/providers/Microsoft.App/containerApps/app-1/listSecrets"
	id, err := ingress.ParseARMResourceID(path)
	require.NoError(t, err)
	require.Equal(t, "sub-123", id.SubscriptionID)
	require.Equal(t, "rg-abc", id.ResourceGroupName)
	require.Equal(t, "Microsoft.App", id.ProviderNamespace)
	require.Equal(t, "containerApps", id.ResourceType)
	require.Equal(t, "app-1", id.ResourceName)
	require.Equal(t, "listSecrets", id.Action)
	require.True(t, id.IsOperation)
}
