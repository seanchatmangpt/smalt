package kv7

import (
	"strings"
	"testing"
)

func TestGUIDVersionShape(t *testing.T) {
	for i := 0; i < 64; i++ {
		g := GUIDVersion()
		if !IsGUIDVersion(g) {
			t.Fatalf("minted %q does not parse as guid_version grammar", g)
		}
		if g != strings.ToLower(g) {
			t.Fatalf("minted %q not lowercase", g)
		}
		// RFC-4122 v4 bits: version nibble 4, variant bits 10.
		if g[14] != '4' {
			t.Fatalf("version nibble not 4: %q", g)
		}
		if c := g[19]; c != '8' && c != '9' && c != 'a' && c != 'b' {
			t.Fatalf("variant bits not 10xx: %q", g)
		}
	}
	// Uniqueness smoke (rand-backed): 64 mints, no collision.
	seen := map[string]bool{}
	for i := 0; i < 64; i++ {
		g := GUIDVersion()
		if seen[g] {
			t.Fatalf("collision on %s", g)
		}
		seen[g] = true
	}
}

func TestParseDataPlaneID(t *testing.T) {
	v, n, ver, err := ParseDataPlaneID("https://v.vault.azure.net/secrets/s/u1")
	if err != nil || v != "v" || n != "s" || ver != "u1" {
		t.Fatalf("got %q %q %q err %v", v, n, ver, err)
	}
	v, n, ver, err = ParseDataPlaneID("https://v.vault.azure.net/secrets/s")
	if err != nil || v != "v" || n != "s" || ver != "" {
		t.Fatalf("got %q %q %q err %v", v, n, ver, err)
	}
	if _, _, _, err := ParseDataPlaneID("/subscriptions/x"); err == nil {
		t.Fatal("ARM-shaped id must be refused by the kv7 parser")
	}
}

func TestLatestVersionLastWrite(t *testing.T) {
	// KD-S4: lexical UUID order is a TRAP — v3's UUID sorts BEFORE v1's
	// lexically here, yet v3 is the last write and must win.
	index := []VersionRow{
		{Version: "ffffffff-0000-4000-8000-000000000001", CreatedSeq: 1},
		{Version: "00000000-0000-4000-8000-000000000003", CreatedSeq: 3},
		{Version: "00000000-0000-4000-8000-000000000002", CreatedSeq: 2},
	}
	if got := LatestVersion(index); got != "00000000-0000-4000-8000-000000000003" {
		t.Fatalf("latest must be last-write, got %s", got)
	}
	if got := LatestVersion(nil); got != "" {
		t.Fatalf("empty history must resolve empty, got %q", got)
	}
}

func TestLifecycle(t *testing.T) {
	// alive -> deleted -> recovered(alive)
	s, err := Step(StateAlive, "delete", false)
	if err != nil || s != StateDeleted {
		t.Fatalf("delete: %s %v", s, err)
	}
	s, err = Step(s, "recover", false)
	if err != nil || s != StateAlive {
		t.Fatalf("recover: %s %v", s, err)
	}
	// alive -> deleted -> purged
	s, _ = Step(StateAlive, "delete", false)
	s, err = Step(s, "purge", false)
	if err != nil || s != StatePurged {
		t.Fatalf("purge: %s %v", s, err)
	}
	// purge-protection: 409 refusal, state unchanged.
	s, _ = Step(StateAlive, "delete", false)
	if _, err := Step(s, "purge", true); err == nil || !strings.Contains(err.Error(), "409") {
		t.Fatalf("purge-protection must refuse 409, got %v", err)
	}
	// typed 404 refusals: recover/purge of alive, delete of purged.
	if _, err := Step(StateAlive, "recover", false); err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("recover of alive must 404, got %v", err)
	}
	if _, err := Step(StatePurged, "delete", false); err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("delete of purged must 404, got %v", err)
	}
}

func TestBundlePolarity(t *testing.T) {
	row := map[string]any{"id": "i", "value": "v", "version": "u", "versions": []string{"u"}, "created_seq": 1}
	out, err := RenderBundle(FacePointGetPatch, row)
	if err != nil {
		t.Fatal(err)
	}
	if out["value"] != "v" {
		t.Fatal("point face must echo value")
	}
	out, _ = RenderBundle(FaceList, row)
	if _, has := out["value"]; has {
		t.Fatal("list face must never echo value")
	}
	out, _ = RenderBundle(FaceEngineSoftDel, row)
	if _, has := out["value"]; has {
		t.Fatal("soft-delete face must never echo value")
	}
	if _, err := RenderBundle("nope", row); err == nil {
		t.Fatal("unknown face must error loudly")
	}
}

func TestTenantScopedKey(t *testing.T) {
	// Home tenant keeps the byte-identical legacy bare key.
	if got := TenantScopedKey("t1", "t1", "s"); got != "s" {
		t.Fatalf("got %q", got)
	}
	if got := TenantScopedKey("t1", "t2", "s"); got != "t2/s" {
		t.Fatalf("got %q", got)
	}
	if got := TenantScopedKey("t1", "", "s"); got != "s" {
		t.Fatalf("got %q", got)
	}
}
