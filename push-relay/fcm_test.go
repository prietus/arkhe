package main

import (
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
)

const testFCMToken = "dGVzdC10b2tlbg:APA91bH-example_token-0123456789abcdefABCDEF"

// fakeGoogle stands in for the OAuth2 token endpoint and the FCM v1 API.
type fakeGoogle struct {
	t          *testing.T
	pub        *rsa.PublicKey
	tokenCalls atomic.Int32
	lastSend   map[string]any
	sendStatus int
	sendError  string
}

func (g *fakeGoogle) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch {
	case r.URL.Path == "/token":
		g.tokenCalls.Add(1)
		_ = r.ParseForm()
		if r.Form.Get("grant_type") != "urn:ietf:params:oauth:grant-type:jwt-bearer" {
			g.t.Errorf("grant_type = %q", r.Form.Get("grant_type"))
		}
		// Verify the RS256 assertion and its claims.
		parts := strings.Split(r.Form.Get("assertion"), ".")
		if len(parts) != 3 {
			g.t.Fatalf("assertion is not a JWT")
		}
		sig, _ := base64.RawURLEncoding.DecodeString(parts[2])
		digest := sha256.Sum256([]byte(parts[0] + "." + parts[1]))
		if err := rsa.VerifyPKCS1v15(g.pub, crypto.SHA256, digest[:], sig); err != nil {
			g.t.Errorf("assertion signature: %v", err)
		}
		claimsJSON, _ := base64.RawURLEncoding.DecodeString(parts[1])
		var claims map[string]any
		_ = json.Unmarshal(claimsJSON, &claims)
		if claims["scope"] != "https://www.googleapis.com/auth/firebase.messaging" {
			g.t.Errorf("scope = %v", claims["scope"])
		}
		if claims["iss"] != "relay@arkhe-test.iam.gserviceaccount.com" {
			g.t.Errorf("iss = %v", claims["iss"])
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"access_token": "ya29.test", "expires_in": 3600})
	case r.URL.Path == "/v1/projects/arkhe-test/messages:send":
		if r.Header.Get("Authorization") != "Bearer ya29.test" {
			g.t.Errorf("authorization = %q", r.Header.Get("Authorization"))
		}
		body, _ := io.ReadAll(r.Body)
		g.lastSend = nil
		_ = json.Unmarshal(body, &g.lastSend)
		if g.sendStatus != 0 && g.sendStatus != http.StatusOK {
			w.WriteHeader(g.sendStatus)
			_, _ = w.Write([]byte(`{"error":{"status":"NOT_FOUND","details":[{"errorCode":"` + g.sendError + `"}]}}`))
			return
		}
		_, _ = w.Write([]byte(`{"name":"projects/arkhe-test/messages/1"}`))
	default:
		http.NotFound(w, r)
	}
}

// newTestFCM builds an fcmClient from a generated service-account key whose
// endpoints point at a fake Google server.
func newTestFCM(t *testing.T) (*fcmClient, *fakeGoogle) {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	der, _ := x509.MarshalPKCS8PrivateKey(key)
	fake := &fakeGoogle{t: t, pub: &key.PublicKey}
	ts := httptest.NewServer(fake)
	t.Cleanup(ts.Close)

	sa, _ := json.Marshal(map[string]string{
		"type":         "service_account",
		"project_id":   "arkhe-test",
		"client_email": "relay@arkhe-test.iam.gserviceaccount.com",
		"private_key":  string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der})),
		"token_uri":    ts.URL + "/token",
	})
	path := filepath.Join(t.TempDir(), "sa.json")
	if err := os.WriteFile(path, sa, 0o600); err != nil {
		t.Fatal(err)
	}
	client, err := newFCMClient(path)
	if err != nil {
		t.Fatal(err)
	}
	client.sendBase = ts.URL
	return client, fake
}

func TestFCMForwardsBodyVerbatimAsData(t *testing.T) {
	client, fake := newTestFCM(t)
	srv := &server{fcm: client}
	body := []byte{0x00, 0x01, 0xde, 0xad, 0xbe, 0xef} // opaque ciphertext

	req := httptest.NewRequest(http.MethodPost, "/v1/fcm/"+testFCMToken, strings.NewReader(string(body)))
	req.SetPathValue("token", testFCMToken)
	req.Header.Set("Urgency", "high")
	req.Header.Set("TTL", "60")
	rec := httptest.NewRecorder()
	srv.handleFCM(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("status = %d, want 201", rec.Code)
	}
	msg, _ := fake.lastSend["message"].(map[string]any)
	if msg["token"] != testFCMToken {
		t.Errorf("token = %v", msg["token"])
	}
	// Data-only: no notification block, so the app decrypts and shows it itself.
	if _, ok := msg["notification"]; ok {
		t.Error("message must be data-only")
	}
	data, _ := msg["data"].(map[string]any)
	if data["b"] != base64.StdEncoding.EncodeToString(body) || data["ce"] != "aes128gcm" {
		t.Errorf("body not forwarded verbatim: %v", data)
	}
	android, _ := msg["android"].(map[string]any)
	if android["priority"] != "HIGH" || android["ttl"] != "60s" {
		t.Errorf("android options = %v", android)
	}

	// A second push reuses the cached access token.
	req2 := httptest.NewRequest(http.MethodPost, "/v1/fcm/"+testFCMToken, strings.NewReader("x"))
	req2.SetPathValue("token", testFCMToken)
	srv.handleFCM(httptest.NewRecorder(), req2)
	if n := fake.tokenCalls.Load(); n != 1 {
		t.Errorf("token exchanges = %d, want 1 (cached)", n)
	}
}

func TestFCMUnregisteredMapsToGone(t *testing.T) {
	client, fake := newTestFCM(t)
	fake.sendStatus, fake.sendError = http.StatusNotFound, "UNREGISTERED"
	srv := &server{fcm: client}
	req := httptest.NewRequest(http.MethodPost, "/v1/fcm/"+testFCMToken, strings.NewReader("x"))
	req.SetPathValue("token", testFCMToken)
	rec := httptest.NewRecorder()
	srv.handleFCM(rec, req)
	if rec.Code != http.StatusGone {
		t.Errorf("status = %d, want 410 so soju drops the subscription", rec.Code)
	}
}

func TestFCMRejectsBadTokensAndMissingConfig(t *testing.T) {
	client, _ := newTestFCM(t)
	srv := &server{fcm: client}
	req := httptest.NewRequest(http.MethodPost, "/v1/fcm/bad", strings.NewReader("x"))
	req.SetPathValue("token", "bad token!")
	rec := httptest.NewRecorder()
	srv.handleFCM(rec, req)
	if rec.Code != http.StatusBadRequest {
		t.Errorf("bad token: status = %d, want 400", rec.Code)
	}

	unconfigured := &server{}
	req = httptest.NewRequest(http.MethodPost, "/v1/fcm/"+testFCMToken, strings.NewReader("x"))
	req.SetPathValue("token", testFCMToken)
	rec = httptest.NewRecorder()
	unconfigured.handleFCM(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Errorf("unconfigured: status = %d, want 404", rec.Code)
	}
}

func TestValidFCMToken(t *testing.T) {
	if !validFCMToken(testFCMToken) {
		t.Error("real-looking token rejected")
	}
	for _, bad := range []string{"", "short", strings.Repeat("a", 40) + " x", strings.Repeat("a", 40) + "/x"} {
		if validFCMToken(bad) {
			t.Errorf("validFCMToken(%q) = true", bad)
		}
	}
}
