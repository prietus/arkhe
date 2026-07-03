# Arkhe

Cliente IRC para iPhone/iPad centrado en **IRCv3**, con **SASL** (PLAIN y
EXTERNAL/**CertFP**) y compatible con bouncers/relays tipo **soju**.

Escrito en Swift 6 + SwiftUI, con un núcleo de protocolo puro y testeado.

## Arquitectura

```
IRCCore/                  Paquete SPM puro (Foundation). Sin dependencias de plataforma.
  IRCMessage*             Modelo de mensaje IRCv3 + parser + encoder (tags, source, trailing)
  IRCTags                 Escapado de message-tags (\s \: \\ \r \n)
  SASL                    PLAIN y EXTERNAL: respuestas y troceado en chunks de 400 bytes
  Capability*             CAP LS/REQ/ACK/END + flujo SASL como máquina de estados pura
  ISupport / CaseMapping  Parsing de 005 y plegado de mayúsculas (ascii/rfc1459)
  → 30 tests con `swift test`

App/                      Target iOS (Arkhe)
  Transport/
    IRCConnection         Actor sobre NWConnection: TLS, framing CRLF, AsyncStream de eventos
    TLSIdentity           Identidad de cliente PKCS#12 para CertFP + huella SHA-256
  Session/
    IRCSession            @Observable @MainActor: orquesta registro, dispatch, buffers, soju
    RuntimeModels         Buffer, ChatLine, Member, BouncerNetwork
    SessionConfig         Snapshot Sendable de la config
  Model/
    ServerConfig          @Model SwiftData (secretos en Keychain, no en el store)
    Keychain              Wrapper de Keychain para contraseñas y frases de certificado
  Store/ClientStore       Estado runtime: sesiones vivas + selección
  Views/                  NavigationSplitView adaptable iPhone/iPad
```

## Funcionalidades IRCv3

- `message-tags`, `server-time` (timestamps reales en el historial), `batch`
- `sasl` con **PLAIN** y **EXTERNAL** (CertFP por certificado de cliente TLS)
- `cap-notify` (CAP NEW/DEL), `echo-message` (echo local sólo si no está activo)
- `account-notify`, `away-notify`, `chghost`, `extended-join`, `multi-prefix`,
  `userhost-in-names`, `setname`, `invite-notify`
- `draft/chathistory` — scrollback automático al unirse a un canal
- **soju**: `soju.im/bouncer-networks` (+notify) — descubre y lista las redes del bouncer

## Requisitos

- Xcode 26+, iOS 17+ (SwiftData + Observation)
- `xcodegen` (`brew install xcodegen`)

## Compilar y ejecutar

```sh
# Núcleo de protocolo (tests)
cd IRCCore && swift test

# Generar el proyecto y compilar la app
xcodegen generate
xcodebuild -project Arkhe.xcodeproj -scheme Arkhe \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
```

Abre `Arkhe.xcodeproj` en Xcode para ejecutar en simulador o dispositivo.

> **Si compilas tú mismo para instalarlo en tu iPhone:** el proyecto trae mi
> `DEVELOPMENT_TEAM` y `PRODUCT_BUNDLE_IDENTIFIER` (`im.arkhe.client`) en
> `project.yml`. Cámbialos por los tuyos (tu Team ID de Apple y un bundle id
> propio, p. ej. `com.tunombre.arkhe`) y vuelve a ejecutar `xcodegen generate`.
> El `.xcodeproj` no se versiona: se genera a partir de `project.yml`.

## CertFP con soju

1. Genera un certificado de cliente y empaquétalo en `.p12`.
2. En la app: nuevo servidor → SASL = **EXTERNAL** → importa el `.p12`.
3. Copia la **huella SHA-256** que muestra la app y regístrala en la red
   (`/msg NickServ CERT ADD`) o en la config de soju.

## Pendiente (siguiente iteración)

- Notificaciones locales/push para menciones y mensajes privados
- Persistencia del historial de mensajes (hoy sólo se persiste la config)
- Multiplexado completo por red del bouncer (bind / cambio de red en vivo en la UI)
- SCRAM-SHA-256, comandos slash adicionales, tema/ajustes, búsqueda

## App Store

Arkhe está disponible en la App Store (0,99 €) como forma cómoda de instalarlo
y de apoyar el desarrollo. El código es abierto: si prefieres compilarlo tú
mismo, sigue las instrucciones de arriba.

## Licencia

[Apache 2.0](LICENSE) © 2026 Carlos Prieto

El código es abierto bajo Apache 2.0. El **nombre "Arkhe" y el icono** son
marcas del autor y no se licencian con el código (Apache 2.0, §6): un fork
debe usar su propio nombre e icono.
