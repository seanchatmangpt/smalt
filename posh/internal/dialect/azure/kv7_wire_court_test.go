// kv7 wire court (P-h step 4, v26.10.31 mount step 3): the wire twin of
// wire_court_test.go's law — BYTE FIDELITY IS LOAD-BEARING. Speaks raw
// HTTP to the live smalt substrate (127.0.0.1:8443, the BEAM KvRoutes
// data plane) and pins the kv7 SecretBundle wire law on every face:
//
//   - KD-15 challenge handshake: tokenless 401 + WWW-Authenticate, then
//     resend bearer (tokenless-only clients are premise rot).
//   - KD-78 future-version refusal: api-version=2099-01-01 is a typed
//     400 InvalidApiVersion (monotonic admission would admit anything
//     <= latest — a past-version refusal proves nothing).
//   - KD-03 drop-lists: point faces echo the value, list faces never
//     carry it, versions face echoes value AND version (registered
//     divergence — the face's own law, kv7.Bundles owns it).
//   - guid_version output shape: lowercase dashed RFC-4122 v4 UUID
//     (BEAM KvRoutes.guid_version/0 twin — kv7.GUIDVersion).
//   - KD-184/KD-S4: versions index is NEWEST-FIRST by last write, never
//     lexical UUID order; latest and the index head agree byte for byte.
//
// Twin-oracle leg: the SAME 3-put-1-patch sequence is replayed through
// the posh translate face (family_translate_kv7.go delegation bindings)
// and the key SETS and scalars must be byte-equal to the BEAM wire
// answers — one law, N delegation bindings (KD-03), N faces agreeing.
//
// Substrate down: loud t.Skip — never a fake pass.
package azure

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"smalt.dev/posh/internal/dialect/azure/kv7"
)

const (
	kv7Host     = "127.0.0.1"
	kv7Port     = "8443"
	kv7Timeout  = 15 * time.Second
	kv7APIV     = "7.4"
	kv7VaultRef = "127.0.0.1"
)

// ---------------------------------------------------------------------------
// wire helpers
// ---------------------------------------------------------------------------

func kv7BaseURL() string { return "http://" + kv7Host + ":" + kv7Port }

// kv7SubstrateUp is the loud-skip gate: a dial that cannot connect means the
// substrate is DOWN — the court skips loudly, never fake-passes.
func kv7SubstrateUp(t *testing.T) {
	t.Helper()
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(kv7Host, kv7Port), 3*time.Second)
	if err != nil {
		t.Skipf("SKIP LOUD: smalt KV data plane %s:%s unreachable (%v) — substrate down; never a fake pass",
			kv7Host, kv7Port, err)
	}
	conn.Close()
}

// kv7MintBearer mints the court's own HS256 bearer. The substrate is booted
// with a court-supplied :sts_signing_secret (>= 32 bytes — StsKey.hs_signer
// accepts it) because the WO-32 cordon removed the BEAM 9443/9444 listeners:
// the STS mint wire face (dialect #0, GAP-01) has no loopback mount in the
// cordon window, so the court signs directly with the verifier's own secret
// — the SAME secret bearer.ex verifies with, never a bypass of the claims
// law (aud/iss/exp/nbf are validated fail-closed server-side).
func kv7MintBearer(t *testing.T) string {
	t.Helper()
	secret := os.Getenv("SMALT_STS_SIGNING_SECRET")
	if len(secret) < 32 {
		t.Skipf("SKIP LOUD: SMALT_STS_SIGNING_SECRET unset or <32 bytes — the cordon-window court cannot mint a bearer; never a fake pass")
	}
	now := time.Now().Unix()
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"HS256","typ":"JWT"}`))
	claims := fmt.Sprintf(`{"aud":"https://management.azure.com","iss":"https://login.microsoftonline.com/smalt-home","sub":"ecourt","exp":%d}`, now+900)
	payload := base64.RawURLEncoding.EncodeToString([]byte(claims))
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(header + "." + payload))
	sig := base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
	return header + "." + payload + "." + sig
}

// kv7Do performs the KD-15 challenge handshake per request family: the
// tokenless request must answer 401 + WWW-Authenticate (the challenge the
// real SDKs' ChallengeAuthPolicy consumes), then the bearer resend must
// succeed. `wantStatus` is the expected POST-challenge status.
func kv7Do(t *testing.T, method, path, body string, wantStatus int) map[string]any {
	t.Helper()
	// leg A: tokenless — KD-15 challenge (typed 401, never a silent admit)
	req0, err := http.NewRequest(method, kv7BaseURL()+path, kv7Body(body))
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	if body != "" {
		req0.Header.Set("content-type", "application/json")
	}
	resp0, err := http.DefaultClient.Do(req0)
	if err != nil {
		t.Skipf("SKIP LOUD: kv7 plane %s unreachable (%v) — substrate down; never a fake pass", kv7BaseURL(), err)
	}
	b0, _ := io.ReadAll(resp0.Body)
	resp0.Body.Close()
	if resp0.StatusCode != http.StatusUnauthorized {
		t.Fatalf("KD-15 fence_violation %s %s: tokenless request answered %d (want 401 challenge) body %s",
			method, path, resp0.StatusCode, b0)
	}
	if resp0.Header.Get("WWW-Authenticate") == "" {
		t.Fatalf("KD-15 fence_violation %s %s: 401 carries no WWW-Authenticate challenge header", method, path)
	}

	// leg B: bearer resend — the handshake completes.
	req, err := http.NewRequest(method, kv7BaseURL()+path, kv7Body(body))
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	if body != "" {
		req.Header.Set("content-type", "application/json")
	}
	req.Header.Set("authorization", "Bearer "+kv7Token(t))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Skipf("SKIP LOUD: kv7 plane %s unreachable (%v) — substrate down; never a fake pass", kv7BaseURL(), err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != wantStatus {
		t.Fatalf("fence_violation %s %s: status %d (want %d) body %s", method, path, resp.StatusCode, wantStatus, b)
	}
	var out map[string]any
	if len(b) > 0 {
		if err := json.Unmarshal(b, &out); err != nil {
			t.Fatalf("%s %s: non-JSON body: %s", method, path, b)
		}
	}
	return out
}

var kv7TokCache string

func kv7Token(t *testing.T) string {
	t.Helper()
	if kv7TokCache == "" {
		kv7TokCache = kv7MintBearer(t)
	}
	return kv7TokCache
}

func kv7Body(body string) io.Reader {
	if body == "" {
		return nil
	}
	return strings.NewReader(body)
}

// kv7KeySet extracts the JSON key set of an object body.
func kv7KeySet(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}

// kv7AssertNoBookkeeping pins the bookkeeping never-leaves-the-vault law:
// none of the internal keys (KD-S3/KD-S4) may appear on ANY wire face.
func kv7AssertNoBookkeeping(t *testing.T, m map[string]any, face string) {
	t.Helper()
	for _, k := range kv7.BookkeepingKeys {
		if _, ok := m[k]; ok {
			t.Fatalf("fence_violation %s: bookkeeping key %q leaked onto the wire: %v", face, k, kv7KeySet(m))
		}
	}
}

// ---------------------------------------------------------------------------
// leg-kv7-live
// ---------------------------------------------------------------------------

func TestKv7WireCourt(t *testing.T) {
	kv7SubstrateUp(t)
	uniq := fmt.Sprintf("%d", lane12Uniq())
	name := "ecourt-s-" + uniq
	t.Logf("[kv7] leg-kv7-live :%s secret=%s", kv7Port, name)

	// -- KD-15 challenge handshake + PUT (first create -> 201) --------------
	put1 := kv7Do(t, http.MethodPut, "/secrets/"+name+"?api-version="+kv7APIV,
		`{"value":"ecourt-v1"}`, http.StatusCreated)
	kv7AssertNoBookkeeping(t, put1, "put-face")
	if put1["value"] != "ecourt-v1" {
		t.Fatalf("fence_violation put-face: value not echoed: %v", put1)
	}
	id1, _ := put1["id"].(string)
	if !strings.HasPrefix(id1, "https://"+kv7VaultRef+".vault.azure.net/secrets/"+name+"/") {
		t.Fatalf("fence_violation put-face: id grammar %q", id1)
	}
	v1 := kv7VersionFromID(t, id1)
	t.Logf("[kv7] PUT#1 201 version=%s", v1)

	// -- point GET: value present, bookkeeping never leaks ------------------
	get1 := kv7Do(t, http.MethodGet, "/secrets/"+name+"?api-version="+kv7APIV, "", http.StatusOK)
	kv7AssertNoBookkeeping(t, get1, "point-get-face")
	if get1["value"] != "ecourt-v1" {
		t.Fatalf("fence_violation point-get-face: value %v (want ecourt-v1)", get1["value"])
	}
	if get1["id"] != id1 {
		t.Fatalf("fence_violation point-get-face: id %v != put id %s (latest must resolve the last write)", get1["id"], id1)
	}

	// -- KD-78 future-version refusal pin: 2099-01-01 is a typed 400 -------
	bad := kv7Do(t, http.MethodGet, "/secrets/"+name+"?api-version=2099-01-01", "", http.StatusBadRequest)
	errObj, _ := bad["error"].(map[string]any)
	if errObj["code"] != "InvalidApiVersion" {
		t.Fatalf("fence_violation KD-78: refusal code %v (want InvalidApiVersion)", errObj["code"])
	}
	t.Logf("[kv7] KD-78 future-version refusal: 400 InvalidApiVersion")

	// -- version-history accumulation: PUT#2/PUT#3 (re-set -> 200) ---------
	put2 := kv7Do(t, http.MethodPut, "/secrets/"+name+"?api-version="+kv7APIV,
		`{"value":"ecourt-v2"}`, http.StatusOK)
	id2, _ := put2["id"].(string)
	v2 := kv7VersionFromID(t, id2)
	put3 := kv7Do(t, http.MethodPut, "/secrets/"+name+"?api-version="+kv7APIV,
		`{"value":"ecourt-v3"}`, http.StatusOK)
	id3, _ := put3["id"].(string)
	v3 := kv7VersionFromID(t, id3)
	if v1 == v2 || v2 == v3 {
		t.Fatalf("fence_violation versions: mints collided %s %s %s", v1, v2, v3)
	}

	// -- versions face: value AND version per entry (KD-S3 registered law),
	//    index NEWEST-FIRST (KD-S4: never lexical UUID order) ---------------
	vers := kv7Do(t, http.MethodGet, "/secrets/"+name+"/versions?api-version="+kv7APIV, "", http.StatusOK)
	versArr, _ := vers["value"].([]any)
	if len(versArr) != 3 {
		t.Fatalf("fence_violation versions-face: %d entries (want 3)", len(versArr))
	}
	wantOrder := []string{v3, v2, v1} // newest-first by last write
	for i, e := range versArr {
		row, _ := e.(map[string]any)
		if row["value"] == nil {
			t.Fatalf("fence_violation versions-face[%d]: value absent (KD-S3 law: this face echoes the value)", i)
		}
		if row["version"] == nil {
			t.Fatalf("fence_violation versions-face[%d]: version member absent", i)
		}
		if row["version"] != wantOrder[i] {
			t.Fatalf("fence_violation KD-S4 versions-face[%d]: version %v (want %s — newest-first, never lexical UUID order)",
				i, row["version"], wantOrder[i])
		}
		kv7AssertNoBookkeeping(t, row, "versions-face")
	}

	// -- last-write-latest resolution: latest == index head, byte for byte --
	latest := kv7Do(t, http.MethodGet, "/secrets/"+name+"?api-version="+kv7APIV, "", http.StatusOK)
	if latest["id"] != id3 {
		t.Fatalf("fence_violation KD-S4 latest: id %v != last write %s", latest["id"], id3)
	}
	headRow, _ := versArr[0].(map[string]any)
	if headRow["id"] != id3 || headRow["value"] != "ecourt-v3" {
		t.Fatalf("fence_violation KD-S4 index-head: %v != last-write bundle %s/ecourt-v3", headRow, id3)
	}

	// -- PATCH (attributes-only; value never rotates) ------------------------
	patch := kv7Do(t, http.MethodPatch, "/secrets/"+name+"?api-version="+kv7APIV,
		`{"attributes":{"enabled":false}}`, http.StatusOK)
	if patch["value"] != "ecourt-v3" {
		t.Fatalf("fence_violation patch-face: value %v (want ecourt-v3 — PATCH never rotates the value)", patch["value"])
	}
	patchAttrs, _ := patch["attributes"].(map[string]any)
	if patchAttrs["enabled"] != false {
		t.Fatalf("fence_violation patch-face: attributes.enabled %v (want false)", patchAttrs["enabled"])
	}
	getAfter := kv7Do(t, http.MethodGet, "/secrets/"+name+"?api-version="+kv7APIV, "", http.StatusOK)
	if getAfter["value"] != "ecourt-v3" {
		t.Fatalf("fence_violation post-patch point-get: value %v (want ecourt-v3)", getAfter["value"])
	}
	attrsAfter, _ := getAfter["attributes"].(map[string]any)
	if attrsAfter["enabled"] != false {
		t.Fatalf("fence_violation post-patch point-get: enabled %v (want false — patch persisted)", attrsAfter["enabled"])
	}

	// -- list face: bundles NEVER carry the value (KD-03 drop-list) ---------
	list := kv7Do(t, http.MethodGet, "/secrets?api-version="+kv7APIV, "", http.StatusOK)
	listArr, _ := list["value"].([]any)
	found := false
	for _, e := range listArr {
		row, _ := e.(map[string]any)
		id, _ := row["id"].(string)
		if strings.HasPrefix(id, "https://"+kv7VaultRef+".vault.azure.net/secrets/"+name+"/") {
			found = true
			if _, ok := row["value"]; ok {
				t.Fatalf("fence_violation KD-03 list-face: value present on a list bundle: %v", row)
			}
			kv7AssertNoBookkeeping(t, row, "list-face")
		}
	}
	if !found {
		t.Fatalf("fence_violation list-face: secret %s absent from the list", name)
	}

	// -- clean up: soft-delete (KD-102) --------------------------------------
	del := kv7Do(t, http.MethodDelete, "/secrets/"+name+"?api-version="+kv7APIV, "", http.StatusOK)
	if _, ok := del["recoveryId"]; !ok {
		t.Fatalf("fence_violation delete-face: deleted bundle lacks recoveryId: %v", del)
	}

	t.Logf("[kv7] leg-kv7-live PASS: KD-15 handshake, KD-78 refusal, version accumulation, newest-first latest, PATCH, KD-03 list drop")
}

func kv7VersionFromID(t *testing.T, id string) string {
	t.Helper()
	_, name, ver, err := kv7.ParseDataPlaneID(id)
	if err != nil || name == "" || ver == "" {
		t.Fatalf("fence_violation id grammar: %q (%v)", id, err)
	}
	kv7AssertGUIDVersion(t, ver)
	return ver
}

// kv7AssertGUIDVersion pins the guid_version grammar: lowercase dashed
// RFC-4122 version-4 (8-4-4-4-12 lower-hex, version nibble 4, variant 10).
func kv7AssertGUIDVersion(t *testing.T, ver string) {
	t.Helper()
	if !kv7.IsGUIDVersion(ver) {
		t.Fatalf("fence_violation guid_version grammar: %q", ver)
	}
	if ver != strings.ToLower(ver) {
		t.Fatalf("fence_violation guid_version: not lowercase: %q", ver)
	}
	if ver[14] != '4' {
		t.Fatalf("fence_violation guid_version: version nibble %c (want 4, RFC-4122 v4): %q", ver[14], ver)
	}
	switch ver[19] {
	case '8', '9', 'a', 'b':
	default:
		t.Fatalf("fence_violation guid_version: variant nibble %c (want 8/9/a/b): %q", ver[19], ver)
	}
}

// ---------------------------------------------------------------------------
// twin-oracle: BEAM wire (8443) vs posh translate face — same sequence,
// key SETS and scalars byte-equal (one law, N delegation bindings).
// ---------------------------------------------------------------------------

// kv7CanonicalRow is the full store-row shape the BEAM faces project: the
// exact member set a kv7 store row carries (egress_router.ex PUT arm).
func kv7CanonicalRow(value, id string, enabled bool, ver string) map[string]any {
	return map[string]any{
		"value":       value,
		"id":          id,
		"attributes":  map[string]any{"enabled": enabled, "created": 1700000000, "updated": 1700000001},
		"version":     ver,
		"created_seq": int64(42),
		"versions":    []string{ver},
	}
}

func TestKv7TwinOracle(t *testing.T) {
	kv7SubstrateUp(t)
	uniq := fmt.Sprintf("%d", lane12Uniq())
	name := "ecourt-twin-" + uniq
	t.Logf("[kv7] twin-oracle secret=%s", name)

	// -- the 3-put-1-patch sequence, BEAM face -------------------------------
	type step struct {
		method, path, body string
		status             int
	}
	seq := []step{
		{http.MethodPut, "/secrets/" + name + "?api-version=" + kv7APIV, `{"value":"twin-v1"}`, http.StatusCreated},
		{http.MethodPut, "/secrets/" + name + "?api-version=" + kv7APIV, `{"value":"twin-v2"}`, http.StatusOK},
		{http.MethodPut, "/secrets/" + name + "?api-version=" + kv7APIV, `{"value":"twin-v3"}`, http.StatusOK},
		{http.MethodPatch, "/secrets/" + name + "?api-version=" + kv7APIV, `{"attributes":{"enabled":false}}`, http.StatusOK},
	}
	beamBodies := make([]map[string]any, 0, len(seq))
	for _, s := range seq {
		beamBodies = append(beamBodies, kv7Do(t, s.method, s.path, s.body, s.status))
	}

	// -- the SAME sequence, posh translate face ------------------------------
	// For each BEAM answer, rebuild the store row it projected FROM (the
	// point faces drop only "version" — re-attach it from the bundle id) and
	// render through the posh delegation binding for that op. Key sets and
	// scalars must agree byte for byte.
	for i, s := range seq {
		op := map[string]string{
			http.MethodPut:   "azure.kv7.secrets.put",
			http.MethodPatch: "azure.kv7.secrets.patch",
		}[s.method]
		h, ok := Kv7TranslateFor(op)
		if !ok {
			t.Fatalf("twin-oracle: translate binding missing for %s", op)
		}
		beam := beamBodies[i]
		beamID, _ := beam["id"].(string)
		ver := strings.TrimPrefix(beamID, "https://"+kv7VaultRef+".vault.azure.net/secrets/"+name+"/")
		val, _ := beam["value"].(string)
		// Reconstruct the store row the BEAM face projected FROM: the point
		// faces drop only "version" (egress_router.ex public_secret_record),
		// so re-attach it from the bundle id; attributes (incl. the patched
		// enabled state) ride the BEAM body verbatim.
		beamAttrs, _ := beam["attributes"].(map[string]any)
		row := kv7CanonicalRow(val, beamID, beamAttrs["enabled"] == true, ver)
		if s.method == http.MethodPatch {
			// patch_secret_record law (secrets.ex): the PATCH arm puts a
			// "tags" member on the record UNCONDITIONALLY (merged {} when
			// the client sends none) — the store row the posh patch face
			// projects therefore always carries tags.
			row["tags"] = map[string]any{}
		}
		status, got, err := h(map[string]string{}, row)
		if err != nil || status != 200 {
			t.Fatalf("twin-oracle %s: status %d err %v", op, status, err)
		}
		if len(got) != len(beam) {
			t.Fatalf("twin-oracle %s: key-set size %d != BEAM wire %d (got %v beam %v)",
				op, len(got), len(beam), kv7KeySet(got), kv7KeySet(beam))
		}
		for k, v := range beam {
			gv, ok := got[k]
			if !ok {
				t.Fatalf("twin-oracle %s: posh face lacks key %q (BEAM wire has it)", op, k)
			}
			// scalar equality: value/id byte-equal; attributes compared on
			// the enabled scalar (created/updated are wall-clock on BEAM).
			switch k {
			case "value", "id":
				if fmt.Sprintf("%v", gv) != fmt.Sprintf("%v", v) {
					t.Fatalf("twin-oracle %s: %s %v != BEAM %v", op, k, gv, v)
				}
			case "attributes":
				ga, _ := gv.(map[string]any)
				ba, _ := v.(map[string]any)
				if ga["enabled"] != ba["enabled"] {
					t.Fatalf("twin-oracle %s: attributes.enabled %v != BEAM %v", op, ga["enabled"], ba["enabled"])
				}
			}
		}
		// bookkeeping never surfaces on the posh face either.
		kv7AssertNoBookkeeping(t, got, "posh-"+op)
	}

	// versions face across both: the BEAM /versions entries rendered through
	// the posh versions binding must keep value AND version, drop the rest.
	vers := kv7Do(t, http.MethodGet, "/secrets/"+name+"/versions?api-version="+kv7APIV, "", http.StatusOK)
	versArr, _ := vers["value"].([]any)
	if len(versArr) < 3 {
		t.Fatalf("twin-oracle versions: %d entries (want >=3)", len(versArr))
	}
	hv, ok := Kv7TranslateFor("azure.kv7.secrets.versions")
	if !ok {
		t.Fatalf("twin-oracle: versions binding missing")
	}
	for i, e := range versArr {
		row, _ := e.(map[string]any)
		// rebuild the store row: versions-face bundles keep value+version but
		// drop created_seq/is_version_row/versions — re-attach the internals.
		full := map[string]any{}
		for k, v := range row {
			full[k] = v
		}
		full["created_seq"] = int64(i)
		full["is_version_row"] = true
		verStr, _ := row["version"].(string)
		full["versions"] = []string{verStr}
		_, gotEnv, err := hv(map[string]string{}, full)
		if err != nil {
			t.Fatalf("twin-oracle versions[%d]: %v", i, err)
		}
		arr, _ := gotEnv["value"].([]any)
		if len(arr) != 1 {
			t.Fatalf("twin-oracle versions[%d]: posh list envelope %v (want exactly one bundle)", i, kv7KeySet(gotEnv))
		}
		got, _ := arr[0].(map[string]any)
		if len(got) != len(row) {
			t.Fatalf("twin-oracle versions[%d]: key-set %v != BEAM %v", i, kv7KeySet(got), kv7KeySet(row))
		}
		for k, v := range row {
			if gv, ok := got[k]; !ok || fmt.Sprintf("%v", gv) != fmt.Sprintf("%v", v) {
				t.Fatalf("twin-oracle versions[%d]: %s %v != BEAM %v", i, k, gv, v)
			}
		}
	}

	// list face across both: list bundles carry NO value on either face.
	list := kv7Do(t, http.MethodGet, "/secrets?api-version="+kv7APIV, "", http.StatusOK)
	listArr, _ := list["value"].([]any)
	hl, ok := Kv7TranslateFor("azure.kv7.secrets.list")
	if !ok {
		t.Fatalf("twin-oracle: list binding missing")
	}
	for _, e := range listArr {
		row, _ := e.(map[string]any)
		id, _ := row["id"].(string)
		if !strings.HasPrefix(id, "https://"+kv7VaultRef+".vault.azure.net/secrets/"+name+"/") {
			continue
		}
		// Reconstruct the store row from the BEAM list entry itself (the
		// list face drops value + version; tags survives if the record
		// carries it), then add the value + bookkeeping the list face must
		// DROP — proving the drop-list, not an absent input.
		full := map[string]any{"id": row["id"], "attributes": row["attributes"],
			"value": "SHOULD-BE-DROPPED", "version": "v", "created_seq": int64(1),
			"versions": []string{"v"}, "is_version_row": true}
		if tags, ok := row["tags"]; ok {
			full["tags"] = tags
		}
		_, gotEnv, err := hl(map[string]string{}, full)
		if err != nil {
			t.Fatalf("twin-oracle list: %v", err)
		}
		arr, _ := gotEnv["value"].([]any)
		if len(arr) != 1 {
			t.Fatalf("twin-oracle list: posh list envelope %v (want exactly one bundle)", kv7KeySet(gotEnv))
		}
		got, _ := arr[0].(map[string]any)
		if _, ok := got["value"]; ok {
			t.Fatalf("twin-oracle KD-03: posh list face echoed the value: %v", got)
		}
		if len(got) != len(row) {
			t.Fatalf("twin-oracle list: key-set %v != BEAM %v", kv7KeySet(got), kv7KeySet(row))
		}
	}

	// cleanup: soft delete
	kv7Do(t, http.MethodDelete, "/secrets/"+name+"?api-version="+kv7APIV, "", http.StatusOK)
	t.Logf("[kv7] twin-oracle PASS: 3-put-1-patch key sets + scalars byte-equal across BEAM wire and posh translate faces")
}

// ---------------------------------------------------------------------------
// offline pinion: the per-face drop-list law itself (shim-court witness).
// Lives in the same file as the wire court so the shim court's BEFORE/AFTER
// witnesses exercise the SAME compiled law the wire court pins live.
// ---------------------------------------------------------------------------

func TestKv7PinionFacesByteLaw(t *testing.T) {
	t.Parallel()
	row := kv7CanonicalRow("pinion-v", "https://v.vault.azure.net/secrets/n/vtag", true, "vtag")

	cases := []struct {
		face        string
		wantKeys    []string
		wantPresent []string
		wantAbsent  []string
	}{
		{face: kv7.FacePointGetPatch, wantPresent: []string{"value"}, wantAbsent: []string{"version", "versions", "created_seq", "is_version_row"}},
		{face: kv7.FaceList, wantAbsent: []string{"value", "version", "versions", "created_seq", "is_version_row"}},
		{face: kv7.FaceVersionsList, wantPresent: []string{"value", "version"}, wantAbsent: []string{"versions", "created_seq", "is_version_row"}},
		{face: kv7.FaceEngineSoftDel, wantAbsent: []string{"value", "is_deleted_secret", "versions", "version_rows", "created_seq"}},
		{face: kv7.FaceARM, wantPresent: []string{"value", "version"}, wantAbsent: []string{}},
	}
	for _, tc := range cases {
		out, err := kv7.RenderBundle(tc.face, row)
		if err != nil {
			t.Fatalf("face %s: %v", tc.face, err)
		}
		for _, k := range tc.wantPresent {
			if _, ok := out[k]; !ok {
				t.Fatalf("fence_violation face %s: key %q absent (want present): %v", tc.face, k, kv7KeySet(out))
			}
		}
		for _, k := range tc.wantAbsent {
			if _, ok := out[k]; ok {
				t.Fatalf("fence_violation face %s: key %q present (want dropped): %v", tc.face, k, kv7KeySet(out))
			}
		}
	}
	if _, err := kv7.RenderBundle("no-such-face", row); err == nil {
		t.Fatalf("fence_violation: unknown face admitted silently")
	}
}

// TestKv7GUIDVersionPinion pins the posh guid_version twin against the same
// RFC-4122 v4 grammar the BEAM face answers on the wire.
func TestKv7GUIDVersionPinion(t *testing.T) {
	t.Parallel()
	for i := 0; i < 50; i++ {
		kv7AssertGUIDVersion(t, kv7.GUIDVersion())
	}
}
