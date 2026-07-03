package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"math/big"
	"strings"
	"testing"
)

func TestValidToken(t *testing.T) {
	valid := strings.Repeat("a1b2", 16) // 64 hex chars
	cases := map[string]bool{
		valid:                    true,
		strings.Repeat("f", 64):  true,
		strings.Repeat("f", 16):  false, // too short
		"nothex" + valid:         false, // non-hex chars
		"":                       false,
	}
	for tok, want := range cases {
		if got := validToken(tok); got != want {
			t.Errorf("validToken(%q) = %v, want %v", tok, got, want)
		}
	}
}

func TestBuildPayloadIsContentBlind(t *testing.T) {
	body := []byte{0x00, 0x01, 0xde, 0xad, 0xbe, 0xef} // opaque ciphertext
	out := buildPayload(body)

	var msg map[string]any
	if err := json.Unmarshal(out, &msg); err != nil {
		t.Fatalf("payload is not valid JSON: %v", err)
	}
	aps, _ := msg["aps"].(map[string]any)
	if aps["mutable-content"] != float64(1) {
		t.Errorf("mutable-content not set; NSE would not run")
	}
	if msg["ce"] != "aes128gcm" {
		t.Errorf("content-encoding = %v, want aes128gcm", msg["ce"])
	}
	// The body must be carried verbatim (base64), never decoded/inspected here.
	if msg["b"] != base64.StdEncoding.EncodeToString(body) {
		t.Errorf("body not forwarded verbatim")
	}
}

func TestPriorityAndExpiration(t *testing.T) {
	if priorityFromUrgency("low") != 5 || priorityFromUrgency("very-low") != 5 {
		t.Error("low urgency should map to priority 5")
	}
	if priorityFromUrgency("") != 10 || priorityFromUrgency("high") != 10 {
		t.Error("default/high urgency should map to priority 10")
	}
	if expirationFromTTL("") != 0 || expirationFromTTL("0") != 0 {
		t.Error("missing/zero TTL should map to expiration 0")
	}
	if expirationFromTTL("60") <= 0 {
		t.Error("positive TTL should map to a future absolute expiration")
	}
}

// TestProviderTokenIsVerifiable proves the ES256 JWT we send to APNs is
// correctly formed and its signature validates against the signing key.
func TestProviderTokenIsVerifiable(t *testing.T) {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	c := &apnsClient{keyID: "9HG9U4DQ2G", teamID: "LFTD9T269J", key: key}

	jwt, err := c.token()
	if err != nil {
		t.Fatal(err)
	}
	parts := strings.Split(jwt, ".")
	if len(parts) != 3 {
		t.Fatalf("jwt has %d segments, want 3", len(parts))
	}

	header, _ := base64.RawURLEncoding.DecodeString(parts[0])
	var h struct{ Alg, Kid string }
	if err := json.Unmarshal(header, &h); err != nil {
		t.Fatal(err)
	}
	if h.Alg != "ES256" || h.Kid != "9HG9U4DQ2G" {
		t.Errorf("header = %+v, want ES256/9HG9U4DQ2G", h)
	}

	sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
	if len(sig) != 64 {
		t.Fatalf("signature is %d bytes, want 64 (r||s)", len(sig))
	}
	digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
	r := new(big.Int).SetBytes(sig[:32])
	s := new(big.Int).SetBytes(sig[32:])
	if !ecdsa.Verify(&key.PublicKey, digest[:], r, s) {
		t.Error("ES256 signature does not verify")
	}

	// A second call within the cache window returns the same token.
	if again, _ := c.token(); again != jwt {
		t.Error("token() should cache within the refresh window")
	}
}
