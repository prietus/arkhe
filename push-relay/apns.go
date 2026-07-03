package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"
)

// apnsClient talks to Apple Push Notification service with token-based (JWT)
// authentication. It is content-blind: it forwards the already-encrypted Web
// Push body verbatim and never decrypts anything.
type apnsClient struct {
	keyID  string
	teamID string
	topic  string
	key    *ecdsa.PrivateKey
	http   *http.Client

	mu        sync.Mutex
	jwt       string
	jwtIssued time.Time
}

func newAPNSClient(keyPath, keyID, teamID, topic string) (*apnsClient, error) {
	key, err := loadKey(keyPath)
	if err != nil {
		return nil, err
	}
	return &apnsClient{
		keyID: keyID, teamID: teamID, topic: topic, key: key,
		http: &http.Client{Timeout: 10 * time.Second}, // HTTP/2 negotiated via ALPN
	}, nil
}

// loadKey parses an APNs auth key (.p8, a PKCS#8-wrapped EC P-256 private key).
func loadKey(path string) (*ecdsa.PrivateKey, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	block, _ := pem.Decode(data)
	if block == nil {
		return nil, errors.New("apns: .p8 is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*ecdsa.PrivateKey)
	if !ok {
		return nil, errors.New("apns: .p8 is not an ECDSA key")
	}
	return key, nil
}

func b64url(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

// token returns a cached provider JWT, regenerating it when older than 40
// minutes (APNs accepts a token for up to 60 and rejects refreshing too often).
func (c *apnsClient) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.jwt != "" && time.Since(c.jwtIssued) < 40*time.Minute {
		return c.jwt, nil
	}
	header := b64url([]byte(fmt.Sprintf(`{"alg":"ES256","kid":%q}`, c.keyID)))
	claims := b64url([]byte(fmt.Sprintf(`{"iss":%q,"iat":%d}`, c.teamID, time.Now().Unix())))
	signingInput := header + "." + claims
	digest := sha256.Sum256([]byte(signingInput))
	r, s, err := ecdsa.Sign(rand.Reader, c.key, digest[:])
	if err != nil {
		return "", err
	}
	// JWS ES256 wants the raw r||s pair, each left-padded to 32 bytes.
	sig := make([]byte, 64)
	r.FillBytes(sig[:32])
	s.FillBytes(sig[32:])
	c.jwt = signingInput + "." + b64url(sig)
	c.jwtIssued = time.Now()
	return c.jwt, nil
}

// apnsResult distils a single push response for the caller.
type apnsResult struct {
	status int    // HTTP status from APNs
	reason string // APNs "reason" string on failure, if present
}

// send delivers one notification to a device via the given APNs host.
func (c *apnsClient) send(host, deviceToken string, payload []byte, priority, expiration int) (apnsResult, error) {
	jwt, err := c.token()
	if err != nil {
		return apnsResult{}, err
	}
	req, err := http.NewRequest(http.MethodPost, "https://"+host+"/3/device/"+deviceToken, bytes.NewReader(payload))
	if err != nil {
		return apnsResult{}, err
	}
	req.Header.Set("authorization", "bearer "+jwt)
	req.Header.Set("apns-topic", c.topic)
	req.Header.Set("apns-push-type", "alert")
	req.Header.Set("apns-priority", strconv.Itoa(priority))
	req.Header.Set("apns-expiration", strconv.Itoa(expiration))

	resp, err := c.http.Do(req)
	if err != nil {
		return apnsResult{}, err
	}
	defer resp.Body.Close()

	res := apnsResult{status: resp.StatusCode}
	if resp.StatusCode != http.StatusOK {
		var body struct {
			Reason string `json:"reason"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&body)
		res.reason = body.Reason
	}
	return res, nil
}
