package provider

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// Live CRUD against the smalt substrate at http://127.0.0.1:9443,
// guarded by TFPOSHT_LIVE=1. Real collaborators, real state assertions.
func TestLiveResourceGroupRoundtrip(t *testing.T) {
	if os.Getenv("TFPOSHT_LIVE") != "1" {
		t.Skip("live test: set TFPOSHT_LIVE=1")
	}
	ctx := context.Background()
	c, err := NewClient(ctx, "http://127.0.0.1:9443", "00000000-0000-0000-0000-000000000000", "", "", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	name := "rg-poshl2"

	if err := c.DeleteResourceGroup(ctx, name); err != nil {
		t.Logf("pre-clean delete: %v (ok if absent)", err)
	}

	created, err := c.PutResourceGroup(ctx, name, "eastus", map[string]string{"posh": "l2"})
	if err != nil {
		t.Fatalf("PUT: %v", err)
	}
	if created.Name != name || created.Location != "eastus" {
		t.Fatalf("PUT body: name=%q location=%q", created.Name, created.Location)
	}

	got, err := c.GetResourceGroup(ctx, name)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	if got == nil {
		t.Fatalf("GET returned nil after PUT")
	}
	if got.Tags["posh"] != "l2" {
		t.Fatalf("GET tags = %v, want posh=l2", got.Tags)
	}

	if err := c.DeleteResourceGroup(ctx, name); err != nil {
		t.Fatalf("DELETE: %v", err)
	}
	after, err := c.GetResourceGroup(ctx, name)
	if err != nil {
		t.Fatalf("GET after delete: %v", err)
	}
	if after != nil {
		t.Fatalf("resource group %s still present after DELETE", name)
	}
}

// TestLiveUserAssignedIdentityRoundtrip drives the real smalt ARM face:
// PUT/GET/DELETE on Microsoft.ManagedIdentity/userAssignedIdentities
// (api-version 2023-04-01), unique f5-* name per run. Asserts real state:
// 201/200 on PUT, GET returns the record, DELETE removes it (404 after).
// Honest-partial law: the face record carries no clientId/principalId, so
// those computed attrs are state-carried (asserted absent from the wire).
func TestLiveUserAssignedIdentityRoundtrip(t *testing.T) {
	if os.Getenv("TFPOSHT_LIVE") != "1" {
		t.Skip("live test: set TFPOSHT_LIVE=1")
	}
	ctx := context.Background()
	c, err := NewClient(ctx, "http://127.0.0.1:9443", "00000000-0000-0000-0000-000000000000", "", "", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	name := fmt.Sprintf("f5-uai-%d", time.Now().UnixNano())
	rg := "rg-poshl2"
	armPath := uaiARMPath(c.subscriptionID, rg, name)

	defer func() {
		if _, derr := c.DeleteRaw(ctx, armPath, uaiAPIVersion); derr != nil {
			t.Logf("cleanup delete: %v", derr)
		}
	}()

	body := map[string]any{
		"location":   "eastus",
		"tags":       map[string]string{"lane": "f5"},
		"properties": map[string]any{},
	}
	var out map[string]any
	if _, _, status, err := c.PutWithETag(ctx, armPath, uaiAPIVersion, "", body, &out); err != nil {
		t.Fatalf("PUT: %v", err)
	} else if status != http.StatusOK && status != http.StatusCreated {
		t.Fatalf("PUT status = %d, want 200/201", status)
	}
	if props, _ := out["properties"].(map[string]any); mapStringField(props, "clientId") != "" || mapStringField(props, "principalId") != "" {
		t.Fatalf("face unexpectedly returned clientId/principalId; honest-partial premise invalidated")
	}

	var got map[string]any
	if _, _, status, err := c.GetRaw(ctx, armPath, uaiAPIVersion, &got); err != nil || status != http.StatusOK {
		t.Fatalf("GET: status=%d err=%v", status, err)
	}
	if got["name"] != name {
		t.Fatalf("GET name = %v, want %q", got["name"], name)
	}
	if mapTagsField(got)["lane"] != "f5" {
		t.Fatalf("GET tags = %v, want lane=f5", got["tags"])
	}

	if status, err := c.DeleteRaw(ctx, armPath, uaiAPIVersion); err != nil {
		t.Fatalf("DELETE: %v", err)
	} else if status != http.StatusOK && status != http.StatusAccepted && status != http.StatusNotFound {
		t.Fatalf("DELETE status = %d", status)
	}
	// 202 Accepted is async delete: bounded poll on the real observable
	// (GET 404), never a fixed sleep.
	deleted := false
	for i := 0; i < 60; i++ {
		_, _, st, gerr := c.GetRaw(ctx, armPath, uaiAPIVersion, &got)
		if IsNotFound(gerr) {
			deleted = true
			break
		}
		if gerr != nil || (st != http.StatusOK && st != http.StatusAccepted && st != http.StatusNotFound) {
			t.Fatalf("GET after DELETE: status=%d err=%v", st, gerr)
		}
		time.Sleep(500 * time.Millisecond)
	}
	if !deleted {
		t.Fatalf("UAI %s still GET-able 30s after DELETE", name)
	}
}

// TestLiveRoleAssignmentRoundtrip drives the real smalt ARM face:
// PUT/GET/DELETE on Microsoft.Authorization/roleAssignments
// (api-version 2022-04-01), unique f5-* name per run. role_definition_id
// arrives as a bare name ("Reader") and must resolve through the
// deterministic mint_definition_guid funnel (bare-name input, not UUID).
func TestLiveRoleAssignmentRoundtrip(t *testing.T) {
	if os.Getenv("TFPOSHT_LIVE") != "1" {
		t.Skip("live test: set TFPOSHT_LIVE=1")
	}
	ctx := context.Background()
	c, err := NewClient(ctx, "http://127.0.0.1:9443", "00000000-0000-0000-0000-000000000000", "", "", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	name := fmt.Sprintf("f5-ra-%d", time.Now().UnixNano())
	scope := fmt.Sprintf("/subscriptions/%s", c.subscriptionID)
	rdID := resolveRoleDefinitionInput(scope, "", "Reader", nil)
	armPath := roleAssignmentARMPath(scope, name)

	defer func() {
		if _, derr := c.DeleteRaw(ctx, NormalizeARMID(armPath), roleAssignAPIVersion); derr != nil {
			t.Logf("cleanup delete: %v", derr)
		}
	}()

	if !strings.Contains(rdID, mintDeterministicGUID("Reader|"+scope)) {
		t.Fatalf("bare name %q did not resolve via mint_definition_guid funnel: %s", "Reader", rdID)
	}

	body := map[string]any{
		"properties": map[string]any{
			"roleDefinitionId": rdID,
			"principalId":      "11111111-1111-1111-1111-111111111111",
			"principalType":    "ServicePrincipal",
		},
	}
	var out map[string]any
	if _, _, status, err := c.PutWithETag(ctx, armPath, roleAssignAPIVersion, "", body, &out); err != nil {
		t.Fatalf("PUT: %v", err)
	} else if status != http.StatusOK && status != http.StatusCreated {
		t.Fatalf("PUT status = %d, want 200/201", status)
	}

	var got map[string]any
	if _, _, status, err := c.GetRaw(ctx, armPath, roleAssignAPIVersion, &got); err != nil || status != http.StatusOK {
		t.Fatalf("GET: status=%d err=%v", status, err)
	}
	props, _ := got["properties"].(map[string]any)
	if mapStringField(props, "principalId") != "11111111-1111-1111-1111-111111111111" {
		t.Fatalf("GET principalId = %v", props["principalId"])
	}
	if got["name"] != name {
		t.Fatalf("GET name = %v, want %q", got["name"], name)
	}

	if _, err := c.DeleteRaw(ctx, NormalizeARMID(armPath), roleAssignAPIVersion); err != nil {
		t.Fatalf("DELETE: %v", err)
	}
	if _, _, status, err := c.GetRaw(ctx, armPath, roleAssignAPIVersion, &got); !IsNotFound(err) {
		t.Fatalf("GET after DELETE: status=%d err=%v, want 404", status, err)
	}
}

// TestLiveRoleDefinitionRoundtrip drives the real smalt ARM face:
// PUT/GET/DELETE on Microsoft.Authorization/roleDefinitions (api-version
// 2022-04-01), unique name per run. C1 gap-close: the ARM face now serves
// custom roleDefinitions writes via Smalt.Arm.Rbac; the provider resource
// is live (previously UNSUPPORTED(wire face) on every verb).
func TestLiveRoleDefinitionRoundtrip(t *testing.T) {
	if os.Getenv("TFPOSHT_LIVE") != "1" {
		t.Skip("live test: set TFPOSHT_LIVE=1")
	}
	ctx := context.Background()
	c, err := NewClient(ctx, "http://127.0.0.1:9443", "00000000-0000-0000-0000-000000000000", "", "", "")
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	name := fmt.Sprintf("f5-rd-%s", mintDeterministicGUID(fmt.Sprintf("rd-%d", time.Now().UnixNano()))[:8])
	scope := fmt.Sprintf("/subscriptions/%s", c.subscriptionID)
	armPath := roleDefARMPath(scope, name)

	defer func() {
		if _, derr := c.DeleteRaw(ctx, armPath, roleDefAPIVersion); derr != nil {
			t.Logf("cleanup delete: %v", derr)
		}
	}()

	body := map[string]any{
		"properties": map[string]any{
			"roleName": name,
			"type":     "CustomRole",
			"permissions": []map[string]any{
				{
					"actions": []string{"Microsoft.Storage/storageAccounts/read"},
				},
			},
			"assignableScopes": []string{scope},
		},
	}
	var out map[string]any
	if _, _, status, err := c.PutWithETag(ctx, armPath, roleDefAPIVersion, "", body, &out); err != nil {
		t.Fatalf("PUT: %v", err)
	} else if status != http.StatusOK && status != http.StatusCreated {
		t.Fatalf("PUT status = %d, want 200/201", status)
	}

	var got map[string]any
	if _, _, status, err := c.GetRaw(ctx, armPath, roleDefAPIVersion, &got); err != nil || status != http.StatusOK {
		t.Fatalf("GET: status=%d err=%v", status, err)
	}
	props, _ := got["properties"].(map[string]any)
	if mapStringField(props, "roleName") != name {
		t.Fatalf("GET roleName = %v, want %q", props["roleName"], name)
	}
	perms, _ := props["permissions"].([]any)
	if len(perms) != 1 {
		t.Fatalf("GET permissions = %v, want 1 row", props["permissions"])
	}

	if _, err := c.DeleteRaw(ctx, armPath, roleDefAPIVersion); err != nil {
		t.Fatalf("DELETE: %v", err)
	}
	if _, _, status, err := c.GetRaw(ctx, armPath, roleDefAPIVersion, &got); !IsNotFound(err) {
		t.Fatalf("GET after DELETE: status=%d err=%v, want 404", status, err)
	}
}
