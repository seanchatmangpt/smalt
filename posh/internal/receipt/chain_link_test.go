package receipt

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
)

type chainVectors struct {
	Domain      string `json:"domain"`
	LinkVectors []struct {
		Name        string `json:"name"`
		PrevRootHex string `json:"prev_root_hex"`
		Seq         uint64 `json:"seq"`
		DataHashHex string `json:"data_hash_hex"`
		SubLedgerID string `json:"sub_ledger_id"`
		LinkDigest  string `json:"link_digest_hex"`
	} `json:"link_vectors"`
	LegacyVectors []struct {
		Name        string `json:"name"`
		PrevRootHex string `json:"prev_root_hex"`
		DataHashHex string `json:"data_hash_hex"`
		LinkDigest  string `json:"link_digest_hex"`
	} `json:"legacy_vectors"`
}

// chainLinkDigest: BLAKE3(domain || raw32(prev) || u64BE(seq) || raw32(dh) || ledger).
func chainLinkDigest(domain []byte, prev []byte, seq uint64, dh []byte, ledger string) string {
	input := make([]byte, 0, len(domain)+32+8+32+len(ledger))
	input = append(input, domain...)
	input = append(input, prev...)
	var be [8]byte
	for i := 0; i < 8; i++ {
		be[i] = byte(seq >> (8 * (7 - i)))
	}
	input = append(input, be[:]...)
	input = append(input, dh...)
	input = append(input, ledger...)
	sum := Sum256(input)
	return hex.EncodeToString(sum[:])
}

func TestChainLinkVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../verification/chain_link_vectors.json")
	if err != nil {
		t.Fatalf("read vectors: %v", err)
	}
	var v chainVectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	domain := []byte(v.Domain)

	// gen-2 links: raw32 prev + u64BE seq + raw32 data_hash + ledger id.
	for _, tc := range v.LinkVectors {
		prev, err1 := hex.DecodeString(tc.PrevRootHex)
		dh, err2 := hex.DecodeString(tc.DataHashHex)
		if err1 != nil || err2 != nil {
			t.Fatalf("bad hex in %s", tc.Name)
		}
		got := chainLinkDigest(domain, prev, tc.Seq, dh, tc.SubLedgerID)
		if got != tc.LinkDigest {
			t.Errorf("gen-2 %s: got %s want %s", tc.Name, got, tc.LinkDigest)
		}
	}

	// gen-1 legacy links: sha256 hex-text fold.
	for _, tc := range v.LegacyVectors {
		sum := sha256.Sum256([]byte(tc.PrevRootHex + tc.DataHashHex))
		got := hex.EncodeToString(sum[:])
		if got != tc.LinkDigest {
			t.Errorf("gen-1 %s: got %s want %s", tc.Name, got, tc.LinkDigest)
		}
	}

	// Encoding-spec differential: hex-text fold must differ from raw32 law.
	if len(v.LinkVectors) > 0 {
		tc := v.LinkVectors[0]
		prev, _ := hex.DecodeString(tc.PrevRootHex)
		dh, _ := hex.DecodeString(tc.DataHashHex)
		hexFold := chainLinkDigest(domain, []byte(tc.PrevRootHex), tc.Seq, []byte(tc.DataHashHex), tc.SubLedgerID)
		raw := chainLinkDigest(domain, prev, tc.Seq, dh, tc.SubLedgerID)
		if raw == hexFold {
			t.Errorf("hex-fold differential collapsed for %s", tc.Name)
		}
	}
}
