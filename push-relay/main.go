// Command arkhe-push is a small, content-blind Web Push → APNs / FCM relay.
//
// A user's soju bouncer detects a highlight or direct message, encrypts it with
// the device's own keys (RFC 8291) and POSTs the ciphertext to
// https://push.<host>/v1/<apns-device-token> (iOS) or
// https://push.<host>/v1/fcm/<fcm-registration-token> (Android). This relay
// forwards that opaque ciphertext to Apple or Google, which wakes the device;
// the app (Notification Service Extension on iOS, a messaging service on
// Android) decrypts it on-device. The relay never sees message content, IRC
// credentials or plaintext — only a device token, the sender soju's IP and the
// timing/size of pushes.
//
// It is stateless: the device token in the path is both the routing key and the
// capability, so there is no database. The only secrets it holds are the APNs
// auth key (.p8) and the Firebase service-account key; either platform can be
// left unconfigured.
package main

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"log"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const (
	hostProduction = "api.push.apple.com"
	hostSandbox    = "api.sandbox.push.apple.com"
	maxBody        = 4096 // a Web Push body carrying one IRC line is tiny
)

func env(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func main() {
	srv := &server{
		env:        env("APNS_ENV", "production"), // production | sandbox | auto
		listenAddr: env("LISTEN_ADDR", "127.0.0.1:8080"),
	}

	keyPath := os.Getenv("APNS_KEY_PATH")
	keyID := os.Getenv("APNS_KEY_ID")
	teamID := os.Getenv("APNS_TEAM_ID")
	topic := env("APNS_TOPIC", "im.arkhe.client")
	if keyPath != "" || keyID != "" || teamID != "" {
		if keyPath == "" || keyID == "" || teamID == "" {
			log.Fatal("APNs: set all of APNS_KEY_PATH, APNS_KEY_ID and APNS_TEAM_ID")
		}
		apns, err := newAPNSClient(keyPath, keyID, teamID, topic)
		if err != nil {
			log.Fatalf("apns: %v", err)
		}
		srv.apns = apns
	}

	if path := os.Getenv("FCM_CREDENTIALS_PATH"); path != "" {
		fcm, err := newFCMClient(path)
		if err != nil {
			log.Fatalf("fcm: %v", err)
		}
		srv.fcm = fcm
	}

	if srv.apns == nil && srv.fcm == nil {
		log.Fatal("configure APNs (APNS_KEY_PATH, APNS_KEY_ID, APNS_TEAM_ID) and/or FCM (FCM_CREDENTIALS_PATH)")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("POST /v1/{token}", srv.handlePush)
	mux.HandleFunc("POST /v1/fcm/{token}", srv.handleFCM)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	})

	log.Printf("arkhe-push listening on %s (apns=%t env=%s topic=%s, fcm=%t)",
		srv.listenAddr, srv.apns != nil, srv.env, topic, srv.fcm != nil)
	log.Fatal(http.ListenAndServe(srv.listenAddr, mux))
}

type server struct {
	apns       *apnsClient // nil when iOS push isn't configured
	fcm        *fcmClient  // nil when Android push isn't configured
	env        string
	listenAddr string
}

// handlePush relays a Web Push delivery from a soju bouncer to APNs. The body is
// forwarded verbatim; the relay does not decrypt it.
func (s *server) handlePush(w http.ResponseWriter, r *http.Request) {
	if s.apns == nil {
		http.Error(w, "APNs not configured", http.StatusNotFound)
		return
	}
	token := strings.ToLower(r.PathValue("token"))
	if !validToken(token) {
		http.Error(w, "bad token", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(body) == 0 || len(body) > maxBody {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}

	payload := buildPayload(body)
	priority := priorityFromUrgency(r.Header.Get("Urgency"))
	expiration := expirationFromTTL(r.Header.Get("TTL"))

	res, err := s.deliver(token, payload, priority, expiration)
	if err != nil {
		log.Printf("apns error: %v", err)
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}

	// Translate the APNs outcome into the Web Push status codes soju expects.
	switch {
	case res.status == http.StatusOK:
		w.WriteHeader(http.StatusCreated) // 201: delivered
	case res.reason == "Unregistered" || res.reason == "BadDeviceToken":
		w.WriteHeader(http.StatusGone) // 410: tell soju to drop this subscription
	case res.status == http.StatusTooManyRequests:
		w.WriteHeader(http.StatusTooManyRequests)
	default:
		log.Printf("apns rejected: status=%d reason=%s", res.status, res.reason)
		w.WriteHeader(http.StatusBadGateway)
	}
}

// handleFCM relays a Web Push delivery from a soju bouncer to Firebase Cloud
// Messaging, for Arkhe on Android. The body is forwarded verbatim (as data);
// the relay does not decrypt it.
func (s *server) handleFCM(w http.ResponseWriter, r *http.Request) {
	if s.fcm == nil {
		http.Error(w, "FCM not configured", http.StatusNotFound)
		return
	}
	token := r.PathValue("token")
	if !validFCMToken(token) {
		http.Error(w, "bad token", http.StatusBadRequest)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(body) == 0 || len(body) > maxBody {
		http.Error(w, "bad body", http.StatusBadRequest)
		return
	}

	high := priorityFromUrgency(r.Header.Get("Urgency")) == 10
	ttl := -1 // FCM default (4 weeks) when soju sends no TTL
	if n, err := strconv.Atoi(r.Header.Get("TTL")); err == nil && n >= 0 {
		ttl = n
	}

	res, err := s.fcm.send(token, body, high, ttl)
	if err != nil {
		log.Printf("fcm error: %v", err)
		http.Error(w, "upstream error", http.StatusBadGateway)
		return
	}

	// Translate the FCM outcome into the Web Push status codes soju expects.
	switch {
	case res.status == http.StatusOK:
		w.WriteHeader(http.StatusCreated) // 201: delivered
	case res.code == "UNREGISTERED" || res.status == http.StatusNotFound:
		w.WriteHeader(http.StatusGone) // 410: the app was uninstalled / token rotated
	case res.status == http.StatusTooManyRequests || res.code == "QUOTA_EXCEEDED":
		w.WriteHeader(http.StatusTooManyRequests)
	default:
		log.Printf("fcm rejected: status=%d code=%s", res.status, res.code)
		w.WriteHeader(http.StatusBadGateway)
	}
}

// deliver sends to the configured APNs environment, transparently retrying the
// other one when APNs reports the token belongs there (env="auto").
func (s *server) deliver(token string, payload []byte, priority, expiration int) (apnsResult, error) {
	primary, secondary := hostProduction, ""
	switch s.env {
	case "sandbox":
		primary = hostSandbox
	case "auto":
		secondary = hostSandbox
	}
	res, err := s.apns.send(primary, token, payload, priority, expiration)
	if err != nil {
		return res, err
	}
	if res.reason == "BadDeviceToken" && secondary != "" {
		return s.apns.send(secondary, token, payload, priority, expiration)
	}
	return res, nil
}

// validToken accepts a lowercase hex APNs device token of plausible length.
func validToken(t string) bool {
	if len(t) < 32 || len(t) > 200 {
		return false
	}
	for _, c := range t {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

// buildPayload wraps the opaque encrypted body in an APNs alert with
// mutable-content set, so the on-device extension runs and decrypts it. The
// placeholder alert is what shows if decryption ever fails.
func buildPayload(body []byte) []byte {
	msg := map[string]any{
		"aps": map[string]any{
			"mutable-content": 1,
			"alert":           map[string]any{"title": "Arkhe", "body": "New message"},
			"sound":           "default",
		},
		"ce": "aes128gcm",
		"b":  base64.StdEncoding.EncodeToString(body),
	}
	out, _ := json.Marshal(msg)
	return out
}

func priorityFromUrgency(u string) int {
	switch strings.ToLower(u) {
	case "very-low", "low":
		return 5
	default:
		return 10
	}
}

// expirationFromTTL maps the Web Push TTL (seconds from now) to an absolute
// apns-expiration. TTL 0 (or missing) means "try once, don't store".
func expirationFromTTL(ttl string) int {
	n, err := strconv.Atoi(ttl)
	if err != nil || n <= 0 {
		return 0
	}
	return int(time.Now().Unix()) + n
}
