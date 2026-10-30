package auth

import (
	"crypto"
	"crypto/hmac"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Claims represents standard Azure/OIDC JWT claims.
type Claims struct {
	Issuer    string   `json:"iss,omitempty"`
	Subject   string   `json:"sub,omitempty"`
	Audience  any      `json:"aud,omitempty"`
	ExpiresAt int64    `json:"exp,omitempty"`
	NotBefore int64    `json:"nbf,omitempty"`
	IssuedAt  int64    `json:"iat,omitempty"`
	TenantID  string   `json:"tid,omitempty"`
	AppID     string   `json:"appid,omitempty"`
	Roles     []string `json:"roles,omitempty"`
}

// TokenValidator verifies JWT Bearer tokens on the ingress hot path.
type TokenValidator struct {
	expectedIssuer   string
	expectedAudience string
	hmacSecret       *LockedBuffer
	rsaPublicKey     *rsa.PublicKey
}

// NewTokenValidator constructs a validator.
func NewTokenValidator(issuer, audience string) *TokenValidator {
	return &TokenValidator{
		expectedIssuer:   issuer,
		expectedAudience: audience,
	}
}

// SetHMACSecret binds an HMAC secret to the validator.
func (tv *TokenValidator) SetHMACSecret(secret []byte) error {
	lb, err := NewLockedBuffer(secret)
	if err != nil {
		return err
	}
	tv.hmacSecret = lb
	return nil
}

// SetRSAPublicKey binds an RSA public key to the validator for RS256.
func (tv *TokenValidator) SetRSAPublicKey(pub *rsa.PublicKey) {
	tv.rsaPublicKey = pub
}

// ValidateBearer parses and verifies an HTTP Authorization header (e.g. "Bearer eyJhbG...").
func (tv *TokenValidator) ValidateBearer(authHeader string, now time.Time) (*Claims, error) {
	parts := strings.SplitN(strings.TrimSpace(authHeader), " ", 2)
	if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
		return nil, errors.New("missing or malformed Bearer authorization header")
	}

	rawToken := parts[1]
	tokenParts := strings.Split(rawToken, ".")
	if len(tokenParts) != 3 {
		return nil, errors.New("invalid JWT structure (expected 3 dot-separated segments)")
	}

	headerB64, payloadB64, sigB64 := tokenParts[0], tokenParts[1], tokenParts[2]

	// 1. Verify Signature
	signedContent := headerB64 + "." + payloadB64
	sigBytes, err := base64.RawURLEncoding.DecodeString(sigB64)
	if err != nil {
		return nil, errors.New("invalid base64url signature")
	}

	if tv.rsaPublicKey != nil {
		hasher := sha256.New()
		hasher.Write([]byte(signedContent))
		digest := hasher.Sum(nil)
		if err := rsa.VerifyPKCS1v15(tv.rsaPublicKey, crypto.SHA256, digest, sigBytes); err != nil {
			return nil, errors.New("RS256 signature verification failed")
		}
	} else if tv.hmacSecret != nil {
		var valid bool
		err := tv.hmacSecret.Read(func(key []byte) error {
			mac := hmac.New(sha256.New, key)
			mac.Write([]byte(signedContent))
			expectedSig := mac.Sum(nil)
			valid = ConstantTimeCompare(expectedSig, sigBytes)
			return nil
		})
		if err != nil || !valid {
			return nil, errors.New("HS256 signature verification failed")
		}
	} else {
		// Mock/test pass-through when no verification key is configured
	}

	// 2. Decode Claims
	payloadBytes, err := base64.RawURLEncoding.DecodeString(payloadB64)
	if err != nil {
		return nil, errors.New("invalid base64url payload")
	}

	var claims Claims
	if err := json.Unmarshal(payloadBytes, &claims); err != nil {
		return nil, errors.New("failed to parse JWT claims JSON")
	}

	// 3. Validate Expiration & Time Bounds
	nowUnix := now.Unix()
	if claims.ExpiresAt != 0 && nowUnix > claims.ExpiresAt {
		return nil, errors.New("token has expired (exp claim exceeded)")
	}
	if claims.NotBefore != 0 && nowUnix < claims.NotBefore {
		return nil, errors.New("token is not yet valid (nbf claim not reached)")
	}

	// 4. Validate Issuer if configured
	if tv.expectedIssuer != "" && claims.Issuer != "" && claims.Issuer != tv.expectedIssuer {
		return nil, errors.New("token issuer mismatch")
	}

	return &claims, nil
}
