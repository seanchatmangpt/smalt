package pinion

import (
	"bytes"
	"crypto/md5"
	"encoding/hex"
	"testing"
)

// Golden: .NET-GUID reorder of a dashed uuid's raw bytes (computed from the
// BEAM LockManager.token_to_wire/1 layout [b3,b2,b1,b0,b5,b4,b7,b6,rest];
// lane receipt python probe 2026-10-30).
// goldenDashed "0f8d5c1e-0000-4000-8000-000000000001" reorders to goldenWire.
var goldenWire, _ = hex.DecodeString("1e5c8d0f000000408000000000000001")

func TestReorderNETGUIDGolden(t *testing.T) {
	raw, err := hex.DecodeString("0f8d5c1e000040008000000000000001")
	if err != nil {
		t.Fatal(err)
	}
	out, err := ReorderNETGUID(raw)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(out, goldenWire) {
		t.Fatalf("reorder drift: got %x want %x", out, goldenWire)
	}
}

func TestReorderNETGUIDInvolution(t *testing.T) {
	raw, _ := hex.DecodeString("0f8d5c1e000040008000000000000001")
	once, _ := ReorderNETGUID(raw)
	twice, _ := ReorderNETGUID(once)
	if !bytes.Equal(twice, raw) {
		t.Fatal("double-involution violated: the 410 MESSAGE_LOCK_LOST hazard")
	}
	// Exhaustive over structured inputs: involution holds on every pattern.
	for i := 0; i < 256; i++ {
		b := []byte{
			byte(i), byte(i ^ 0xFF), 3, 4, 5, 6, 7, 8,
			9, 10, 11, 12, 13, 14, 15, byte(255 - i),
		}
		once, _ := ReorderNETGUID(b)
		twice, _ := ReorderNETGUID(once)
		if !bytes.Equal(twice, b) {
			t.Fatalf("involution violated at pattern %d", i)
		}
	}
	// Wrong length is a loud error, never silent.
	if _, err := ReorderNETGUID(make([]byte, 15)); err == nil {
		t.Fatal("15-byte token must be refused")
	}
}

func TestSASLOutcomeDescriptor(t *testing.T) {
	if SASLOutcomeDescriptor != 0x44 {
		t.Fatal("0x44 pinion drifted")
	}
	if got := WirePerfID(byte(SASLOutcomeDescriptor)); !bytes.Equal(got, []byte{0x00, 0x53, 0x44}) {
		t.Fatalf("performative constructor drift: %x", got)
	}
}

func TestSASLAnonymousOnly(t *testing.T) {
	if len(SASLAdvertisedMechanisms) != 1 || SASLAdvertisedMechanisms[0] != "ANONYMOUS" {
		t.Fatal("advertised set must stay exactly [ANONYMOUS] (pinion, verbatim)")
	}
}

func TestAttachArity(t *testing.T) {
	if len(AttachFields) != AttachFieldCount {
		t.Fatalf("attach arity drifted: %d != 14", len(AttachFields))
	}
	// Locale fields must be absent (the 16-vs-14 crash class).
	for _, f := range AttachFields {
		if f == "outgoingLocales" || f == "incomingLocales" {
			t.Fatalf("locale field %q must be omitted from attach", f)
		}
	}
}

func TestEHPartitionTwins(t *testing.T) {
	// Golden vectors computed from md5(pk)[0] rem 2 (lane receipt python
	// probe 2026-10-30, matching EventHubsRestRoutes.ex pk_partition/1 and
	// connection/link.ex eh_pk_partition/1).
	vectors := map[string]string{
		"evt-key-a": "0",
		"evt-key-b": "0",
		"evt-key-c": "1",
		"evt-key-d": "0",
	}
	for pk, want := range vectors {
		// The Go law and the md5 remainder are computed independently so
		// a drift in EHPartitionOf shows as a mismatch.
		sum := md5.Sum([]byte(pk))
		manual := EHFixedPartitions[int(sum[0])%2]
		if got := EHPartitionOf([]byte(pk)); got != manual || got != want {
			t.Fatalf("partition twin drift for %q: got %s want %s (manual %s)", pk, got, want, manual)
		}
	}
	// Only ["0","1"] admitted; "2" is the never-deliverable attach class.
	if !EHPartitionAdmitted("0") || !EHPartitionAdmitted("1") {
		t.Fatal("pinned partitions must be admitted")
	}
	if EHPartitionAdmitted("2") {
		t.Fatal("partition \"2\" must be refused (silently-unreceivable attach)")
	}
}
