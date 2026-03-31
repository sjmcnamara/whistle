# Whistle Roadmap

An open-source, decentralized family location app powered by Nostr.
No accounts. No servers. No permissions needed.

---

## Architecture Overview

```
┌─────────────────────────────┐  ┌─────────────────────────────┐
│  iOS App (Swift / SwiftUI)  │  │  Android App (Kotlin/Compose)│
├──────────────┬──────────────┤  ├──────────────┬──────────────┤
│ nostr-sdk    │  MDK (Swift  │  │ nostr-sdk    │  MDK (Kotlin │
│ -swift       │  UniFFI)     │  │ -kotlin      │  UniFFI)     │
├──────────────┴──────────────┤  ├──────────────┴──────────────┤
│  Marmot Event Handlers (kinds 443 / 444 / 445)               │
│  MIP-00→03: KeyPackages, Groups, Welcomes, Messages          │
├──────────────────────────────────────────────────────────────┤
│  Location Payload Schema (app-defined JSON in MLS msgs)      │
│  Group Chat / Nickname / Leave Payload Schemas               │
└──────────────────────────────────────────────────────────────┘
```

**Key design decisions:**

- **MLS (RFC 9420)** for group key management — epoch-based key rotation, forward secrecy, post-compromise security
- **Marmot Protocol (MIP-00→03)** for MLS-over-Nostr event kinds (443/444/445)
- **`mdk-swift` (Marmot Protocol)** — official Swift package, precompiled XCFramework, MIP-00→03 already implemented
- **`nostr-sdk-swift` (rust-nostr)** for relay connectivity, NIP-44 encryption, NIP-59 gift-wrap
- **No NIP-29** (relay-enforced groups) — all group membership is cryptographic, not relay-enforced
- **Location payloads** are app-layer content inside MLS application messages — fully encrypted
- **Invite codes** encode a Nostr relay hint + the inviter's npub, bootstrapped via NIP-59 gift-wrap

---

## Phases

### v0.1 — Foundation ✅
_Project skeleton, identity, relay connectivity_

- XcodeGen project (`project.yml`), `scripts/build.sh`, CI-friendly build
- Clean architecture: `Models / Services / Views / ViewModels`
- Nostr identity: generate nsec/npub, persist to Keychain, display npub QR
- Relay connectivity: connect to configurable relays, publish/subscribe to basic events
- Basic UI shell: tab bar (Map, Chat, Settings), placeholder screens
- `nostr-sdk-swift` integrated as Swift Package dependency

---

### v0.2 — MLS Core (mdk-swift) ✅
_Integrate the official Marmot Swift package — MIP-00→03 already implemented_

> **Note:** The Marmot team publishes [`mdk-swift`](https://github.com/marmot-protocol/mdk-swift) — an official Swift package backed by a precompiled UniFFI XCFramework wrapping `mdk-core` (OpenMLS). This gives us MIP-00→03 without building a Rust bridge ourselves.

- Add `mdk-swift` as SPM dependency (pin to specific commit for stability)
- `MLSService` wrapper: initialise MDK with Keychain-seeded keying material, expose typed Swift API
- MLS key storage: Keychain-backed credential store for MDK signing identity + key packages
- Group lifecycle: create group, publish KeyPackage (kind 443), accept Welcome (kind 444)
- Epoch tracking: detect epoch advances, log rotations
- Unit tests: group create/add/remove/re-add, message encrypt/decrypt round-trips
- Integration test: two simulated identities exchange a Welcome and a message on a local relay

---

### v0.3 — Marmot Event Kinds ✅
_Nostr event kinds 443 / 444 / 445 per Marmot MIP-00→03_

- **Kind 443 — KeyPackage**: generate and publish MLS KeyPackageBundle to configured relays; subscribe to own kind 443 events for rotation
- **Kind 10051 — KeyPackage Relay List**: publish and fetch relay hints for KeyPackage discovery
- **Kind 444 — Welcome**: when adding a group member, fetch their KeyPackage, generate MLS Welcome, deliver via NIP-59 gift-wrap (kind 1059 outer)
- **Kind 445 — Group Events**: publish/subscribe group traffic — Proposals, Commits, Application Messages; content is NIP-44 encrypted TLS-serialised `MLSMessage`
- Group creation flow: creator generates group → publishes KeyPackage → no invite needed yet (self-join v0.3)
- Invite flow: shareable invite code encodes `{relay, inviterNpub, groupId}`; invitee publishes KeyPackage, inviter sends Welcome
- Integration tests: two simulated identities, full add/message/remove lifecycle on a local relay

---

### v0.4 — Location Layer ✅
_CoreLocation wired into MLS group messages_

- **Location payload schema** (inside kind 445 application message):
  ```json
  { "type": "location", "lat": 0.0, "lon": 0.0, "alt": 0.0, "acc": 10.0, "ts": 1700000000, "v": 1 }
  ```
- `LocationService`: CoreLocation wrapper, configurable update interval (default 1 hr), low-battery mode (reduced frequency)
- Background publishing: iOS background modes (significant location change + background fetch), WebSocket reconnect lifecycle
- Pause/resume tracking toggle persisted in UserDefaults
- **Map view**: MapKit, show all family members' latest locations as named pins with timestamp
- Member location cache: decode incoming kind 445 messages, store latest location per group member npub
- `LocationViewModel`: drives map state, handles stale location indicators (> 2× interval = grey pin)

---

### v0.5 — Group Chat & UX ✅
_Full family group experience_

- **Chat payload schema** (inside kind 445 application message):
  ```json
  { "type": "chat", "text": "...", "ts": 1700000000, "v": 1 }
  ```
- Chat view: message list with sender names (npub short form or set nickname), send bar
- Nicknames: each member sets a display name stored in group metadata (kind 445 control message)
- **Group management UI**: member list, add member (show QR / copy invite link), remove member
- **Invite flow UI**: generate shareable invite link/QR; scan or paste to join
- Multiple groups: support joining/creating more than one family group
- Group metadata: group name, member count, last activity
- Settings: relay configuration, update interval slider, low-battery threshold, display name

---

### v0.6 — Reliability & Cross-Device ✅
_Make the app work reliably across multiple devices day-to-day_

- **Cross-device location**: verified phone A sees phone B's pin and vice versa
- **Offline catch-up**: on reconnect, replay missed events using `since` filter on last processed timestamp
- **Crash resilience**: `GroupHealthTracker` detects consecutive MLS failures per group; "Out of sync" badge shown in group list; `clearPendingCommit()` called for all groups on launch
- **Background location audit**: foreground/background mode logged on every location callback
- **Nickname persistence**: `NicknameStore` backed by UserDefaults; display names re-broadcast on launch, name change, group create/join
- **Group join pending state**: "Pending" row in group list after accepting invite, before Welcome arrives (`PendingInviteStore`, UserDefaults-backed)
- **Subscription retry loop**: auto-reconnects and resumes subscriptions with backoff on relay disconnect
- **Map improvements** (v0.6.1): auto-centre on own pin on first appearance; locate-me toolbar button; own pin shows countdown to next update instead of elapsed time

---

### v0.7 — Tap-to-Share Invites ✅
_Frictionless group joining via AirDrop, QR scan, and NFC_

- **AirDrop / deep-link invites**: invites shared as `whistle://invite/<code>` URLs; accepting an AirDrop or tapping a link opens the app and pre-fills the Join Group sheet — no copy-paste required
- **QR code scanning**: "Scan QR Code" in Join Group opens live camera scanner; auto-populates and submits
- **NFC read**: "Tap NFC Tag" (iPhone 7+) reads an NDEF invite URL from any NFC tag and auto-joins
- **NFC write**: "Write to NFC Tag" in Invite sheet writes the `whistle://` URL to a blank NFC sticker; anyone can tap to join
- **One-tap member approval**: after joining, invitee shares a `whistle://addmember/` URL with the admin; admin taps once to approve — no pubkey copy-paste required
- `whistle://` URL scheme registered; `InviteCode.asURL()` / `from(url:)` helpers; `InviteCode.approvalURL(pubkeyHex:groupId:)`
- `NFCReadCoordinator`, `NFCWriteCoordinator`, `QRScannerView`

---

### v0.7.1 — State Management & Reliability ✅
_Patch: Fixed member count stale state, improved event processing consistency_

- **Member count refresh**: member count now updates immediately when members join/leave or are removed
- **Chat header member list**: fixed member names not loading in group chat header subtitle; now subscribes to membership changes
- **Event processing consistency**: MarmotService now reliably refreshes state and notifies subscribers on all event types (commit, proposal, pendingProposal)
- **Cache safety**: member removal now only clears locations after successful group event publication; prevents corrupting cache on MLS errors
- **Fine-grained location cleanup**: when removing a single member, only that member's location is cleared instead of all group members

### v0.7.2 — Welcome retry & key package recovery ✅
_Patch: Robust handling for gift-wrap welcomes that arrive before key package becomes available_

- **Gift-wrap retry queue**: failed welcome events due to missing key package are queued, and retries occur during missed gift-wrap fetch
- **Invitation recovery**: key package refresh now triggers missed gift-wrap fetch, improving user join reliability

### v0.7.3 — Build & Settings Stabilization ✅
_Patch: Compile fixes and settings/about cleanup_

- **Group details compile regression**: fixed member removal swipe action scoping in `GroupDetailView`
- **Settings compile regression**: corrected `SettingsView` structure/scope and switched app-settings navigation to SwiftUI `openURL`
- **Export compliance key**: restored `ITSAppUsesNonExemptEncryption=false` in `Info.plist`
- **About projects links**: Settings now shows direct links to Nostr, OpenMLS, and Marmot Protocol project pages

---

### v0.8 — Security & Identity
_Foundational security + identity improvements split into patch releases_

### v0.8.1 — App Lock ✅
_Device-level access protection_

- **PIN / biometric lock**: FaceID / TouchID gate on app launch
- **Re-auth on reopen**: optional setting to require unlock each time the app returns to foreground
- **Passcode fallback path**: explicit "Use Passcode" action when biometrics are unavailable or inconvenient
- **Auth flow stability**: scene-phase handling avoids repeated prompt cancellations during lock/unlock transitions

### v0.8.2 — Identity Import / Export ✅
_Bring-your-own key and backup flow — released 2026-03-25_

- **Import / export nsec**: allow users to bring an existing Nostr identity or back up their key (NIP-49 encrypted export)
- **NIP-49 encrypted export**: password-protected ncryptsec via NostrSDK's `SecretKey.encrypt(password:)` — scrypt KDF + XChaCha20-Poly1305
- **Import flow**: auto-detects nsec (plaintext) or ncryptsec (encrypted), validates key, destructive confirmation before replacing identity
- **Full identity replacement**: tears down MLS groups, relay subscriptions, caches, and nickname store; re-initialises from scratch with new key
- **Clipboard security**: exported keys auto-expire from clipboard after 60 seconds

### v0.8.3 — Key Lifecycle Hardening ✅
_Ongoing cryptographic hygiene for long-lived groups — released 2026-03-25_

- **Key rotation**: periodic forced epoch advance (self-update + Commit) on configurable schedule — default 7 days, options 1/3/7/14/30 days
- **Forward secrecy audit**: structured logging verifies epoch advances and confirms old epoch keys are unreachable post-rotation (RFC 9420 §14.1)
- **Rotation scheduler**: stale groups rotated on launch; rechecked every 6 hours while app is active; timer cancelled on identity replacement

> **Note:** Secure Enclave integration deferred to v0.9 — Nostr uses secp256k1, which is incompatible with Secure Enclave's P-256 constraint. Will explore SE-wrapped key encryption alongside MLS database encryption.

---

### v0.8.3-android — Android Port ✅
_Full native Android app with cross-platform interop — released 2026-03-26_

- **Kotlin + Jetpack Compose**: native Android UI with Material 3, Hilt DI, Coroutines + Flow
- **Cross-platform MLS**: same MDK (Rust via UniFFI) and NostrSDK (rust-nostr) as iOS — full messaging interop
- **OpenStreetMap**: osmdroid-based family map, no Google Play Services dependency (GrapheneOS compatible)
- **Feature parity**: groups, chat, location sharing, QR invite flow, NIP-49 key import/export, biometric lock, key rotation
- **Monorepo**: Android lives in `android/` alongside iOS source

---

### v0.8.5 — Branding Refresh ✅
_Cosmetic rename from Famstr to Whistle — released 2026-03-31_

- **User-facing rename**: app display name updated to Whistle on iOS and Android
- **Splash and lock UI**: startup and lock screen branding text updated to Whistle
- **Launcher icons**: new Whistle icon pack applied on both platforms
- **No package rename**: internal bundle/application identifiers remain `org.findmyfam`

---

### v0.9 — MLS Database Encryption & Secure Enclave
_Major storage-hardening release for at-rest group key material_

- **MLS database encryption**: replace `newMdkUnencrypted()` workaround — restore SQLCipher or equivalent when MDK supports it (group keys and messages currently in plaintext SQLite)
- **Secure Enclave-wrapped nsec**: encrypt the Nostr secret key with a Secure Enclave-derived key for hardware-bound protection at rest

---

### v1.0 — Social & Connectivity
_Richer group experience and relay management_

- **Custom relay management**: add, remove, toggle relays from Settings; validate connectivity on add
- **Chat commands**: `/list-members`, `/topic <name>`, `/leave` — slash commands parsed in chat input
- **Relay redundancy**: publish to multiple relays, subscribe to all, deduplicate by event ID
- **Privacy audit**: verify no metadata leakage — all group traffic via kind 445, member list not on relays

---

## Branch Strategy

Each phase = `feature/vX.Y-description` branch off `master`.
PR per phase → review → merge to `master`.
Bug-fix releases use `bugfix/v0.x.y` branches.

```
master
  └── feature/v0.1-foundation           ✅ merged
  └── feature/v0.2-mls-bridge           ✅ merged
  └── feature/v0.3-marmot-event-kinds   ✅ merged
  └── feature/v0.4-location-layer       ✅ merged
  └── feature/v0.5-group-chat-ux        ✅ merged
  └── bugfix/v0.5.1                     ✅ merged
  └── feature/v0.6-reliability          ✅ merged
  └── feature/v0.7-tap-to-share         ✅ merged
  └── feature/v0.8.1-app-lock           ✅ merged
  └── feature/v0.8.2-identity-import-export  ✅ merged
  └── feature/v0.8.3-key-lifecycle-hardening ✅ merged
  └── feature/android-v0.8.3            ✅ merged
  └── feature/v0.9-mls-db-encryption
  └── feature/v1.0-social-connectivity
```

---

## Key References

- [Marmot Protocol](https://github.com/marmot-protocol/marmot) — MIP-00→05 specifications
- [Marmot Dev Kit (MDK)](https://github.com/parres-hq/mdk) — Rust reference implementation
- [mdk-swift](https://github.com/marmot-protocol/mdk-swift) — official Marmot Swift package, precompiled XCFramework, MIP-00→03
- [mls-rs (awslabs)](https://github.com/awslabs/mls-rs) — alternative RFC 9420 MLS if mdk-swift is insufficient
- [nostr-sdk-swift](https://github.com/rust-nostr/nostr-sdk-swift) — Swift Nostr SDK
- [nostr-sdk-kotlin](https://github.com/rust-nostr/nostr-sdk-kotlin) — Kotlin Nostr SDK (same rust-nostr core)
- [NIP-44](https://nips.nostr.com/44) — Versioned encryption (ChaCha20 + HKDF)
- [NIP-59](https://nips.nostr.com/59) — Gift wrap (metadata-hiding envelope)
- [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) — MLS specification
- [Locus (discontinued)](https://github.com/Myzel394/locus) — prior art: Nostr location sharing (no MLS)
