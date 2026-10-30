package provider

import (
	"context"
	"os"
	"testing"
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
