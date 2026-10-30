package azure

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
)

// The byte-parity golden (captured from the live BEAM faces via
// tmp/lane14_capture.exs: `MIX_ENV=test MIX_BUILD_ROOT=_build-lane14
// mix run --no-start tmp/lane14_capture.exs` — writes
// posh/internal/dialect/azure/testdata/lro_golden.json).
const goldenPath = "testdata/lro_golden.json"

type lroGolden struct {
	Create struct {
		Status  int               `json:"status"`
		Headers map[string]string `json:"headers"`
		Body    string            `json:"body"`
	} `json:"create"`
	Delete struct {
		Status  int               `json:"status"`
		Headers map[string]string `json:"headers"`
		Body    string            `json:"body"`
	} `json:"delete"`
	Doctor []struct {
		Type     string `json:"type"`
		Version  string `json:"version"`
		Latest   string `json:"latest"`
		Admitted bool   `json:"admitted"`
	} `json:"doctor"`
}

func loadGolden(t *testing.T) *lroGolden {
	t.Helper()
	b, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("byte-parity golden unreadable (run the BEAM capture first): %v", err)
	}
	var g lroGolden
	if err := json.Unmarshal(b, &g); err != nil {
		t.Fatalf("golden malformed: %v", err)
	}
	return &g
}

// TestLROEnvelopeByteParity: the posh dialect must reproduce the SAME
// envelope bytes the BEAM face emitted for the same op state (202-as-terminal
// law: the tf provider polls nothing — resource_key_vault.go:203 reads back on
// 202 — so envelope drift here regresses terraform directly).
func TestLROEnvelopeByteParity(t *testing.T) {
	g := loadGolden(t)

	// ---- create face ------------------------------------------------------
	// Rebuild the op record from the golden body (same op state), then assert
	// the dialect envelope reproduces the golden bytes byte-identically.
	var op OpRecord
	if err := json.Unmarshal([]byte(g.Create.Body), &op); err != nil {
		t.Fatalf("golden create body not an op record: %v", err)
	}

	authority := deriveAuthority(g.Create.Headers["azure-asyncoperation"])
	if authority == "" {
		t.Fatalf("could not derive authority from golden headers")
	}

	got := AsyncEnvelope(FaceCreate, authority, &op)

	if got.Status != g.Create.Status {
		t.Fatalf("create status = %d, BEAM emitted %d", got.Status, g.Create.Status)
	}
	if len(got.Headers) != len(g.Create.Headers) {
		t.Fatalf("create header count = %d, BEAM golden %d", len(got.Headers), len(g.Create.Headers))
	}
	for _, kv := range got.Headers {
		want, ok := g.Create.Headers[kv[0]]
		if !ok {
			t.Fatalf("create: dialect emitted header %q absent from BEAM golden", kv[0])
		}
		if kv[1] != want {
			t.Fatalf("create header %q = %q, BEAM golden %q", kv[0], kv[1], want)
		}
	}
	if string(got.Body) != g.Create.Body {
		t.Fatalf("create body bytes diverge from BEAM golden:\n got: %s\nwant: %s", got.Body, g.Create.Body)
	}

	// ---- delete face ------------------------------------------------------
	loc := g.Delete.Headers["location"]
	if loc == "" {
		t.Fatalf("golden delete carries no location header")
	}
	authorityDel := deriveAuthority(loc)
	// The BEAM delete minters poll-URL from the FULL op id (the whole
	// "/subscriptions/.../operations/<id>" path), same as the create face.
	fullOpID := loc[len(authorityDel):]

	dGot := AsyncEnvelope(FaceDelete, authorityDel, &OpRecord{ID: fullOpID})

	if dGot.Status != g.Delete.Status {
		t.Fatalf("delete status = %d, BEAM emitted %d", dGot.Status, g.Delete.Status)
	}
	// Per-face law: location + retry-after ONLY — no azure-asyncoperation.
	if _, leak := g.Delete.Headers["azure-asyncoperation"]; leak {
		t.Fatalf("BEAM delete golden carries azure-asyncoperation — per-face table changed upstream; re-capture")
	}
	if len(dGot.Headers) != len(g.Delete.Headers) {
		t.Fatalf("delete header count = %d, BEAM golden %d", len(dGot.Headers), len(g.Delete.Headers))
	}
	for _, kv := range dGot.Headers {
		want, ok := g.Delete.Headers[kv[0]]
		if !ok {
			t.Fatalf("delete: dialect emitted header %q absent from BEAM golden (per-face law breach)", kv[0])
		}
		if kv[1] != want {
			t.Fatalf("delete header %q = %q, BEAM golden %q", kv[0], kv[1], want)
		}
	}
	if string(dGot.Body) != g.Delete.Body {
		t.Fatalf("delete body bytes diverge from BEAM golden: got %q want %q", dGot.Body, g.Delete.Body)
	}
}

// TestLroWireBodyParity: the KD-T5-F3 shim semantics survive the move:
// InProgress passthrough, stored enrichment, id/name/type enrichment,
// degrade-don't-fabricate on a miss.
func TestLroWireBodyParity(t *testing.T) {
	op := map[string]any{
		"status":     "InProgress",
		"resourceId": "/subscriptions/s/resourceGroups/r/providers/Microsoft.Storage/storageAccounts/sa1",
	}
	if got := LroWireBody(op, map[string]any{"properties": map[string]any{"x": 1}}); len(got) != 2 {
		t.Fatalf("InProgress op must pass through untouched, got %v", got)
	}

	terminal := map[string]any{
		"status":     "Succeeded",
		"resourceId": "/subscriptions/s/resourceGroups/r/providers/Microsoft.Storage/storageAccounts/sa1",
		"name":       "op-name",
	}
	stored := map[string]any{
		"properties": map[string]any{"provisioningState": "Succeeded"},
		"location":   "eastus",
	}
	got := LroWireBody(terminal, stored)
	if got["id"] != terminal["resourceId"] || got["type"] != "Microsoft.Storage/storageAccounts" || got["name"] != "sa1" {
		t.Fatalf("identity enrichment wrong: %v", got)
	}
	if _, ok := got["properties"]; !ok || got["location"] != "eastus" {
		t.Fatalf("stored enrichment wrong: %v", got)
	}

	lean := LroWireBody(map[string]any{"status": "Succeeded", "resourceId": terminal["resourceId"]}, nil)
	if _, ok := lean["properties"]; ok {
		t.Fatalf("nil stored must not fabricate properties: %v", lean)
	}

	odd := LroWireBody(map[string]any{"status": "Succeeded", "resourceId": "not-an-arm-id"}, nil)
	if _, ok := odd["id"]; ok {
		t.Fatalf("non-ARM id must not enrich identity: %v", odd)
	}
}

// TestDoctorOracleCrossExam: the posh dialect admission must agree with the
// BEAM doctor oracle (Smalt.Registry.admitted_version?/2) on all 20 cells —
// 4 types x 5 version cases (latest, 2019-01-01, 2099-01-01, ABSENT, "abc").
// The latest-version strings are dialect config seeded FROM the golden (the
// lattice RULE SHAPE stays core; the table is dialect territory, L2).
func TestDoctorOracleCrossExam(t *testing.T) {
	g := loadGolden(t)
	if len(g.Doctor) != 20 {
		t.Fatalf("doctor golden must carry 20 cells, got %d", len(g.Doctor))
	}

	dialectLatest := map[string]string{}
	for _, cell := range g.Doctor {
		if cell.Latest != "" {
			dialectLatest[cell.Type] = cell.Latest
		}
	}

	agree := 0
	for _, cell := range g.Doctor {
		got := admittedVersionIn(dialectLatest, cell.Type, cell.Version)
		if got != cell.Admitted {
			t.Errorf("doctor cell %s / %q: BEAM oracle %v, dialect %v",
				cell.Type, cell.Version, cell.Admitted, got)
			continue
		}
		agree++
	}
	if agree != 20 {
		t.Fatalf("doctor cross-exam %d/20 — falsifier requires 20/20", agree)
	}
	t.Logf("doctor cross-exam: 20/20 cells agree with Smalt.Registry.admitted_version?/2")
}

// admittedVersionIn is the dialect-side monotonic admission lattice (KD-78)
// over a latest-version table: admitted iff the type is registered and
// version <= latest (date order, -preview stripped). Mirrors
// Smalt.Registry.admitted_version?/2 + Common.version_lte?/2.
func admittedVersionIn(table map[string]string, resourceType, version string) bool {
	latest, ok := table[resourceType]
	if !ok {
		return false
	}
	v, ok1 := parseVersionBase(version)
	l, ok2 := parseVersionBase(latest)
	return ok1 && ok2 && v <= l
}

// parseVersionBase strips a -preview suffix and renders YYYY-MM-DD as a
// comparable int (unparseable -> never admitted, KD-78 malformed law).
func parseVersionBase(version string) (int, bool) {
	base := strings.Split(version, "-preview")[0]
	var y, m, d int
	if _, err := fmt.Sscanf(base, "%d-%d-%d", &y, &m, &d); err != nil {
		return 0, false
	}
	if y < 1000 || y > 9999 || m < 1 || m > 12 || d < 1 || d > 31 {
		return 0, false
	}
	return y*10000 + m*100 + d, true
}

// deriveAuthority splits the request-authority origin off an operation URL
// ("http://host/.../operations/<id>" -> "http://host"): the same
// client's-seat resolution the BEAM minters use (never hardcoded).
func deriveAuthority(opURL string) string {
	if i := strings.Index(opURL, "/subscriptions"); i >= 0 {
		return opURL[:i]
	}
	return ""
}
