# Famstr Roadmap

An open-source, decentralized family location app powered by Nostr.
No accounts. No servers. No permissions needed.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────┐
│  iOS App (Swift / SwiftUI)                               │
├──────────────────────────┬──────────────────────────────┤
│  nostr-sdk-swift         │  MLS Bridge (Swift layer)     │
│  (relay connect,         │  UniFFI → mls-rs-uniffi       │
│  NIP-44, NIP-59,         │  (or MDK/OpenMLS)             │
│  event pub/sub)          │                               │
├──────────────────────────┴──────────────────────────────┤
│  Marmot Event Handlers (kinds 443 / 444 / 445)           │
│  MIP-00: Credentials & KeyPackages                       │
│  MIP-01: Group Construction                              │
│  MIP-02: Welcome Events                                  │
│  MIP-03: Group Messages                                  │
├─────────────────────────────────────────────────────────┤
│  Location Payload Schema (app-defined JSON in MLS msgs)  │
│  Group Chat Payload Schema                               │
└─────────────────────────────────────────────────────────┘
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

### v0.6 — Reliability & Cross-Device
_Make the app work reliably across multiple devices day-to-day_

- **Cross-device location**: verify phone A sees phone B's pin and vice versa; debug the full relay→MLS decrypt→`routeApplicationMessage`→`locationCache` path for incoming location messages
- **Offline catch-up**: on reconnect, replay missed kind 445 Commits in sequence; handle epoch gaps gracefully (request re-add if unrecoverable)
- **Crash resilience**: MLS state corruption detection and recovery — prompt user to leave & re-join if epoch gap is unrecoverable
- **Background location audit**: measure real-world background wake intervals, validate significant location change wakes, test app-suspended behaviour after ~3 min
- **Nickname persistence**: `NicknameStore` currently in-memory — nicknames lost on restart until others re-broadcast; persist to UserDefaults or re-request on startup
- **Group join pending state**: show "Waiting for admin approval" after accepting an invite, before the Welcome is received
- **UI polish**:
  - Fix Display Name label line-wrapping in SettingsView
  - Add icons for interval picker (clock) and authorization status (checkmark)

---

### v0.7 — Security & Identity
_Production-grade key security and identity management_

- **PIN / biometric lock**: FaceID / TouchID gate on app launch; optional per-session re-auth
- **MLS database encryption**: replace `newMdkUnencrypted()` workaround — restore SQLCipher or equivalent when MDK supports it (group keys and messages currently in plaintext SQLite)
- **Import / export nsec**: allow users to bring an existing Nostr identity or back up their key (NIP-49 encrypted export)
- **Key rotation**: periodic forced epoch advance (UpdateProposal + Commit) on configurable schedule — default 7 days
- **Forward secrecy audit**: verify old epoch keys are zeroed/deleted post-rotation
- **Secure Enclave** for MLS signing keys (where hardware supports it); fallback to Keychain

---

### v0.8 — Social & Connectivity
_Richer group experience and easier onboarding_

- **Tap-to-share invites**: NFC / AirDrop to share group invite + npub of invitee — like iOS contact sharing
- **Custom relay management**: add, remove, toggle relays from Settings; validate connectivity on add
- **Chat commands**: `/list-members`, `/topic <name>`, `/leave` — slash commands parsed in chat input
- **Relay redundancy**: publish to multiple relays, subscribe to all, deduplicate by event ID
- **Privacy audit**: verify no metadata leakage — all group traffic via kind 445, member list not on relays

---

## Branch Strategy

Each phase = `feature/v0.x-description` branch off `master`.
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
  └── feature/v0.6-reliability
  └── feature/v0.7-security-identity
  └── feature/v0.8-social-connectivity
```

---

## Key References

- [Marmot Protocol](https://github.com/marmot-protocol/marmot) — MIP-00→05 specifications
- [Marmot Dev Kit (MDK)](https://github.com/parres-hq/mdk) — Rust reference implementation
- [mdk-swift](https://github.com/marmot-protocol/mdk-swift) — official Marmot Swift package, precompiled XCFramework, MIP-00→03
- [mls-rs (awslabs)](https://github.com/awslabs/mls-rs) — alternative RFC 9420 MLS if mdk-swift is insufficient
- [nostr-sdk-swift](https://github.com/rust-nostr/nostr-sdk-swift) — Swift Nostr SDK
- [NIP-44](https://nips.nostr.com/44) — Versioned encryption (ChaCha20 + HKDF)
- [NIP-59](https://nips.nostr.com/59) — Gift wrap (metadata-hiding envelope)
- [RFC 9420](https://www.rfc-editor.org/rfc/rfc9420.html) — MLS specification
- [Locus (discontinued)](https://github.com/Myzel394/locus) — prior art: Nostr location sharing (no MLS)
