package auth_test

import (
	"crypto"
	"crypto/hmac"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
	"smalt.dev/posh/internal/auth"
)

func TestMemguard_Zeroization(t *testing.T) {
	t.Parallel()

	secret := []byte("super-secret-key-1234567890")
	lb, err := auth.NewLockedBuffer(secret)
	require.NoError(t, err)

	err = lb.Read(func(b []byte) error {
		require.Equal(t, secret, b)
		return nil
	})
	require.NoError(t, err)

	lb.Destroy()
	require.True(t, lb.IsDestroyed())

	err = lb.Read(func(b []byte) error {
		return nil
	})
	require.Error(t, err)
}

func TestTokenValidator_HS256(t *testing.T) {
	t.Parallel()

	secret := []byte("very-secure-hmac-shared-key-256-bit")
	tv := auth.NewTokenValidator("https://sts.windows.net/my-tenant/", "https://management.azure.com/")
	err := tv.SetHMACSecret(secret)
	require.NoError(t, err)

	now := time.Now()
	claims := auth.Claims{
		Issuer:    "https://sts.windows.net/my-tenant/",
		Subject:   "user-101",
		TenantID:  "my-tenant",
		ExpiresAt: now.Add(1 * time.Hour).Unix(),
		NotBefore: now.Add(-5 * time.Minute).Unix(),
	}

	header := map[string]string{"alg": "HS256", "typ": "JWT"}
	hJSON, _ := json.Marshal(header)
	cJSON, _ := json.Marshal(claims)

	hB64 := base64.RawURLEncoding.EncodeToString(hJSON)
	cB64 := base64.RawURLEncoding.EncodeToString(cJSON)
	signedContent := hB64 + "." + cB64

	mac := hmac.New(sha256.New, secret)
	mac.Write([]byte(signedContent))
	sig := mac.Sum(nil)
	sigB64 := base64.RawURLEncoding.EncodeToString(sig)

	token := "Bearer " + signedContent + "." + sigB64

	// Act
	parsed, err := tv.ValidateBearer(token, now)
	require.NoError(t, err)
	require.Equal(t, "user-101", parsed.Subject)
	require.Equal(t, "my-tenant", parsed.TenantID)

	// Tampered token fails
	tampered := "Bearer " + signedContent + ".invalidSig"
	_, err = tv.ValidateBearer(tampered, now)
	require.Error(t, err)

	// Expired token fails
	pastTime := now.Add(2 * time.Hour)
	_, err = tv.ValidateBearer(token, pastTime)
	require.Error(t, err)
}

func TestTokenValidator_RS256(t *testing.T) {
	t.Parallel()

	privKey, err := rsa.GenerateKey(rand.Reader, 2048)
	require.NoError(t, err)

	tv := auth.NewTokenValidator("https://login.microsoftonline.com/tenant-123/v2.0", "")
	tv.SetRSAPublicKey(&privKey.PublicKey)

	now := time.Now()
	claims := auth.Claims{
		Issuer:    "https://login.microsoftonline.com/tenant-123/v2.0",
		Subject:   "service-principal-999",
		ExpiresAt: now.Add(30 * time.Minute).Unix(),
	}

	hJSON, _ := json.Marshal(map[string]string{"alg": "RS256", "typ": "JWT"})
	cJSON, _ := json.Marshal(claims)

	hB64 := base64.RawURLEncoding.EncodeToString(hJSON)
	cB64 := base64.RawURLEncoding.EncodeToString(cJSON)
	signedContent := hB64 + "." + cB64

	hasher := sha256.New()
	hasher.Write([]byte(signedContent))
	digest := hasher.Sum(nil)

	sig, err := rsa.SignPKCS1v15(rand.Reader, privKey, crypto.SHA256, digest)
	require.NoError(t, err)

	token := "Bearer " + signedContent + "." + base64.RawURLEncoding.EncodeToString(sig)

	parsed, err := tv.ValidateBearer(token, now)
	require.NoError(t, err)
	require.Equal(t, "service-principal-999", parsed.Subject)
}
