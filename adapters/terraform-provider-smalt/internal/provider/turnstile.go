// Turnstile receipt verification on the TF apply path — closes the gaps/26
// residue named in docs/jira/posh/v26.10.31/gaps/14-turnstile-neutrality.md
// (dialect-participation contract clause 2): the provider previously
// discardec the X-Smalt-Receipt-Turnstile / X-Smalt-Receipt-Timestamp header
// pair on mutation responses; enforcement was emit-only on that path.
//
// Additive, not a wire change: this is client-side VERIFICATION of headers
// the smalt gateway already emits; no request bytes, path, verb, or header
// sent by the provider change, so the zero-provider-code-change bar's WIRE
// behavior is untouched (reads are stamp-only and skip verification).
//
// Fail-closed: absent headers on a non-GET response are a verification
// failure, not a bypass. No env opt-out exists — the neutrality doc (gaps/14)
// sanctions none.
package provider

import (
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"strconv"
)

// Headers carrying the smalt receipt turnstile (Elixir lane contract,
// receipt_turnstile.ex:112-113).
const (
	turnstileHeader   = "X-Smalt-Receipt-Turnstile"
	turnstileTSHeader = "X-Smalt-Receipt-Timestamp"
)

// turnstileOp is the canonical op string bound into every ARM turnstile
// (must equal armclient.TurnstileOp / the gateway fence's op).
const turnstileOp = "arm.request"

// Typed sentinel errors — callers branch on errors.Is, not string matching.
var (
	// errTurnstile is returned (wrapped) when the header pair is present but
	// fails verification against the request body (tampered digest, bad hex,
	// bad timestamp).
	errTurnstile = errors.New("smalt receipt turnstile verification failed")
	// errTurnstileMissing is returned when a non-GET response carries neither
	// turnstile header — a fail-closed refusal, never a silent bypass.
	errTurnstileMissing = errors.New("smalt receipt turnstile missing on mutating response")
)

// verifyTurnstileResponse verifies the turnstile header pair on a mutation
// response against the raw request body. GETs are stamp-only and exempt
// (gaps/14 dialect contract clause 1: "GET/read paths are stamp-only").
//
// Cases:
//   - both headers absent on non-GET -> errTurnstileMissing (fail-closed)
//   - timestamp header unparsable    -> errTurnstile (wrapped)
//   - header not 64 hex / bad hex    -> errTurnstile (wrapped)
//   - constant-time digest mismatch  -> errTurnstile
func verifyTurnstileResponse(method string, hdr http.Header, requestBody []byte) error {
	if method == http.MethodGet {
		return nil
	}
	headerHex := hdr.Get(turnstileHeader)
	tsHeader := hdr.Get(turnstileTSHeader)
	if headerHex == "" && tsHeader == "" {
		return fmt.Errorf("%w (%s %s)", errTurnstileMissing, method, "ARM mutation")
	}
	ts, err := strconv.ParseUint(tsHeader, 10, 64)
	if err != nil {
		return fmt.Errorf("%w: bad %s header %q", errTurnstile, turnstileTSHeader, tsHeader)
	}
	if len(headerHex) != 64 {
		return fmt.Errorf("%w: %s is not 64 hex chars", errTurnstile, turnstileHeader)
	}
	decoded, err := hex.DecodeString(headerHex)
	if err != nil {
		return fmt.Errorf("%w: %s is not valid hex", errTurnstile, turnstileHeader)
	}
	want := TurnstileReceipt(turnstileOp, ts, requestBody)
	if subtle.ConstantTimeCompare(decoded, want[:]) != 1 {
		return fmt.Errorf("%w: digest mismatch over (%q, %d, %d body bytes)", errTurnstile, turnstileOp, ts, len(requestBody))
	}
	return nil
}
