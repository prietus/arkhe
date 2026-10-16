package main

import (
	"bytes"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"
)

// fcmClient talks to Firebase Cloud Messaging (HTTP v1) for Arkhe on Android,
// authenticating with a service-account key (OAuth2 JWT bearer grant). Like the
// APNs client it is content-blind: the encrypted Web Push body rides along as
// opaque data and the app decrypts it on-device.
type fcmClient struct {
	projectID   string
	clientEmail string
	tokenURI    string
	key         *rsa.PrivateKey
	http        *http.Client
	// sendBase is the FCM API root; overridable in tests.
	sendBase string

	mu          sync.Mutex
	accessToken string
	expiresAt   time.Time
}

// serviceAccount is the subset of a Google service-account JSON key we need.
type serviceAccount struct {
	ProjectID   string `json:"project_id"`
	ClientEmail string `json:"client_email"`
	PrivateKey  string `json:"private_key"`
	TokenURI    string `json:"token_uri"`
}

func newFCMClient(credentialsPath string) (*fcmClient, error) {
	data, err := os.ReadFile(credentialsPath)
	if err != nil {
		return nil, err
	}
	var sa serviceAccount
	if err := json.Unmarshal(data, &sa); err != nil {
		return nil, fmt.Errorf("fcm: service account JSON: %w", err)
	}
	if sa.ProjectID == "" || sa.ClientEmail == "" || sa.PrivateKey == "" {
		return nil, errors.New("fcm: service account JSON lacks project_id, client_email or private_key")
	}
	block, _ := pem.Decode([]byte(sa.PrivateKey))
	if block == nil {
		return nil, errors.New("fcm: private_key is not valid PEM")
	}
	parsed, err := x509.ParsePKCS8PrivateKey(block.Bytes)
	if err != nil {
		return nil, err
	}
	key, ok := parsed.(*rsa.PrivateKey)
	if !ok {
		return nil, errors.New("fcm: private_key is not an RSA key")
	}
	if sa.TokenURI == "" {
		sa.TokenURI = "https://oauth2.googleapis.com/token"
	}
	return &fcmClient{
		projectID: sa.ProjectID, clientEmail: sa.ClientEmail, tokenURI: sa.TokenURI, key: key,
		http:     &http.Client{Timeout: 10 * time.Second},
		sendBase: "https://fcm.googleapis.com",
	}, nil
}

// token returns a cached OAuth2 access token, refreshing it five minutes before
// it expires (Google issues them for an hour).
func (c *fcmClient) token() (string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.accessToken != "" && time.Until(c.expiresAt) > 5*time.Minute {
		return c.accessToken, nil
	}
	now := time.Now().Unix()
	header := b64url([]byte(`{"alg":"RS256","typ":"JWT"}`))
	claims, _ := json.Marshal(map[string]any{
		"iss":   c.clientEmail,
		"scope": "https://www.googleapis.com/auth/firebase.messaging",
		"aud":   c.tokenURI,
		"iat":   now,
		"exp":   now + 3600,
	})
	signingInput := header + "." + b64url(claims)
	digest := sha256.Sum256([]byte(signingInput))
	sig, err := rsa.SignPKCS1v15(rand.Reader, c.key, crypto.SHA256, digest[:])
	if err != nil {
		return "", err
	}
	assertion := signingInput + "." + b64url(sig)

	form := url.Values{
		"grant_type": {"urn:ietf:params:oauth:grant-type:jwt-bearer"},
		"assertion":  {assertion},
	}
	resp, err := c.http.PostForm(c.tokenURI, form)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	var body struct {
		AccessToken string `json:"access_token"`
		ExpiresIn   int    `json:"expires_in"`
		Error       string `json:"error"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&body)
	if resp.StatusCode != http.StatusOK || body.AccessToken == "" {
		return "", fmt.Errorf("fcm: token exchange failed: status=%d error=%s", resp.StatusCode, body.Error)
	}
	if body.ExpiresIn <= 0 {
		body.ExpiresIn = 3600
	}
	c.accessToken = body.AccessToken
	c.expiresAt = time.Now().Add(time.Duration(body.ExpiresIn) * time.Second)
	return c.accessToken, nil
}

// fcmResult distils a send response: the HTTP status and, on failure, the FCM
// error code (e.g. UNREGISTERED, INVALID_ARGUMENT, QUOTA_EXCEEDED).
type fcmResult struct {
	status int
	code   string
}

// send delivers one data message carrying the encrypted Web Push body. It is a
// data-only message so the app always handles it itself (decrypt, then show);
// `highPriority` maps the Web Push Urgency onto FCM's delivery priority.
func (c *fcmClient) send(deviceToken string, body []byte, highPriority bool, ttlSeconds int) (fcmResult, error) {
	access, err := c.token()
	if err != nil {
		return fcmResult{}, err
	}
	priority := "HIGH"
	if !highPriority {
		priority = "NORMAL"
	}
	android := map[string]any{"priority": priority}
	if ttlSeconds >= 0 {
		android["ttl"] = fmt.Sprintf("%ds", ttlSeconds)
	}
	payload, _ := json.Marshal(map[string]any{
		"message": map[string]any{
			"token": deviceToken,
			"data": map[string]string{
				"ce": "aes128gcm",
				"b":  base64.StdEncoding.EncodeToString(body),
			},
			"android": android,
		},
	})

	endpoint := c.sendBase + "/v1/projects/" + c.projectID + "/messages:send"
	req, err := http.NewRequest(http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return fcmResult{}, err
	}
	req.Header.Set("Authorization", "Bearer "+access)
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return fcmResult{}, err
	}
	defer resp.Body.Close()

	res := fcmResult{status: resp.StatusCode}
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Error struct {
				Status  string `json:"status"`
				Details []struct {
					ErrorCode string `json:"errorCode"`
				} `json:"details"`
			} `json:"error"`
		}
		_ = json.NewDecoder(resp.Body).Decode(&e)
		res.code = e.Error.Status
		for _, d := range e.Error.Details {
			if d.ErrorCode != "" {
				res.code = d.ErrorCode
			}
		}
	}
	return res, nil
}

// validFCMToken accepts a plausible FCM registration token: base64url
// characters plus ':' (the instance-id prefix separator).
func validFCMToken(t string) bool {
	if len(t) < 32 || len(t) > 4096 {
		return false
	}
	return strings.IndexFunc(t, func(c rune) bool {
		return !(c >= '0' && c <= '9' || c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' ||
			c == '-' || c == '_' || c == ':')
	}) < 0
}
