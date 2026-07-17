# Whistle

[![CI](https://github.com/sjmcnamara/whistle/actions/workflows/ci.yml/badge.svg)](https://github.com/sjmcnamara/whistle/actions/workflows/ci.yml)
[![CodeQL](https://github.com/sjmcnamara/whistle/actions/workflows/codeql.yml/badge.svg)](https://github.com/sjmcnamara/whistle/actions/workflows/codeql.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/sjmcnamara/whistle/badge)](https://scorecard.dev/viewer/?uri=github.com/sjmcnamara/whistle)
[![iOS](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fcodecov.io%2Fapi%2Fv2%2Fgithub%2Fsjmcnamara%2Frepos%2Fwhistle%2Freport%3Fflag%3Dios&query=%24.totals.coverage&suffix=%25&label=iOS&color=brightgreen)](https://app.codecov.io/gh/sjmcnamara/whistle?flags%5B0%5D=ios)
[![WhistleCore](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fcodecov.io%2Fapi%2Fv2%2Fgithub%2Fsjmcnamara%2Frepos%2Fwhistle%2Freport%3Fflag%3Dwhistlecore&query=%24.totals.coverage&suffix=%25&label=WhistleCore&color=brightgreen)](https://app.codecov.io/gh/sjmcnamara/whistle?flags%5B0%5D=whistlecore)
[![Android](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fcodecov.io%2Fapi%2Fv2%2Fgithub%2Fsjmcnamara%2Frepos%2Fwhistle%2Freport%3Fflag%3Dandroid&query=%24.totals.coverage&suffix=%25&label=Android&color=brightgreen)](https://app.codecov.io/gh/sjmcnamara/whistle?flags%5B0%5D=android)
![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20Android-lightgrey)
[![License: Unlicense](https://img.shields.io/badge/License-Unlicense-blue.svg)](LICENSE)

> Marmots are profoundly social animals. They live in close family groups, keep watch for one another, and communicate through sharp whistles that carry across distance — a simple system built on trust, awareness, and care.

Most location-sharing apps route your real-time movements through servers that store, analyse, and monetise your patterns. They require accounts, phone numbers, and emails — turning a simple "are you home safe?" into permanent surveillance infrastructure you didn't ask for.

Whistle is built around a different principle.

It’s a private, encrypted group network designed to keep people connected without intermediaries. No servers. No accounts. No data trails. Just direct, secure sharing between the people you choose. Built on open-source tools and public cryptography, it uses Nostr for identity and message delivery, MLS for end-to-end encryption, and Marmot as the glue that binds it all together.

Share your location when it matters, with the people who need it. Stop when it doesn’t.

## Who it's for

**The family circle** — quiet reassurance that someone got home safe, or is on their way, without the ping of a constant text. No history being archived. Shared in the moment, then gone.

**The festival crew** — find each other across four stages without the endless "where are you?" chain. No need to swap numbers with everyone or install a 200MB official app. Group evaporates Monday morning.

**The late walk home** — temporary visibility while you're in a taxi or crossing an unfamiliar city. The digital equivalent of "text me when you're home" — without handing your data to a platform.

**The school trip** — lightweight coordination for teachers and small groups splitting off, without turning the day into a surveillance exercise.

## What it does

Create or join an encrypted group, share a live map with your people, and chat — all end-to-end encrypted. No relay ever sees plaintext location data or group membership.

- **Family groups** — create or join with a shareable invite code
- **Live map** — see everyone's location, updated on a configurable interval
- **Group chat** — built-in encrypted messaging for the whole group
- **Tap-to-join** — share invites via QR code, NFC tap, or AirDrop
- **Whistle** — force an instant location update to your group on demand, ignoring the timer and battery backoff
- **Pause/resume** — stop sharing your location anytime without leaving the group
- **Movement aware** — automatically backs off location updates when a device is stationary, resumes normal rate on movement
- **Low-battery alerts** — notifies the group when a member's battery is critically low
- **Multiple groups** — belong to more than one circle at a time
- **Cross-platform** — native iOS and Android apps that interop seamlessly
- **No accounts** — identity is a Nostr keypair stored on-device
- **Open protocol** — built on [Nostr](https://nostr.com) + [MLS](https://www.rfc-editor.org/rfc/rfc9420.html) via the [Marmot Protocol](https://github.com/marmot-protocol/marmot); no proprietary server, no lock-in

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
| 30443 | MLS KeyPackage — used to add members to the group (addressable, MDK 0.8.0+) |
| 444 | Welcome — bootstraps a new member's group state (gift-wrapped) |
| 445 | Group Event — all in-group traffic: Commits, location updates, chat |
| 10051 | KeyPackage relay list |

## Requirements

### iOS
- Xcode 16+ (tested on Xcode 26)
- iOS 17.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### Android
- Android Studio — latest stable recommended (AGP 8.13)
- Android SDK 36+
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

v1.6.5 — Production ready. iOS and Android. See [ROADMAP.md](ROADMAP.md) for full history and [CHANGELOG.md](CHANGELOG.md) for release notes.

## Wiki

Project operational docs live in [website/docs/wiki/](website/docs/wiki/index.md) — also rendered as the "Reference" section of the Whistle site.
