package replay_test

import (
	"context"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"smalt.dev/posh/internal/api"
	"smalt.dev/posh/internal/receipt"
	"smalt.dev/posh/internal/replay"
)

// Pinned cross-lane test vector (from receipt/blake3_test.go):
// op="arm.request", ts=1730000000000000000, payload=`{"k":"v"}`.
const pinnedTurnstileHex = "0c39d201b2fc87a2171046f1e76f8afc5398263d888381ee9f24cae4cabdb834"

func TestParseReceiptHex(t *testing.T) {
	t.Parallel()

	// Valid vector
	rec, err := replay.ParseReceiptHex(pinnedTurnstileHex, "arm.request", 1730000000000000000, []byte(`{"k":"v"}`))
	if err != nil {
		t.Fatalf("ParseReceiptHex failed: %v", err)
	}
	if rec.Op != "arm.request" || rec.TimestampNs != 1730000000000000000 || rec.Receipt != pinnedTurnstileHex {
		t.Errorf("unexpected parsed record fields: %+v", rec)
	}

	// Invalid hex length
	_, err = replay.ParseReceiptHex("deadbeef", "op", 100, nil)
	if !errors.Is(err, replay.ErrInvalidReceiptHex) {
		t.Errorf("expected ErrInvalidReceiptHex, got %v", err)
	}

	// Invalid hex characters
	badChars := strings.Repeat("z", 64)
	_, err = replay.ParseReceiptHex(badChars, "op", 100, nil)
	if !errors.Is(err, replay.ErrInvalidReceiptHex) {
		t.Errorf("expected ErrInvalidReceiptHex for bad chars, got %v", err)
	}

	// Empty op
	_, err = replay.ParseReceiptHex(pinnedTurnstileHex, "", 100, nil)
	if !errors.Is(err, replay.ErrEmptyOperation) {
		t.Errorf("expected ErrEmptyOperation, got %v", err)
	}
}

func TestParseRecordAndLog(t *testing.T) {
	t.Parallel()

	// Single record JSON
	singleJSON := `{
		"id": "rec-1",
		"op": "echo",
		"timestamp_ns": 1730280000000000000,
		"payload": "{\"test\":true}",
		"receipt": "0c39d201b2fc87a2171046f1e76f8afc5398263d888381ee9f24cae4cabdb834"
	}`

	rec, err := replay.ParseRecord([]byte(singleJSON))
	if err != nil {
		t.Fatalf("ParseRecord failed: %v", err)
	}
	if rec.ID != "rec-1" || rec.Op != "echo" {
		t.Errorf("parsed record mismatch: %+v", rec)
	}

	// JSON Array Log
	arrayLog := `[
		{"id": "r1", "op": "echo", "timestamp_ns": 100, "payload": {"foo": "bar"}},
		{"id": "r2", "op": "arm.request", "timestamp_ns": 200, "payload": "raw"}
	]`
	records, err := replay.ParseLog(strings.NewReader(arrayLog))
	if err != nil {
		t.Fatalf("ParseLog array failed: %v", err)
	}
	if len(records) != 2 {
		t.Fatalf("expected 2 records, got %d", len(records))
	}
	if records[0].Op != "echo" || records[1].Op != "arm.request" {
		t.Errorf("unexpected record ops: %v, %v", records[0].Op, records[1].Op)
	}

	// JSON Lines (JSONL) Log with comments and empty lines
	jsonlLog := `
# Replay journal trace
{"id": "line1", "op": "echo", "timestamp_ns": 101, "payload": "p1"}

{"id": "line2", "op": "arm.get", "timestamp_ns": 102, "payload": "p2"}
`
	recordsJSONL, err := replay.ParseLog(strings.NewReader(jsonlLog))
	if err != nil {
		t.Fatalf("ParseLog JSONL failed: %v", err)
	}
	if len(recordsJSONL) != 2 {
		t.Fatalf("expected 2 records, got %d", len(recordsJSONL))
	}
	if recordsJSONL[0].ID != "line1" || recordsJSONL[1].ID != "line2" {
		t.Errorf("unexpected IDs: %v, %v", recordsJSONL[0].ID, recordsJSONL[1].ID)
	}
}

func TestInMemoryTimeTravelReplay(t *testing.T) {
	t.Parallel()

	called := false
	memHandler := func(ctx context.Context, req *api.Request) *api.Response {
		called = true
		if req.Op != "arm.request" {
			return api.NewError(req.ID, api.CodeUpstream, "unexpected op")
		}
		return api.NewOK(req.ID, map[string]string{"status": "ok"})
	}

	replayer := replay.NewReplayer(
		replay.WithMembraneHandler(memHandler),
		replay.WithStrict(true),
	)

	// Build a valid record matching pinned vector
	rec := &replay.Record{
		ID:          "req-test-1",
		Op:          "arm.request",
		TimestampNs: 1730000000000000000,
		Payload:     []byte(`{"k":"v"}`),
		Receipt:     pinnedTurnstileHex,
	}

	res, err := replayer.Execute(context.Background(), rec)
	if err != nil {
		t.Fatalf("Execute failed: %v", err)
	}
	if !called {
		t.Fatal("expected membrane handler to be invoked")
	}
	if !res.Matched {
		t.Fatalf("expected turnstile match, got diff: %s", res.Diff)
	}
	if res.ReplayedReceipt != pinnedTurnstileHex {
		t.Errorf("got %s, want %s", res.ReplayedReceipt, pinnedTurnstileHex)
	}
	if res.Response == nil || res.Response.Ok == nil {
		t.Fatalf("expected OK response, got %+v", res.Response)
	}
}

func TestTurnstileAntiVacuityMismatch(t *testing.T) {
	t.Parallel()

	replayer := replay.NewReplayer(replay.WithStrict(true))

	// 1. Bit flip in payload
	recDiffPayload := &replay.Record{
		Op:          "arm.request",
		TimestampNs: 1730000000000000000,
		Payload:     []byte(`{"k":"v_TAMPERED"}`),
		Receipt:     pinnedTurnstileHex,
	}
	_, err := replayer.Execute(context.Background(), recDiffPayload)
	if err == nil || !errors.Is(err, replay.ErrTurnstileMismatch) {
		t.Fatalf("expected ErrTurnstileMismatch on payload bit flip, got %v", err)
	}

	// 2. 1-nanosecond timestamp drift
	recDiffTs := &replay.Record{
		Op:          "arm.request",
		TimestampNs: 1730000000000000001,
		Payload:     []byte(`{"k":"v"}`),
		Receipt:     pinnedTurnstileHex,
	}
	_, err = replayer.Execute(context.Background(), recDiffTs)
	if err == nil || !errors.Is(err, replay.ErrTurnstileMismatch) {
		t.Fatalf("expected ErrTurnstileMismatch on timestamp drift, got %v", err)
	}

	// 3. Operation name change
	recDiffOp := &replay.Record{
		Op:          "arm.request_other",
		TimestampNs: 1730000000000000000,
		Payload:     []byte(`{"k":"v"}`),
		Receipt:     pinnedTurnstileHex,
	}
	_, err = replayer.Execute(context.Background(), recDiffOp)
	if err == nil || !errors.Is(err, replay.ErrTurnstileMismatch) {
		t.Fatalf("expected ErrTurnstileMismatch on op change, got %v", err)
	}
}

func TestLoopbackHTTPReplay(t *testing.T) {
	t.Parallel()

	// Create a loopback HTTP server that echoes headers and turnstiles
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tsStr := r.Header.Get(replay.HeaderTimestamp)
		var ts uint64
		if tsStr != "" {
			_ = json.Unmarshal([]byte(tsStr), &ts)
		}
		buf := make([]byte, 1024)
		n, _ := r.Body.Read(buf)
		body := buf[:n]

		// Server produces real receipt
		turnstile := receipt.Hex(receipt.TurnstileReceipt("arm.request", ts, body))
		w.Header().Set(replay.HeaderTurnstile, turnstile)
		w.Header().Set(replay.HeaderTimestamp, tsStr)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"status":"success"}`))
	}))
	defer srv.Close()

	replayer := replay.NewReplayer(
		replay.WithTargetURL(srv.URL),
		replay.WithStrict(true),
	)

	rec := &replay.Record{
		Op:          "arm.request",
		Path:        "/subscriptions/sub/resourcegroups",
		Method:      http.MethodPost,
		TimestampNs: 1730000000000000000,
		Payload:     []byte(`{"k":"v"}`),
		Receipt:     pinnedTurnstileHex,
	}

	res, err := replayer.Execute(context.Background(), rec)
	if err != nil {
		t.Fatalf("Loopback Execute failed: %v", err)
	}
	if !res.Matched {
		t.Fatalf("expected match, got %s", res.Diff)
	}
	if res.HTTPStatusCode != http.StatusOK {
		t.Errorf("status code = %d, want 200", res.HTTPStatusCode)
	}
}

func TestReplayAllAndFile(t *testing.T) {
	t.Parallel()

	rec1 := &replay.Record{
		Op:          "arm.request",
		TimestampNs: 1730000000000000000,
		Payload:     []byte(`{"k":"v"}`),
		Receipt:     pinnedTurnstileHex,
	}
	// Compute expected receipt for second record
	ts2 := uint64(1730280000000000000)
	payload2 := []byte(`{"subscription_id":"00000000-0000-0000-0000-000000000000"}`)
	rec2Receipt := hex.EncodeToString(func() []byte {
		h := receipt.TurnstileReceipt("echo", ts2, payload2)
		return h[:]
	}())
	rec2 := &replay.Record{
		Op:          "echo",
		TimestampNs: ts2,
		Payload:     payload2,
		Receipt:     rec2Receipt,
	}

	replayer := replay.NewReplayer()
	summary, err := replayer.ReplayAll(context.Background(), []*replay.Record{rec1, rec2})
	if err != nil {
		t.Fatalf("ReplayAll failed: %v", err)
	}
	if summary.Total != 2 || summary.Matched != 2 || summary.Mismatched != 0 {
		t.Errorf("summary mismatch: %+v", summary)
	}

	// Write to temporary file and test ReplayFile
	tmpDir := t.TempDir()
	logPath := filepath.Join(tmpDir, "replay_trace.jsonl")
	data1, _ := json.Marshal(rec1)
	data2, _ := json.Marshal(rec2)
	content := string(data1) + "\n" + string(data2) + "\n"
	if err := os.WriteFile(logPath, []byte(content), 0o644); err != nil {
		t.Fatalf("write log file: %v", err)
	}

	fileSummary, err := replayer.ReplayFile(context.Background(), logPath)
	if err != nil {
		t.Fatalf("ReplayFile failed: %v", err)
	}
	if fileSummary.Total != 2 || fileSummary.Matched != 2 {
		t.Errorf("file summary mismatch: %+v", fileSummary)
	}
}

func BenchmarkTurnstileReplayValidation(b *testing.B) {
	payload := []byte(`{"k":"v"}`)
	rec := &replay.Record{
		Op:          "arm.request",
		TimestampNs: 1730000000000000000,
		Payload:     payload,
		Receipt:     pinnedTurnstileHex,
	}
	replayer := replay.NewReplayer()
	ctx := context.Background()

	b.ResetTimer()
	b.ReportAllocs()
	for i := 0; i < b.N; i++ {
		res, err := replayer.Execute(ctx, rec)
		if err != nil || !res.Matched {
			b.Fatalf("benchmark failed: %v", err)
		}
	}
}
