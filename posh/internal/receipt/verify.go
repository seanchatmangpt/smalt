package receipt

import (
	"crypto/subtle"
	"encoding/hex"
	"errors"
)

// ErrBadTurnstileHex is returned when a turnstile receipt header is not a
// valid 64-character lowercase/uppercase hexadecimal SHA-256-sized token.
var ErrBadTurnstileHex = errors.New("receipt: turnstile header is not 64 hex chars")

// VerifyTurnstile recomputes the canonical turnstile digest over
// (op, timestampNs, payloadBody) and compares it to headerHex in constant
// time. It rejects any header that is not exactly 64 hex characters.
func VerifyTurnstile(headerHex string, op string, timestampNs uint64, payloadBody []byte) (bool, error) {
	if len(headerHex) != 64 {
		return false, ErrBadTurnstileHex
	}
	decoded, err := hex.DecodeString(headerHex)
	if err != nil {
		return false, ErrBadTurnstileHex
	}
	want := TurnstileReceipt(op, timestampNs, payloadBody)
	ok := subtle.ConstantTimeCompare(decoded, want[:]) == 1
	return ok, nil
}
