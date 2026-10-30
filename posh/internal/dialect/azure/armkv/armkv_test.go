package armkv

import (
	"reflect"
	"testing"
)

// Golden vectors: same input MUST mint the same GUID (KD-09 tf-state law).
// Values cross-probed against the real tf provider function
// (resource_remaining_v1.go mintDeterministicGUID, lane-15 receipt:
// go test probe 2026-10-30, output quoted in the wave receipt).
func TestMintDeterministicGUIDGolden(t *testing.T) {
	goldens := map[string]string{
		"/subscriptions/00000000-0000-4000-8000-000000000000/resourceGroups/rg1/providers/Microsoft.Authorization/roleDefinitions/foo": "6f261121-a182-5683-9e4c-91e0b3618ac0",
		"smalt-kv-armkv-golden": "adcd7097-2121-5af3-a36e-98df40de25e8",
	}
	for in, want := range goldens {
		if got := MintDeterministicGUID(in); got != want {
			t.Fatalf("uuid5 drift: input %q got %s want %s", in, got, want)
		}
	}
	// Namespace byte-freeze tripwire: flipping one namespace byte MUST
	// change the output (the freeze is load-bearing, not decorative).
	tampered := make([]byte, len(RoleDefUUIDNamespace))
	copy(tampered, RoleDefUUIDNamespace)
	tampered[7] ^= 0x01
	saved := RoleDefUUIDNamespace
	RoleDefUUIDNamespace = tampered
	if MintDeterministicGUID("smalt-kv-armkv-golden") == "adcd7097-2121-5af3-a36e-98df40de25e8" {
		t.Fatal("namespace freeze vacuous: tampered bytes minted the golden GUID")
	}
	RoleDefUUIDNamespace = saved
}

func TestPolarityTable(t *testing.T) {
	row := map[string]any{
		"id":             "https://v.vault.azure.net/secrets/s",
		"value":          "shh",
		"attributes":     map[string]any{},
		"version":        "u1",
		"versions":       []string{"u1"},
		"created_seq":    3,
		"is_version_row": true,
	}
	// Point face echoes value.
	out, err := ApplyPolarity("8443-point-get-patch", row)
	if err != nil {
		t.Fatal(err)
	}
	if out["value"] != "shh" {
		t.Fatal("point face must echo value (KD-03 polarity)")
	}
	if _, has := out["versions"]; has {
		t.Fatal("bookkeeping must never leave the vault")
	}
	// List face never echoes value.
	out, err = ApplyPolarity("8443-list", row)
	if err != nil {
		t.Fatal(err)
	}
	if _, has := out["value"]; has {
		t.Fatal("list face must never echo value (KD-03 polarity)")
	}
	// Soft-delete face never echoes value.
	out, _ = ApplyPolarity("engine-soft-delete", row)
	if _, has := out["value"]; has {
		t.Fatal("soft-delete face must never echo value (KD-03 polarity)")
	}
	// ARM face echoes verbatim — no drops beyond bookkeeping.
	out, _ = ApplyPolarity("arm-face", row)
	if out["value"] != "shh" || out["version"] != "u1" {
		t.Fatal("ARM face must echo verbatim (posh KD-03 law)")
	}
	// Unknown face is a loud error, never a silent pass.
	if _, err := ApplyPolarity("no-such-face", row); err == nil {
		t.Fatal("unknown face must error")
	}
}

func TestAPIVersionGate(t *testing.T) {
	cases := map[string]bool{
		"":           true,  // KD-151 relaxed gate: absent admitted
		"7.4":        true,  // pin
		"7.0":        true,  // 7.x ladder
		"7":          false, // bare major
		"7.x":        false, // bad minor
		"6.0":        false, // past
		"2099-01-01": false, // future date-form (KD-78 fence)
	}
	for v, want := range cases {
		if got := APIVersionAdmitted(v); got != want {
			t.Fatalf("api-version %q: got %v want %v", v, got, want)
		}
	}
}

func TestIDGrammar(t *testing.T) {
	if got, want := MintDataPlaneID("v", "s", "u1"), "https://v.vault.azure.net/secrets/s/u1"; got != want {
		t.Fatalf("got %s want %s", got, want)
	}
	if got, want := MintDataPlaneID("v", "s", ""), "https://v.vault.azure.net/secrets/s"; got != want {
		t.Fatalf("got %s want %s", got, want)
	}
	want := "/subscriptions/sub/resourceGroups/rg/providers/Microsoft.KeyVault/vaults/v"
	if got := MintARMID("sub", "rg", "v"); got != want {
		t.Fatalf("got %s want %s", got, want)
	}
	if !reflect.DeepEqual(SortKeys(map[string]any{"b": 1, "a": 2}), []string{"a", "b"}) {
		t.Fatal("SortKeys not sorted")
	}
}
