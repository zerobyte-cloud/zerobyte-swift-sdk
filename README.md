# ZeroByte Swift SDK

The Swift client for ZeroByte, an end-to-end encrypted relay between two paired
devices of one app. It runs on iOS 16, macOS 13, watchOS 9, tvOS 16 and
visionOS 1 and uses only Apple frameworks: CryptoKit for the cryptography,
URLSession for HTTP and the WebSocket.

## How it works

Two devices pair once and agree a 32-byte link key and a link id. From these,
each device derives the mailbox name, an access token and one encryption key
per direction. Every message is sealed with ChaCha20-Poly1305 on the device
that sends it. The relay holds the sealed envelope until the other device
collects it, and it never has a key to open it with.

The wire format is specified in
[Relay Protocol v1](https://github.com/zerobyte-cloud/zerobyte-protocol/blob/master/relay-v1.md).

## Installation

In Xcode, choose File > Add Package Dependencies and enter the repository URL.
In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/zerobyte-cloud/zerobyte-swift-sdk.git", from: "1.0.0")
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "ZeroByte", package: "zerobyte-swift-sdk"),
        // Only if the app uses Apple push notifications:
        .product(name: "ZeroBytePush", package: "zerobyte-swift-sdk"),
    ])
]
```

| Library | What it holds |
|---|---|
| `ZeroByte` | Keys, envelopes, the relay client, `Link`, signal and ICE |
| `ZeroBytePush` | APNs registrations for the relay's APNs module, and the tag in a push |
| `ZeroByteTimeline` | One keyed state both devices keep, synced as commits that merge into one timeline |

## Usage

```swift
import ZeroByte

// Both devices agreed `linkKey` (32 bytes) and `linkID` when they paired.
let credentials = try Credentials(linkKey: linkKey, linkID: linkID)
let base = URL(string: "https://relay.example.com/v1/")!  // your relay
let relay = Relay(appID: "<your app id>", credentials: credentials, base: base)
let link = Link(
    credentials: credentials,
    sends: .primaryToCompanion,
    transport: relay,
    lastReceived: savedLastReceived
)

try await link.send(Data("hello".utf8))

for await _ in relay.watch(direction: .companionToPrimary) {
    for message in try await link.receive() {
        handle(message.plaintext)
    }
}
```

- **Pairing** is the app's job: for example a QR code carrying a fresh 32-byte
  key, or an ECDH exchange confirmed by comparing digits on both screens. Store
  the link key in the Keychain.
- **Directions.** The primary holds the source of truth and sends
  `.primaryToCompanion`; the companion sends `.companionToPrimary`.
- **State.** Persist `link.lastReceived` and pass it back on the next launch,
  so messages are not delivered twice.
- **Unpairing.** Call `try await link.erase()` to delete the mailbox at once.
- **The relay.** `base` is your relay's `/v1/` URL, with the trailing slash.
  There is no default.

The app id identifies your app on your relay. Generate one with
`npm run app-id` in a clone of
[zerobyte-relay](https://github.com/zerobyte-cloud/zerobyte-relay) and add it
to `RELAY_APPS`.

### Relay extensions

These work on relays and apps that enable them (see the relay's README); a
relay that doesn't answers `RelayError.unavailable(status: 404)`. Any call may
throw `RelayError.rateLimited(retryAfter:)`; wait and retry.

**Push.** The reader registers its APNs token on the direction it reads; the
writer asks for a push per message. APNs lives in the separate `ZeroBytePush`
library, as it does in the relay (a module loaded only when configured):

```swift
import ZeroBytePush

// On the companion, after every launch:
try await relay.registerPush(
    .apns(deviceToken: apnsToken, environment: .production,
          tag: tagForThisLink, alert: "New message"),
    direction: .primaryToCompanion)

// On the primary:
try await link.send(Data("hello".utf8), notify: .alert)
```

The push carries only `userInfo["zerobyte"]["tag"]`. A Notification Service
Extension reads it with `ZeroBytePushPayload.tag(in: userInfo)`, finds the link
by its tag, calls `link.receive()` and replaces the notification's text with
the decrypted message. Another push service is a
`PushRegistration(service:fields:tag:alert:)` for a module the relay has. The relay sends no push while
`watch` is open, which pings every 30 seconds.

**Signal.** A rendezvous for a direct connection. Frames are sealed under
signal keys derived from the link key, so the relay can neither read nor forge
them:

```swift
let channel = relay.signal(sends: .primaryToCompanion)
for await event in await channel.events() {
    switch event {
    case .peer(true): try await channel.send(offerData)
    case .peer(false): break
    case .message(let data): handle(data)  // answer, ICE candidates
    }
}
let ice = try await relay.iceServers()  // STUN/TURN for the peer connection
```

### Timeline

`ZeroByteTimeline` keeps one keyed state on both devices and sends only what
changed, as commits that every device merges into the same order
([Timeline v1](https://github.com/zerobyte-cloud/zerobyte-protocol/blob/master/timeline-v1.md)).
A key's entry is the one with the latest stamp, so both copies converge
whatever order things arrive in, and a change made after seeing another
always wins over it.

```swift
import ZeroByteTimeline

var timeline = (try? Timeline(encoded: saved)) ?? Timeline()

// Setting a key to the value it already holds stages nothing.
try timeline.set(planData, at: TimelineSlot("plan", plan.id.uuidString))

let outcome = try await TimelineRelay.sync(
    &timeline, credentials: credentials, transport: relay,
    sends: .companionToPrimary, notify: .silent
) { save($0.encoded()) }

for update in outcome.updates {
    apply(update.slot, update.value)  // nil: deleted
}
```

- A device that can produce its own values again (from a database, say) creates
  its timeline with `forgetsOwnValues:` naming those collections and passes
  `values:` to `sync`; the timeline then keeps only their digests.
- Two devices on the same network can skip the relay: send
  `timeline.state()`, answer the other's state with
  `timeline.catchUp(after:)` and `receive` each part.
- A value must fit in one message (1 MiB); split larger values over keys.

## Testing

```sh
swift test
```

This runs the protocol vectors and the `Link` tests. To also test against a
real relay, start one locally (see zerobyte-relay) and run:

```sh
RELAY_BASE=http://127.0.0.1:8080/v1/ RELAY_APP=<app id> swift test
```

For the extensions, add an app with `signal` (and `push=<bundle id>`) to the
relay and set `RELAY_SIGNAL_APP=<that id>` (and `RELAY_PUSH=1`).

`Tests/ZeroByteTests/relay-v1.json` is copied from the independent reference in
[zerobyte-protocol](https://github.com/zerobyte-cloud/zerobyte-protocol/tree/master/spec).
Never regenerate it from this package.

## Licence

Apache-2.0, see [`LICENSE`](LICENSE).

## About ZeroByte

ZeroByte is an open-source project by Szymon Michalik: the protocol, the relay
and the SDKs. To use ZeroByte in your app, run your own relay (see
[zerobyte-relay](https://github.com/zerobyte-cloud/zerobyte-relay)) or register the app on
the hosted relay at [console.zerobyte.cloud](https://console.zerobyte.cloud).
