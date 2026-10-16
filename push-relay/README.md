# arkhe-push — Web Push → APNs relay

A small, **content-blind** relay that lets any soju bouncer deliver push
notifications to Arkhe on iOS **without the user running any infrastructure of
their own** beyond the bouncer they already have.

## How it fits

```
soju (each user's bouncer)  --RFC 8291 encrypted-->  arkhe-push  --APNs-->  iPhone
   detects highlight/DM            POST /v1/<token>     forwards        NSE decrypts
```

- The message is **encrypted end-to-end** between the user's soju and their
  device (RFC 8291). This relay forwards the ciphertext verbatim.
- **It never sees** message content, senders, channels or IRC credentials. It
  sees only a device token (routing), the sender soju's IP and push timing/size.
- **Stateless:** the APNs device token in the URL path is both the routing key
  and the capability. No database. The only secret it holds is the APNs key.

One instance serves every Arkhe user. Privacy-conscious users can point their
soju at their own instance instead (the endpoint URL is configurable in the app).

## Endpoint contract

The app registers this with soju:

```
WEBPUSH REGISTER https://push.arkhe.priet.us/v1/<apns-device-token> p256dh=<b64url>;auth=<b64url>
```

soju then `POST`s the encrypted body to that URL. The relay wraps it into an
APNs notification the on-device extension can decrypt:

```json
{
  "aps": { "mutable-content": 1, "alert": { "title": "Arkhe", "body": "New message" }, "sound": "default" },
  "ce": "aes128gcm",
  "b": "<base64 of the raw encrypted Web Push body>"
}
```

`mutable-content` runs the Notification Service Extension, which base64-decodes
`b`, decrypts it (RFC 8291) and replaces the alert with the real sender/text.

### Android (Firebase Cloud Messaging)

Arkhe for Android registers `https://push.arkhe.priet.us/v1/fcm/<fcm-token>`.
The relay forwards the body to FCM (HTTP v1) as a **data-only** message — so the
app always handles it itself, decrypts it on-device and shows the notification:

```json
{ "message": { "token": "<fcm-token>",
  "data": { "ce": "aes128gcm", "b": "<base64 of the raw encrypted Web Push body>" },
  "android": { "priority": "HIGH", "ttl": "<TTL>s" } } }
```

`Urgency: low|very-low` maps to `NORMAL` priority; FCM `UNREGISTERED` maps to
`410 Gone` so soju drops the subscription, like APNs `Unregistered`.

## Build

```sh
cd push-relay
go build -o arkhe-push .   # pure stdlib, no dependencies
go test ./...
```

## Configuration (environment)

| Variable | Required | Default | Notes |
|---|---|---|---|
| `APNS_KEY_PATH` | for iOS | — | path to the `.p8` APNs auth key |
| `APNS_KEY_ID` | for iOS | — | `9HG9U4DQ2G` |
| `APNS_TEAM_ID` | for iOS | — | `LFTD9T269J` |
| `FCM_CREDENTIALS_PATH` | for Android | — | Firebase service-account JSON key (Project settings → Service accounts → Generate new private key) |
| `APNS_TOPIC` | no | `im.arkhe.client` | the app bundle id |
| `APNS_ENV` | no | `production` | `production` \| `sandbox` \| `auto` |
| `LISTEN_ADDR` | no | `127.0.0.1:8080` | behind nginx |

At least one platform must be configured; a platform left unconfigured answers
`404` on its route.

Use `APNS_ENV=auto` while you have both TestFlight (sandbox) and App Store
(production) builds in the wild — it tries production, then sandbox on
`BadDeviceToken`.

## Deploy on the VPS (mail.priet.us / 89.47.167.133)

1. **DNS** — add an A record so the push host resolves to the VPS (not home):
   ```
   push.arkhe.priet.us.  A  89.47.167.133
   ```

2. **TLS** — issue a certificate (same webroot as your other sites):
   ```sh
   sudo certbot certonly --webroot -w /var/www/html -d push.arkhe.priet.us
   ```

3. **Binary + user + secrets**
   ```sh
   GOOS=linux GOARCH=amd64 go build -o arkhe-push .   # (or build on the VPS)
   sudo install -m 0755 arkhe-push /usr/local/bin/arkhe-push
   sudo useradd --system --no-create-home --shell /usr/sbin/nologin arkhe-push
   sudo mkdir -p /etc/arkhe-push
   sudo cp AuthKey_9HG9U4DQ2G.p8 /etc/arkhe-push/
   sudo cp firebase-service-account.json /etc/arkhe-push/fcm.json   # Android
   sudo tee /etc/arkhe-push/env >/dev/null <<'EOF'
   FCM_CREDENTIALS_PATH=/etc/arkhe-push/fcm.json
   APNS_KEY_PATH=/etc/arkhe-push/AuthKey_9HG9U4DQ2G.p8
   APNS_KEY_ID=9HG9U4DQ2G
   APNS_TEAM_ID=LFTD9T269J
   APNS_TOPIC=im.arkhe.client
   APNS_ENV=auto
   LISTEN_ADDR=127.0.0.1:8080
   EOF
   sudo chown -R arkhe-push:arkhe-push /etc/arkhe-push
   sudo chmod 600 /etc/arkhe-push/AuthKey_9HG9U4DQ2G.p8 /etc/arkhe-push/fcm.json /etc/arkhe-push/env
   ```

4. **systemd**
   ```sh
   sudo cp deploy/arkhe-push.service /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo systemctl enable --now arkhe-push
   ```

5. **nginx** — add the vhost on the internal `127.0.0.1:9443` tier (same pattern
   as `arkhe.priet.us`; the `:443` SNI stream already routes unknown hosts here,
   so no stream-map change):
   ```sh
   sudo cp deploy/push.arkhe.priet.us.conf /etc/nginx/sites-enabled/
   sudo nginx -t && sudo systemctl reload nginx
   ```

6. **Smoke test**
   ```sh
   curl -s https://push.arkhe.priet.us/healthz   # -> ok
   ```

## Privacy

- No message content ever reaches the relay (E2E encrypted; it forwards opaque
  bytes).
- No IRC credentials, no plaintext, no database of conversations.
- Access logging is **off** (nginx) so device tokens and soju IPs are not
  persisted; only errors are kept.
- The relay holds two secrets: the APNs `.p8` and the Firebase service-account
  key (both `chmod 600`).

## Security notes

- The device token in the path is unguessable and acts as the capability. A v2
  could additionally verify the VAPID `Authorization` header soju sends.
- `client_max_body_size 8k` (nginx) + a 4 KB read cap (relay) bound abuse.
