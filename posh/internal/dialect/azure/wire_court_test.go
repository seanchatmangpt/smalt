// WO-13 wire-court port (lane 12, v26.10.31): Go port of the AMQP leg
// (leg 1) of test/courts/court_wire.erl — BYTE FIDELITY IS LOAD-BEARING
// (SHIM-COURT R51: a prior "cleaner" layout caused 410 MESSAGE_LOCK_LOST
// on every live lock). Do not clean up, do not "normalize" the frames.
//
// Speaks raw TCP to the live smalt AMQP endpoint (127.0.0.1:5672):
// SASL ANONYMOUS-only handshake, sasl-outcome descriptor 0x44 with code
// zero, AMQP open/begin, 14-field CBS attach pair, CBS put-token with a
// REAL HMAC-SHA256 SAS token, queue-scoped put-token, queue attach +
// unsettled transfer + disposition accepted.
//
// Substrate down or SMALT_SB_SHARED_KEY unset: loud t.Skip — never a
// fake pass.
package azure

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const (
	wireHost        = "127.0.0.1"
	wireAMQPPort    = "5672"
	wireTimeout     = 15 * time.Second
	wireContainerID = "ecourt-fence"
)

// ---- byte-fence assertion primitives (court_wire.erl assert_*) ------------

func wireAssertPrefix(t *testing.T, prefix []byte, body []byte, name string) {
	t.Helper()
	if !bytes.HasPrefix(body, prefix) {
		t.Fatalf("fence_violation %s: expected prefix %x got %x", name, prefix, body)
	}
}

func wireAssertContains(t *testing.T, needle []byte, hay []byte, name string) {
	t.Helper()
	if !bytes.Contains(hay, needle) {
		t.Fatalf("fence_violation %s: needle_missing %q haystack %x", name, needle, hay)
	}
}

func wireAssertNotContains(t *testing.T, needle string, hay []byte, name string) {
	t.Helper()
	if strings.Contains(string(hay), needle) {
		t.Fatalf("fence_violation %s: needle_present %q", name, needle)
	}
}

// ---- AMQP wire helpers (mirror court_wire.erl frame/desc/enc_*) -----------

// wireFrame mirrors frame/3: [Size:32, 0x02, Type, Ch:16, body...]
func wireFrame(typ byte, ch uint16, body ...[]byte) []byte {
	n := 8
	for _, b := range body {
		n += len(b)
	}
	out := make([]byte, 8, n)
	binary.BigEndian.PutUint32(out[0:4], uint32(n))
	out[4] = 0x02
	out[5] = typ
	binary.BigEndian.PutUint16(out[6:8], ch)
	return append(out, bytes.Join(body, nil)...)
}

// wireJoin concatenates iolist-style parts.
func wireJoin(parts ...[]byte) []byte { return bytes.Join(parts, nil) }

// wireDesc mirrors desc/2: described performative — constructor 0x00 +
// smallulong descriptor + list32 fields. Compound size INCLUDES the count
// field (AMQP §1.6 list32: size covers count + elements — byte-proven
// against the substrate's own mechanisms frame, C0 0F = 1(count) + 14).
func wireDesc(desc byte, fields ...[]byte) []byte {
	sz := 4
	for _, f := range fields {
		sz += len(f)
	}
	out := []byte{0x00, 0x53, desc, 0xD0}
	out = binary.BigEndian.AppendUint32(out, uint32(sz))
	out = binary.BigEndian.AppendUint32(out, uint32(len(fields)))
	return wireJoin(append([][]byte{out}, fields...)...)
}

// wireDescVal mirrors desc_val/2: described value whose body is a RAW
// encoded value (map body of application-properties, string body of
// amqp-value) — NOT a field list. NOTE: desc_val, NOT desc — the section
// value IS the map; desc would wrap it in a bogus list32.
func wireDescVal(desc byte, value []byte) []byte {
	return wireJoin([]byte{0x00, 0x53, desc}, value)
}

func wireEncStr(b []byte) []byte {
	return append([]byte{0xA1, byte(len(b))}, b...)
}

func wireEncSym(b []byte) []byte {
	return append([]byte{0xA3, byte(len(b))}, b...)
}

func wireEncBin(b []byte) []byte {
	return append([]byte{0xA0, byte(len(b))}, b...)
}

// wireEncMap mirrors enc_map/3: map32 constructor 0xD1, size INCLUDES the
// count field, count = pairs*2. KEYS are symbols (val(s,...)), VALUES are
// strings (val(b,...)) — the real-SDK shape; the substrate's normalize_keys
// converts symbol keys only, a symbol VALUE decodes as {:symbol, _} and
// fails the plain-binary check_operation/2 compare.
func wireEncMap(pairs [][2][]byte) []byte {
	sz := 4
	for _, p := range pairs {
		sz += len(wireEncSym(p[0])) + len(wireEncStr(p[1]))
	}
	out := []byte{0xD1}
	out = binary.BigEndian.AppendUint32(out, uint32(sz))
	out = binary.BigEndian.AppendUint32(out, uint32(len(pairs)*2))
	for _, p := range pairs {
		out = append(out, wireEncSym(p[0])...)
		out = append(out, wireEncStr(p[1])...)
	}
	return out
}

// wireAddrField mirrors addr_field/2 (source desc 0x28, target desc 0x29).
func wireAddrField(desc byte, addr []byte) []byte {
	if addr == nil {
		return []byte{0x40} // null
	}
	return wireDesc(desc, wireEncStr(addr))
}

// wireNull is the AMQP null constructor 0x40.
var wireNull = []byte{0x40}

// wireAttachFrame mirrors attach_frame/4 — 14-field attach (py-court
// pinion): snd/rcv-settle-mode BEFORE source/target — positional decode
// punishes skipped mid-list fields.
func wireAttachFrame(handle byte, roleReceiver bool, source, target []byte) []byte {
	src := wireAddrField(0x28, source)
	tgt := wireAddrField(0x29, target)
	role := byte(0x42) // sender
	if roleReceiver {
		role = 0x41
	}
	name := []byte(fmt.Sprintf("ecourt-l%d", handle))
	return wireDesc(0x12,
		wireEncStr(name),     // name
		[]byte{0x52, handle}, // handle (smalluint)
		[]byte{role},         // role
		[]byte{0x40},         // snd-settle-mode (default mixed)
		[]byte{0x40},         // rcv-settle-mode (default mode-first)
		src, tgt,             // source / target
		[]byte{0x40}, // unsettled
		[]byte{0x40}, // incomplete-unsettled
		[]byte{0x40}, // initial-delivery-count
		[]byte{0x40}, // max-message-size
		[]byte{0x40}, // offered-capabilities
		[]byte{0x40}, // desired-capabilities
		[]byte{0x40}, // properties
	)
}

// wireFlowFrame mirrors flow_frame/2.
func wireFlowFrame(handle byte, credit uint32) []byte {
	creditFld := []byte{0x70, 0, 0, 0, byte(credit)}
	return wireDesc(0x13,
		[]byte{0x52, handle}, // handle
		[]byte{0x52, 0},      // delivery-count
		creditFld,            // credit
		[]byte{0x42},         // drain false
		[]byte{0x42},         // echo false
		[]byte{0x40},         // available
		[]byte{0x40},         // total
	)
}

// wireFrameReader is the Go twin of recv_frame: incremental framing over a
// buffered TCP stream.
type wireFrameReader struct {
	conn net.Conn
	buf  []byte
}

func (r *wireFrameReader) readMore() error {
	r.conn.SetReadDeadline(time.Now().Add(wireTimeout))
	tmp := make([]byte, 4096)
	n, err := r.conn.Read(tmp)
	r.buf = append(r.buf, tmp[:n]...)
	if err != nil {
		return fmt.Errorf("amqp_recv: %w", err)
	}
	return nil
}

// readFrame returns (frameType, body-including-payload, err).
func (r *wireFrameReader) readFrame() (byte, []byte, error) {
	for {
		if len(r.buf) >= 8 {
			size := binary.BigEndian.Uint32(r.buf[0:4])
			doff := r.buf[4]
			if doff != 2 {
				return 0, nil, fmt.Errorf("fence_violation amqp_extended_doff %d", doff)
			}
			if uint32(len(r.buf)) >= size {
				typ := r.buf[5]
				body := append([]byte{}, r.buf[8:size]...)
				r.buf = append([]byte{}, r.buf[size:]...)
				return typ, body, nil
			}
		}
		if err := r.readMore(); err != nil {
			return 0, nil, err
		}
	}
}

func (r *wireFrameReader) readExact(n int) ([]byte, error) {
	for len(r.buf) < n {
		if err := r.readMore(); err != nil {
			return nil, fmt.Errorf("amqp_recv_exact: %w", err)
		}
	}
	out := append([]byte{}, r.buf[:n]...)
	r.buf = append([]byte{}, r.buf[n:]...)
	return out, nil
}

// drainToAttachAcks mirrors drain_to_attach_acks: drain flow (0x13) frames
// until Count attach acks (0x12) observed; anything else is a violation.
func (r *wireFrameReader) drainToAttachAcks(count int) error {
	for count > 0 {
		typ, body, err := r.readFrame()
		if err != nil {
			return err
		}
		switch {
		case bytes.HasPrefix(body, []byte{0x00, 0x53, 0x12}):
			if typ != 0x00 {
				return fmt.Errorf("fence_violation attach_wrong_frame_type %d", typ)
			}
			count--
		case bytes.HasPrefix(body, []byte{0x00, 0x53, 0x13}):
			// flow: keep draining
		default:
			return fmt.Errorf("fence_violation amqp_expected_attach_ack %x", body)
		}
	}
	return nil
}

// recvTransferPayload mirrors recv_transfer_payload: read until a transfer
// (0x14) whose handle matches; return its payload bytes. Detach (0x16) and
// flow (0x13) are skipped per the Erlang court.
func (r *wireFrameReader) recvTransferPayload(handle byte) ([]byte, error) {
	for {
		typ, body, err := r.readFrame()
		if err != nil {
			return nil, err
		}
		if typ != 0x00 {
			return nil, fmt.Errorf("cbs_expected_transfer: frame type %d", typ)
		}
		switch {
		case bytes.HasPrefix(body, []byte{0x00, 0x53, 0x14}):
			rest := body[3:]
			// Erlang pattern: <<0,16#53,16#14, Ctor, Sz..., _N(count)...,
			// Fields0, Payload>> — Fields0 starts AFTER the count field.
			var fields []byte
			var payloadAt int
			switch rest[0] {
			case 0xD0: // list32: ctor(1) size(4) count(4) elements...
				sz := binary.BigEndian.Uint32(rest[1:5])
				fields = rest[9:]
				payloadAt = 5 + int(sz)
			case 0xC0: // list8: ctor(1) size(1) count(1) elements...
				sz := int(rest[1])
				fields = rest[3:]
				payloadAt = 2 + sz
			default:
				return nil, fmt.Errorf("fence_violation transfer_malformed_list %x", body)
			}
			h, err := wireHandleField(fields)
			if err != nil {
				return nil, err
			}
			if h != handle {
				return nil, fmt.Errorf("cbs_expected_transfer: handle %d != %d", h, handle)
			}
			// payload rides the same frame after the list fields
			return rest[payloadAt:], nil
		case bytes.HasPrefix(body, []byte{0x00, 0x53, 0x13}),
			bytes.HasPrefix(body, []byte{0x00, 0x53, 0x16}):
			// flow / detach: keep reading
		default:
			return nil, fmt.Errorf("fence_violation cbs_expected_transfer %x", body)
		}
	}
}

// wireHandleField mirrors handle_field/1: first field of the transfer
// list32 = handle (smalluint 0x52 or uint 0x70).
func wireHandleField(fields []byte) (byte, error) {
	switch {
	case fields[0] == 0x52:
		return fields[1], nil
	case fields[0] == 0x70:
		return fields[4], nil // uint32; assumes low byte carries the handle
	default:
		return 0, fmt.Errorf("fence_violation transfer_handle_encoding %x", fields)
	}
}

// recvDisposition mirrors recv_disposition: read until a disposition
// (0x15); a DETACH (0x16) is a fence violation — the server's typed
// link-level refusal must never be skipped.
func (r *wireFrameReader) recvDisposition() ([]byte, error) {
	for {
		typ, body, err := r.readFrame()
		if err != nil {
			return nil, err
		}
		if typ != 0x00 {
			continue
		}
		switch {
		case bytes.HasPrefix(body, []byte{0x00, 0x53, 0x16}):
			return nil, fmt.Errorf("fence_violation amqp_unexpected_detach %x", body)
		case bytes.HasPrefix(body, []byte{0x00, 0x53, 0x15}):
			return body, nil
		default:
			// keep reading (flow etc.)
		}
	}
}

// assertSaslOutcomeZero mirrors assert_sasl_outcome_zero: after the 0x44
// descriptor the outcome code must encode ZERO in any legal constructor
// form (0x50 ubyte 0 / 0x52 smalluint 0 / 0x43 ulong-0). Anything else =
// refused SASL.
func assertSaslOutcomeZero(t *testing.T, body []byte) {
	t.Helper()
	if !bytes.HasPrefix(body, []byte{0x00, 0x53, 0x44}) {
		t.Fatalf("fence_violation amqp_sasl_outcome_shape %x", body)
	}
	fields := body[3:]
	codeZero := [][]byte{{0x50, 0x00}, {0x52, 0x00}, {0x43}}
	for _, c := range codeZero {
		if bytes.Contains(fields, c) {
			return
		}
	}
	t.Fatalf("fence_violation amqp_sasl_outcome_not_ok %x", fields)
}

// assertStatus200 mirrors assert_status_200: status-code must encode 200
// in a legal uint constructor form (0x70 uint32 / 0x52 smalluint / 0x50
// ubyte); 0x190 = 200.
func assertStatus200(t *testing.T, body []byte) {
	t.Helper()
	code200 := [][]byte{
		{0x70, 0x00, 0x00, 0x00, 200},
		{0x52, 200},
		{0x50, 200},
	}
	for _, c := range code200 {
		if bytes.Contains(body, c) {
			return
		}
	}
	t.Fatalf("fence_violation cbs_reply_200_missing %x", body)
}

// sasToken mirrors sas_token/2: HMAC key = the base64 TEXT (substrate
// shared_key/0 returns the string); string-to-sign = "<sr>\n<se>" (SAS
// spec, sas_verifier check_signature); percent-encode everything but
// unreserved chars — the raw base64 '+' would be URI.decode'd to a SPACE
// server-side (sas_verifier URI.decode(fields.sig)).
func sasToken(keyB64 string, sr string) string {
	se := time.Now().Unix() + 900
	seBin := fmt.Sprintf("%d", se)
	mac := hmac.New(sha256.New, []byte(keyB64))
	mac.Write([]byte(sr + "\n" + seBin))
	sig := wireURIEncode(base64.StdEncoding.EncodeToString(mac.Sum(nil)))
	skn := "RootManageSharedAccessKey"
	return fmt.Sprintf("SharedAccessSignature sr=%s&sig=%s&se=%s&skn=%s",
		sr, sig, seBin, skn)
}

func wireURIEncode(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '-' || c == '.' || c == '_' || c == '~' {
			b.WriteByte(c)
		} else {
			fmt.Fprintf(&b, "%%%02X", c)
		}
	}
	return b.String()
}

// sharedKeyFromDevEnv derives the per-host dev SAS key the same way
// scripts/dev_env.sh does (printf '%s' "$(hostname -s)smalt-dev-sb" |
// openssl dgst -sha256 -binary | base64).
func sharedKeyFromDevEnv(t *testing.T) string {
	t.Helper()
	host, err := exec.Command("hostname", "-s").Output()
	if err != nil {
		h, _ := os.Hostname()
		host = []byte(h)
	}
	sum := sha256.Sum256([]byte(fmt.Sprintf("%ssmalt-dev-sb", strings.TrimSpace(string(host)))))
	return base64.StdEncoding.EncodeToString(sum[:])
}

// ensureQueueARM provisions the test queue through the ARM gateway
// (9443, the admitted management surface): rg -> namespace -> queue PUT.
// The wire court sends to a unique queue; a substrate booted with real-SB
// semantics (KD-86, :sb_auto_ensure=false) refuses
// MessagingEntityNotFound on a never-created entity — a management-plane
// created entity IS sendable (BK-B4R).
func ensureQueueARM(t *testing.T, queue string) {
	t.Helper()
	const armBase = "http://127.0.0.1:9443"
	// STS mint (substrate :enforce auth): form POST, then Bearer on ARM PUTs.
	stsForm := strings.NewReader("grant_type=client_credentials&client_id=ecourt&client_secret=ecourt")
	resp0, err := http.Post(armBase+"/organizations/oauth2/v2.0/token",
		"application/x-www-form-urlencoded", stsForm)
	if err != nil {
		t.Skipf("SKIP LOUD: ARM gateway 127.0.0.1:9443 unreachable (%v) — substrate down; never a fake pass", err)
	}
	b0, _ := io.ReadAll(resp0.Body)
	resp0.Body.Close()
	if resp0.StatusCode != 200 {
		t.Fatalf("STS mint failed: status %d body %s", resp0.StatusCode, b0)
	}
	// extract "access_token":"..." via byte match (no JSON dependency)
	rest, after, found := bytes.Cut(b0, []byte(`"access_token":"`))
	_ = rest
	if !found {
		t.Fatalf("STS response lacks access_token: %s", b0)
	}
	tok, _, _ := bytes.Cut(after, []byte(`"`))
	put := func(path string, body string) {
		req, err := http.NewRequest(http.MethodPut, armBase+path+"?api-version=2021-04-01",
			strings.NewReader(body))
		if err != nil {
			t.Fatalf("ARM PUT %s: %v", path, err)
		}
		req.Header.Set("content-type", "application/json")
		req.Header.Set("authorization", "Bearer "+string(tok))
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Skipf("SKIP LOUD: ARM gateway 127.0.0.1:9443 unreachable (%v) — substrate down; never a fake pass", err)
		}
		defer resp.Body.Close()
		if resp.StatusCode == 202 {
			// LRO: bounded poll on the operation resource until terminal
			// status — observe, never wait-and-hope.
			b, _ := io.ReadAll(resp.Body)
			_, opID, ok2 := bytes.Cut(b, []byte(`"id":"`))
			if !ok2 {
				t.Fatalf("ARM PUT %s: 202 without operation id: %s", path, b)
			}
			opURL, _, _ := bytes.Cut(opID, []byte(`"`))
			deadline := time.Now().Add(15 * time.Second)
			for {
				reqP, _ := http.NewRequest(http.MethodGet, armBase+string(opURL), nil)
				reqP.Header.Set("authorization", "Bearer "+string(tok))
				rp, err := http.DefaultClient.Do(reqP)
				if err != nil {
					t.Fatalf("LRO poll %s: %v", opURL, err)
				}
				bp, _ := io.ReadAll(rp.Body)
				rp.Body.Close()
				if bytes.Contains(bp, []byte(`"status":"Succeeded"`)) {
					break
				}
				if time.Now().After(deadline) {
					t.Fatalf("LRO %s did not reach Succeeded within 15s: %s", opURL, bp)
				}
				time.Sleep(100 * time.Millisecond) // SLEEP-CLASS: POLL-STEP (bounded observable poll)
			}
			return
		}
		if resp.StatusCode != 200 && resp.StatusCode != 201 {
			b, _ := io.ReadAll(resp.Body)
			t.Fatalf("ARM PUT %s: status %d body %s", path, resp.StatusCode, b)
		}
	}
	put("/subscriptions/ecourt-sub/resourceGroups/ecourt-rg", `{"location":"eastus"}`)
	put("/subscriptions/ecourt-sub/resourceGroups/ecourt-rg/providers/Microsoft.ServiceBus/namespaces/ecourt-ns",
		`{"location":"eastus","skuName":"Standard"}`)
	put("/subscriptions/ecourt-sub/resourceGroups/ecourt-rg/providers/Microsoft.ServiceBus/namespaces/ecourt-ns/queues/"+queue,
		`{"location":"eastus"}`)
}

// TestWireCourt is the Go port of court_wire.erl leg_amqp/2, verbatim.
func TestWireCourt(t *testing.T) {
	keyB64 := os.Getenv("SMALT_SB_SHARED_KEY")
	if keyB64 == "" {
		keyB64 = sharedKeyFromDevEnv(t)
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(wireHost, wireAMQPPort), 3*time.Second)
	if err != nil {
		t.Skipf("SKIP LOUD: smalt AMQP endpoint %s:%s unreachable (%v) — substrate down; never a fake pass",
			wireHost, wireAMQPPort, err)
	}
	defer conn.Close()
	r := &wireFrameReader{conn: conn}

	uniq := fmt.Sprintf("%d", lane12Uniq())
	q := []byte("ecourt-q-" + uniq)
	ensureQueueARM(t, string(q))
	t.Logf("[leg1] AMQP raw wire :%s queue=%s", wireAMQPPort, q)

	// -- protocol header (SASL layer): byte-exact echo required --
	if _, err := conn.Write([]byte{'A', 'M', 'Q', 'P', 3, 1, 0, 0}); err != nil {
		t.Fatal(err)
	}
	hdr, err := r.readExact(8)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(hdr, []byte("AMQP\x03\x01\x00\x00")) {
		t.Fatalf("fence_violation amqp_sasl_header_echo: expected AMQP\\x03\\x01\\x00\\x00 got %x", hdr)
	}

	// -- server-mechanisms frame: must offer ANONYMOUS --
	typ, mechBody, err := r.readFrame()
	if err != nil {
		t.Fatal(err)
	}
	if typ != 0x01 {
		t.Fatalf("fence_violation expected SASL frame type 0x01 got 0x%02x", typ)
	}
	wireAssertContains(t, []byte("ANONYMOUS"), mechBody, "amqp_sasl_mechanisms_anonymous")

	// -- sasl-init (descriptor 0x41): mechanism=ANONYMOUS, null, null --
	saslInit := wireFrame(0x01, 0, wireDesc(0x41,
		wireEncSym([]byte("ANONYMOUS")),
		[]byte{0x40}, // initial-response: null
		[]byte{0x40}, // hostname: null
	))
	if _, err := conn.Write(saslInit); err != nil {
		t.Fatal(err)
	}
	typ, outcomeBody, err := r.readFrame()
	if err != nil {
		t.Fatal(err)
	}
	if typ != 0x01 {
		t.Fatalf("fence_violation expected SASL outcome frame type 0x01 got 0x%02x", typ)
	}
	// sasl-outcome descriptor 0x44 (pinned by real-SDK census) + code 0
	wireAssertPrefix(t, []byte{0x00, 0x53, 0x44}, outcomeBody, "amqp_sasl_outcome_descriptor_0x44")
	assertSaslOutcomeZero(t, outcomeBody)
	t.Logf("[leg1] SASL ANONYMOUS handshake OK (outcome 0x44 code 0)")

	// -- AMQP layer: header + open + begin --
	if _, err := conn.Write([]byte("AMQP\x00\x01\x00\x00")); err != nil {
		t.Fatal(err)
	}
	hdr2, err := r.readExact(8)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(hdr2, []byte("AMQP\x00\x01\x00\x00")) {
		t.Fatalf("fence_violation amqp_header_echo: expected AMQP\\x00\\x01\\x00\\x00 got %x", hdr2)
	}
	open := wireFrame(0x00, 0, wireDesc(0x10,
		wireEncStr([]byte(wireContainerID)),  // container-id
		[]byte{0x40},                         // hostname
		[]byte{0x70, 0x00, 0x01, 0x00, 0x00}, // max-frame-size 65536
		[]byte{0x40}, []byte{0x40}, []byte{0x40},
		[]byte{0x40}, []byte{0x40}, []byte{0x40},
		[]byte{0x40},
	))
	begin := wireFrame(0x00, 0, wireDesc(0x11,
		[]byte{0x40},                         // remote-channel
		[]byte{0x52, 0x00},                   // next-outgoing-id 0
		[]byte{0x70, 0x00, 0x01, 0x86, 0xA0}, // incoming-window 100000
		[]byte{0x70, 0x00, 0x01, 0x86, 0xA0}, // outgoing-window
		[]byte{0x40},                         // handle-max
	))
	if _, err := conn.Write(wireJoin(open, begin)); err != nil {
		t.Fatal(err)
	}
	_, openBody, err := r.readFrame()
	if err != nil {
		t.Fatal(err)
	}
	wireAssertPrefix(t, []byte{0x00, 0x53, 0x10}, openBody, "amqp_open_descriptor")
	wireAssertContains(t, []byte("smalt-local"), openBody, "amqp_open_container_id")
	_, _, err = r.readFrame() // begin ack
	if err != nil {
		t.Fatal(err)
	}

	// -- attach CBS sender (handle 0) + CBS receiver (handle 1) + flow --
	attS := wireFrame(0x00, 0, wireAttachFrame(0, false, nil, []byte("$cbs")))
	attR := wireFrame(0x00, 0, wireAttachFrame(1, true, []byte("$cbs"), nil))
	flow1 := wireFrame(0x00, 0, wireFlowFrame(1, 200))
	if _, err := conn.Write(wireJoin(attS, attR, flow1)); err != nil {
		t.Fatal(err)
	}
	if err := r.drainToAttachAcks(2); err != nil {
		t.Fatal(err)
	}

	// -- CBS put-token: REAL SAS token, HMAC-SHA256 over sr with dev key --
	token := sasToken(keyB64, "sb://127.0.0.1:5672")
	appProps := wireDescVal(0x74, wireEncMap([][2][]byte{
		{[]byte("operation"), []byte("put-token")},
		{[]byte("type"), []byte("servicebus.windows.net:sastoken")},
		{[]byte("name"), []byte("sb://127.0.0.1:5672")},
	}))
	bodyVal := wireDescVal(0x77, wireEncStr([]byte(token)))
	delID := uint32(time.Now().UnixNano() % 1000)
	transfer := wireFrame(0x00, 0,
		wireDesc(0x14,
			[]byte{0x52, 0x00},                   // handle 0
			wireUint32(delID),                    // delivery-id
			wireEncBin([]byte("ecourt-cbs-1")),   // delivery-tag
			[]byte{0x70, 0x00, 0x00, 0x00, 0x00}, // message-format 0
			[]byte{0x41},                         // settled true
		),
		appProps, bodyVal,
	)
	if _, err := conn.Write(transfer); err != nil {
		t.Fatal(err)
	}
	cbsPayload, err := r.recvTransferPayload(1)
	if err != nil {
		t.Fatal(err)
	}
	wireAssertContains(t, []byte("status-code"), cbsPayload, "cbs_reply_statuscode_marker")
	assertStatus200(t, cbsPayload)
	wireAssertNotContains(t, "INVALID_LOCAL_SAS", cbsPayload, "cbs_no_invalid_sas")
	wireAssertNotContains(t, "UNSUPPORTED_CBS_REQUEST", cbsPayload, "cbs_no_unsupported")
	wireAssertNotContains(t, "CLAIM_CAPACITY", cbsPayload, "cbs_no_capacity")
	t.Logf("[leg1] CBS put-token verified (statusCode 200)")

	// -- queue-scoped put-token (claim keyed by "endpoint/<entity>";
	//    namespace-only claims do not authorize the entity attach) --
	qAud := append(append([]byte("sb://127.0.0.1:5672/"), q...), []byte{}...)
	tokenQ := sasToken(keyB64, string(qAud))
	appPropsQ := wireDescVal(0x74, wireEncMap([][2][]byte{
		{[]byte("operation"), []byte("put-token")},
		{[]byte("type"), []byte("servicebus.windows.net:sastoken")},
		{[]byte("name"), qAud},
	}))
	bodyValQ := wireDescVal(0x77, wireEncStr([]byte(tokenQ)))
	qXferCbs := wireFrame(0x00, 0,
		wireDesc(0x14,
			[]byte{0x52, 0x00},
			wireUint32(delID+1),
			wireEncBin([]byte("ecourt-cbs-2")),
			[]byte{0x70, 0x00, 0x00, 0x00, 0x00},
			[]byte{0x41},
		),
		appPropsQ, bodyValQ,
	)
	if _, err := conn.Write(qXferCbs); err != nil {
		t.Fatal(err)
	}
	cbsPayloadQ, err := r.recvTransferPayload(1)
	if err != nil {
		t.Fatal(err)
	}
	wireAssertContains(t, []byte("status-code"), cbsPayloadQ, "cbs_reply_statuscode_marker")
	assertStatus200(t, cbsPayloadQ)
	t.Logf("[leg1] queue-scoped CBS put-token verified (statusCode 200)")

	// -- queue attach + transfer + disposition accepted --
	attQ := wireFrame(0x00, 0, wireAttachFrame(2, false, nil, q))
	if _, err := conn.Write(attQ); err != nil {
		t.Fatal(err)
	}
	if err := r.drainToAttachAcks(1); err != nil {
		t.Fatal(err)
	}
	qDelID := uint32(time.Now().UnixNano() % 1000)
	qXfer := wireFrame(0x00, 0,
		wireDesc(0x14,
			[]byte{0x52, 0x02},
			wireUint32(qDelID),
			wireEncBin([]byte("ecourt-qtag-1")),
			[]byte{0x70, 0x00, 0x00, 0x00, 0x00},
			[]byte{0x40}, // unsettled: server must settle
		),
		wireDescVal(0x77, wireEncStr([]byte("ecourt-payload-1"))),
	)
	if _, err := conn.Write(qXfer); err != nil {
		t.Fatal(err)
	}
	disp, err := r.recvDisposition()
	if err != nil {
		t.Fatal(err)
	}
	// AMQP performative codes: disposition=0x15 (detach is 0x16 — the
	// byte-observed detach w/ unauthorized-access is what the pre-fix court
	// was mislabeling), end=0x17, close=0x18
	wireAssertPrefix(t, []byte{0x00, 0x53, 0x15}, disp, "queue_disposition_descriptor")
	wireAssertContains(t, []byte{0x00, 0x53, 0x24}, disp, "queue_disposition_accepted")

	// -- clean close --
	end := wireFrame(0x00, 0, wireDesc(0x17, []byte{0x40}))
	closeF := wireFrame(0x00, 0, wireDesc(0x19, []byte{0x40}))
	if _, err := conn.Write(wireJoin(end, closeF)); err != nil {
		t.Fatal(err)
	}
	t.Logf("[leg1] queue attach+transfer+disposition accepted OK")
}

// wireUint32 encodes a uint32 as AMQP uint constructor 0x70.
func wireUint32(v uint32) []byte {
	out := []byte{0x70}
	return binary.BigEndian.AppendUint32(out, v)
}

// lane12Uniq mirrors erlang:unique_integer([positive]) for run-unique names.
func lane12Uniq() int64 {
	return uniqueSeq.Add(1) + time.Now().UnixNano()%1_000_000_000
}

var uniqueSeq atomic.Int64
