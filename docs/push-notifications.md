# Push notifications

Arkhe has two tiers of notifications:

1. **Local** — mentions and direct messages while the app is open or briefly
   backgrounded. Always on, no infrastructure. (`App/Notifications/`.)
2. **Remote (Web Push)** — the same alerts while the app is **fully closed**,
   delivered by the user's own bouncer. This is the model below.

## Why Web Push (and not a per-user bridge)

A closed iOS app can only be woken by Apple (APNs), and APNs must be told to push
by something online 24/7. In Arkhe's world that "something" is the **bouncer the
user already runs** — soju implements the `soju.im/webpush` extension: it detects
the highlight/DM, encrypts it (RFC 8291) and POSTs it to a push endpoint. The
user needs **no extra infrastructure** beyond their bouncer.

The only shared piece is a small **relay** (this repo's `push-relay/`) that
forwards soju's encrypted POST to APNs. It is **content-blind**: Web Push is
end-to-end encrypted between the user's soju and their device, so the relay only
ever sees ciphertext, a device token and the sender soju's IP — never message
content or IRC credentials. One relay serves every user; privacy-conscious users
can run their own and point the app at it.

```
  soju (each user's bouncer)  --RFC 8291 encrypted-->  arkhe-push relay  --APNs-->  iPhone
     detects highlight/DM            POST /v1/<token>       forwards          NSE decrypts on-device
```

## What's implemented

**App**
- `Shared/WebPush/WebPushKeys.swift` — generates a P-256 key pair + 16-byte auth
  secret, stored in a Keychain item shared with the extension via the
  `group.im.arkhe.client` App Group (after-first-unlock, so it decrypts on the
  lock screen).
- `Shared/WebPush/WebPushCrypto.swift` — RFC 8291 `aes128gcm` decryption
  (ECDH P-256 → HKDF-SHA256 → AES-128-GCM), verified against the RFC 8291 §5
  test vector.
- `NotificationService/` — the Notification Service Extension: decrypts the
  payload, parses the IRC line with IRCCore, and fills in sender/channel/text.
- `IRCSession.registerWebPush(...)` sends `WEBPUSH REGISTER <endpoint> p256dh=…;auth=…`
  once the bouncer advertises `soju.im/webpush`; `NotificationManager` builds
  `https://<relay>/v1/<apns-token>` and drives registration when the user turns
  on **Settings → Push (app closed)**.
- Entitlements: `Config/Arkhe.entitlements` (aps-environment + App Group),
  `Config/NotificationService.entitlements` (App Group).

**Relay** — `push-relay/` (Go, standard library only). See its README for build,
config and deploy. Stateless: the device token in the URL is the routing key.

## Activation checklist

Apple Developer portal (you):

1. App ID `im.arkhe.client` → enable **Push Notifications**.
2. App ID `im.arkhe.client` → enable **App Groups**; create group
   `group.im.arkhe.client`.
3. Create App ID `im.arkhe.client.NotificationService` (the extension) → enable
   **App Groups** with the same `group.im.arkhe.client`.
4. You already created the **APNs Auth Key** — Key ID `9HG9U4DQ2G`, Team
   `LFTD9T269J`. Keep the `.p8` for the relay.

Relay (you) — full steps in `push-relay/README.md`:

5. DNS `push.arkhe.priet.us A 89.47.167.133`, TLS via certbot, deploy the binary
   + systemd + nginx vhost on the VPS.

App:

6. `xcodegen generate`, archive (Xcode signs the app + embedded extension with
   the new capabilities) and ship. On device, enable **Settings → Push (app
   closed)**; grant permission; get mentioned with the app closed to test.

Until 1–5 are done the app still delivers **local** notifications; remote push
simply stays inactive.

## Notes

- Keychain sharing uses the App Group id verbatim as the access group
  (`group.im.arkhe.client`, no team prefix) — fork-portable. If a fork can't read
  the shared item, fall back to an explicit `keychain-access-groups` entitlement.
- APNs environment: the relay defaults to `production` with `APNS_ENV=auto` to
  also cover TestFlight (sandbox) builds.
