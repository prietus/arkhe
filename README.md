# Arkhe

An IRC client for iPhone/iPad focused on **IRCv3**, with **SASL** (PLAIN and
EXTERNAL/**CertFP**) and compatible with soju-style bouncers/relays.

Written in Swift 6 + SwiftUI, with a pure, tested protocol core.

## Screenshots

<p align="center">
  <img src="docs/screenshots/chat.png" width="30%" alt="Channel view with inline link previews and a multi-network sidebar">
  &nbsp;
  <img src="docs/screenshots/settings.png" width="30%" alt="Display and privacy settings">
  &nbsp;
  <img src="docs/screenshots/console.png" width="30%" alt="Raw IRCv3 protocol console for debugging">
</p>

## Architecture

```
IRCCore/                  Pure SPM package (Foundation). No platform dependencies.
  IRCMessage*             IRCv3 message model + parser + encoder (tags, source, trailing)
  IRCTags                 message-tags escaping (\s \: \\ \r \n)
  SASL                    PLAIN and EXTERNAL: responses and chunking into 400-byte pieces
  Capability*             CAP LS/REQ/ACK/END + SASL flow as a pure state machine
  ISupport / CaseMapping  Parsing of 005 and case folding (ascii/rfc1459)
  → 30 tests via `swift test`

App/                      iOS target (Arkhe)
  Transport/
    IRCConnection         Actor over NWConnection: TLS, CRLF framing, AsyncStream of events
    TLSIdentity           PKCS#12 client identity for CertFP + SHA-256 fingerprint
  Session/
    IRCSession            @Observable @MainActor: orchestrates registration, dispatch, buffers, soju
    RuntimeModels         Buffer, ChatLine, Member, BouncerNetwork
    SessionConfig         Sendable snapshot of the config
  Model/
    ServerConfig          @Model SwiftData (secrets in Keychain, not in the store)
    Keychain              Keychain wrapper for passwords and certificate passphrases
  Store/ClientStore       Runtime state: live sessions + selection
  Notifications/          Local alerts, badge, tap→buffer + APNs/Web Push registration
  Views/                  Adaptive iPhone/iPad NavigationSplitView

Shared/WebPush/           Shared by the app and the Notification Service Extension
  WebPushKeys             P-256 keypair + auth secret in a shared-App-Group Keychain
  WebPushCrypto           RFC 8291 (aes128gcm) decryption — verified vs the RFC test vector
NotificationService/      Notification Service Extension: decrypts Web Push, formats the alert
push-relay/               Go: content-blind Web Push → APNs relay (stdlib only; self-hostable)
```

## IRCv3 features

- **Core**: `message-tags`, `server-time` (real timestamps in history), `batch`,
  `labeled-response`, `cap-notify` (CAP NEW/DEL), `standard-replies` (FAIL/WARN/NOTE)
- **Auth**: `sasl` with **PLAIN** and **EXTERNAL** (CertFP via TLS client certificate)
- **Presence & identity**: `account-notify`, `account-tag`, `away-notify`,
  `chghost`, `extended-join`, `multi-prefix`, `userhost-in-names`, `setname`,
  `invite-notify`, `echo-message` (local echo only when it isn't active)
- **History**: `draft/chathistory` — automatic scrollback when joining a channel;
  `draft/event-playback` — replays joins/parts/topics on reconnect, not just messages
- **Rich messaging**:
  - `draft/read-marker` (`MARKREAD`) — read position syncs across every client on
    the bouncer, so unread counts and the "new messages" divider follow you device
    to device
  - `draft/multiline` — sends and renders multi-line messages as a single message
  - `draft/message-redaction` (`REDACT`) — delete your own messages (or moderate)
  - `+draft/reply` threaded replies, `+draft/react`/`+draft/unreact` emoji
    reactions, and `+typing` typing indicators
- **soju**: `soju.im/bouncer-networks` (+notify) — discovers and lists the
  bouncer's networks; `soju.im/webpush` — push notifications while the app is
  closed; `soju.im/no-implicit-names` — member rosters fetched lazily, per
  channel viewed, to save mobile data on reconnect

## Requirements

- Xcode 26+, iOS 17+ (SwiftData + Observation)
- `xcodegen` (`brew install xcodegen`)

## Build and run

```sh
# Protocol core (tests)
cd IRCCore && swift test

# Generate the project and build the app
xcodegen generate
xcodebuild -project Arkhe.xcodeproj -scheme Arkhe \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Open `Arkhe.xcodeproj` in Xcode to run on a simulator or device.

> **If you build it yourself to install on your own iPhone:** the project ships
> with my `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` (`im.arkhe.client`)
> in `project.yml`. Change them to your own (your Apple Team ID and your own
> bundle id, e.g. `com.yourname.arkhe`) and run `xcodegen generate` again. The
> `.xcodeproj` is not versioned: it is generated from `project.yml`.
>
> Remote push additionally needs the **Push Notifications** and **App Groups**
> capabilities on your App IDs (the app and its `…NotificationService`) plus a
> relay — or remove the `CODE_SIGN_ENTITLEMENTS` lines from `project.yml` to build
> without push (local notifications still work). See
> [`docs/push-notifications.md`](docs/push-notifications.md).

## CertFP with soju

1. Generate a client certificate and package it as a `.p12`.
2. In the app: new server → SASL = **EXTERNAL** → import the `.p12`.
3. Copy the **SHA-256 fingerprint** the app shows and register it on the network
   (`/msg NickServ CERT ADD`) or in your soju config.

## Notifications

**Local** notifications for **mentions** (your nick — or any custom **highlight
keyword** — in a channel) and **direct messages**, with per-type toggles,
previews and sound in Settings. **Reply inline** from the notification without
opening the app; **mute** a noisy conversation's alerts (long-press it in the
sidebar); alerts are suppressed for the conversation you're already viewing. On
backgrounding the connection is held briefly to catch a last message; on return
it reconnects and pulls missed scrollback via chathistory.

**Remote push** for when the app is fully closed uses the bouncer's own Web Push
(`soju.im/webpush`) — no per-user infrastructure. soju detects the highlight/DM
and sends it **end-to-end encrypted** (RFC 8291) to a small **content-blind**
relay ([`push-relay/`](push-relay/), Go), which forwards it to APNs; a
Notification Service Extension decrypts it on-device. The relay never sees
message content or credentials. Self-hosters can point the app at their own
relay. See [`docs/push-notifications.md`](docs/push-notifications.md).

## Roadmap (next iteration)

- Message history persistence (only the config is persisted today)
- Full per-network bouncer multiplexing (bind / live network switching in the UI)
- SCRAM-SHA-256, additional slash commands, theming/settings, search

## App Store

Arkhe is available on the App Store (€0.99) as a convenient way to install it
and to support development. The code is open: if you'd rather build it yourself,
follow the instructions above.

## License

[Apache 2.0](LICENSE) © 2026 Carlos Prieto

The code is open source under Apache 2.0. The **name "Arkhe" and the icon** are
trademarks of the author and are not licensed with the code (Apache 2.0, §6):
a fork must use its own name and icon.
