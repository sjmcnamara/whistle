# Whistle

An open-source, decentralized family location sharing app powered by Nostr.

No accounts. No central server. No permissions needed.

## What it does

Family members create or join a shared encrypted group. Each member periodically posts their location to the group. Everyone in the group can see each other on a live map.

All communication is end-to-end encrypted using MLS (Messaging Layer Security, RFC 9420) and transported over the Nostr protocol via the [Marmot Protocol](https://github.com/marmot-protocol/marmot) event kinds. No relay ever sees plaintext location data or group membership.

- **Family groups** — create or join with a shareable invite code
- **Cross-platform** — native iOS and Android apps that interop seamlessly in the same encrypted groups
- **Tap-to-join** — share invites via AirDrop, QR code scan, or NFC tap; one-tap admin approval
- **Live map** — see all family members' locations, updated on a configurable interval (default: 1 hr)
- **Group chat** — built-in encrypted chat for the whole family
- **Pause/resume** — stop sharing your location anytime without leaving the group
- **Low-battery mode** — automatically reduces update frequency when battery is low
- **Multiple groups** — join more than one family group
- **No accounts** — identity is a Nostr keypair stored on-device
- **Open protocol** — built on Nostr + MLS; no proprietary server, no lock-in

## Security Model

Location and chat payloads are encrypted using MLS (RFC 9420):

- **Epoch-based key rotation** — group keys advance with every membership change
- **Forward secrecy** — old messages stay secret even if current keys are compromised
- **Post-compromise security** — future messages are secure after a key rotation
- **Member roster** — tracked cryptographically, not by relay policy
- **Proper join/leave/rejoin handling** — via MLS Add/Remove Proposals and Commits

Group traffic is published as Marmot-compatible Nostr events:

| Kind | Purpose |
|------|---------|
| 443 | MLS KeyPackage — used to add members to the group |
| 444 | Welcome — bootstraps a new member's group state (gift-wrapped) |
| 445 | Group Event — all in-group traffic: Commits, location updates, chat |
| 10051 | KeyPackage relay list |

## Requirements

### iOS
- Xcode 16.1+
- iOS 17.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Android
- Android Studio Hedgehog+
- Android SDK 34+
- Java 17

Pre-built native libraries (MDK, NostrSDK) are checked into `android/app/src/main/jniLibs/`. No Rust toolchain needed for development.

## Project Structure

```
whistle/
├── Sources/              ← iOS app (Swift / SwiftUI)
│   ├── Models/
│   ├── Services/
│   ├── ViewModels/
│   └── Views/
├── WhistleCore/          ← Shared Swift package (models, protocol constants, defaults)
│   ├── Sources/WhistleCore/
│   └── Tests/WhistleCoreTests/
├── WhistleTests/         ← iOS unit tests
├── Resources/            ← iOS assets
├── project.yml           ← iOS XcodeGen config
├── android/              ← Android (Kotlin / Jetpack Compose)
│   ├── app/
│   └── build.gradle.kts
├── CHANGELOG.md
└── ROADMAP.md
```

## Status

Active development — iOS and Android at v0.9.1. See [ROADMAP.md](ROADMAP.md) for full history and upcoming phases.

## Wiki

Project operational docs live in [docs/wiki/Home.md](docs/wiki/Home.md).

## License

MIT
