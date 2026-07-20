# Architecture

## Project Layout

```
Sources/                  ← iOS app target (Whistle)
├── Models/               ← Domain types (LocationPayload, InviteCode, etc.)
├── Services/             ← Core services (MLSService, RelayService, KeychainService, etc.)
├── ViewModels/           ← UI state (AppViewModel, GroupListViewModel, ChatViewModel, etc.)
└── Views/                ← SwiftUI views

WhistleCore/              ← Shared Swift package (imported by app + tests)
├── Sources/WhistleCore/  ← Protocol constants (MarmotKind), defaults (AppDefaults), shared models
└── Tests/WhistleCoreTests/

WhistleTests/             ← Unit tests for the app target

android/app/              ← Android app (Kotlin / Jetpack Compose)
├── services/             ← MLSService, IdentityService, RelayService, etc.
├── viewmodels/           ← AppViewModel, GroupListViewModel, etc.
├── ui/                   ← Compose screens (groups, settings, map, identity)
├── models/               ← AppSettings, shared types
└── shared/               ← MarmotKind, AppDefaults (mirrors WhistleCore)
```

## High-Level Components

- `AppViewModel`: App orchestration and startup wiring
- `MarmotService`: Protocol orchestration (Nostr + MLS event handling)
- `MLSService`: MLS group and crypto operations (wraps MDK via UniFFI)
- `RelayService`: Relay connectivity, subscriptions, and event publish/fetch
- `LocationService`: CoreLocation (iOS) / Android `LocationManager` (Android) wrapper; emits position updates at the configured interval. Android subscribes to both `GPS_PROVIDER` and `NETWORK_PROVIDER` and selects per-fix by accuracy and freshness (no FusedLocationProvider — keeps the app GMS-free / GrapheneOS-compatible). Map rendering is OSM via osmdroid for the same reason.
- `MotionService`: Movement Aware (v1.1.4+) — detects stationary periods and signals `LocationService` to back off 4× while still
- `BatteryAlertService`: Low Battery Alerts (v1.2.0) — monitors device battery and triggers a tagged location publish + local notification when a configurable threshold is crossed
- `LocationCache`: in-memory latest-location-per-member, keyed `groupId:pubkeyHex`
- `DiagnosticsCollector` (v1.8): assembles a redacted, deterministic `DiagnosticsReport` from live app state for the Share Diagnostics feature (relay/group/epoch health, no location or key material)
- `GroupListViewModel`, `GroupDetailViewModel`, `ChatViewModel`: UI-facing state and actions

## Shared Core (WhistleCore)

Cross-cutting protocol constants and models extracted into a Swift package so both the app target and test target can import them:

- `MarmotKind` — Nostr event kind constants (30443, 444, 445, 1059, 10051, and the Whistle-specific 1080 join-request) and inner message kinds (chat, location, leaveRequest)
- `AppDefaults` — default relays, intervals, preference keys
- Shared model types used across services and views

Android mirrors this via the `:shared` Gradle module (`org.findmyfam.shared`).

## Security Architecture

### Key Storage

- **iOS**: nsec encrypted with AES-GCM using a Secure Enclave-derived key (P-256 ECDH + HKDF). The SE private key never leaves hardware. Falls back to plain Keychain on simulator.
- **Android**: nsec stored in `EncryptedSharedPreferences` backed by Android Keystore with StrongBox preference for hardware-bound encryption.
- **MLS database**: SQLCipher-encrypted via MDK's `keyring-core` integration. Active since v1.1.3 / MDK 0.8.0 (Whistle PR #252 contributed the auto-init that unblocked it). On first launch after upgrading from pre-v1.1.3, the old unencrypted database is detected and replaced with a fresh encrypted one.

### Key Components

- `SecureEnclaveService` (iOS): P-256 ECDH key agreement + AES-GCM encrypt/decrypt
- `EncryptedSecureStorage` (iOS): `SecureStorage`-conforming wrapper that transparently SE-wraps the nsec; auto-migrates plaintext on first load
- `KeychainService` (iOS): raw Keychain CRUD for strings and data
- `IdentityService` (both): key generation, import/export, destroy

### Event Deduplication

When subscribed to multiple relays, the same event may arrive multiple times. Dedup is handled at three levels:

1. **`processedEventIds`** (app-layer): persisted `Set<String>` checked before any processing; survives restarts
2. **`pendingGiftWrapEventIds`** (gift-wrap retry): failed Welcomes queued for retry, not marked processed
3. **MLS `PreviouslyFailed`** (MDK-layer): MDK's own internal cache prevents reprocessing at the crypto level

## Core Data and State Stores

- `AppSettings`: persisted app settings and event processing metadata
- `PendingInviteStore`: pending joins before Welcome is accepted
- `PendingLeaveStore`: pending leave requests awaiting admin confirmation
- `PendingWelcomeStore`: unsolicited Welcomes awaiting user consent
- `JoinRequestStore`: pending `kind:1080` join-requests, keyed by group, awaiting the admin's batch-add (see [Join and Invite Flow](Join-and-Invite-Flow.md))
- `NicknameStore`: pubkey-to-display-name mapping
- `MemberAvatarStore`: member profile photos keyed by pubkey — your own is broadcast to each group as an `AvatarPayload` inside an MLS message, and other members' arrive the same way
- `SharedGroupAvatarStore`: a group's shared photo, admin-set and broadcast to every member (v1.7.3) as a `GroupAvatarPayload` over MLS
- `LocalGroupAvatarStore`: purely personal, per-device group picture — never shared or synced; when both exist the local one wins over the shared photo
- `LocationCache`: latest location by group/member

### Shipped feature notes

- **Member avatars** and the **shared group photo** (v1.7.3) ride inline over MLS as application-message payloads (`AvatarPayload` / `GroupAvatarPayload`), so images never touch a relay in the clear.
- **Presence / stationary sharing** — the `LocationPayload` carries an optional `stationary` flag (v1.7.0, Movement Aware state) and an optional `interval` (v1.2.1, the publisher's own cadence) alongside the position; receivers use them for staleness and presence.
- **Share Diagnostics** (v1.8) — `DiagnosticsCollector` produces a redacted `DiagnosticsReport` the user can export to help debug relay/sync issues without leaking location or key material.

## Event Kinds (Marmot)

| Kind | Name | Purpose |
|------|------|---------|
| `30443` | KeyPackage | MLS credential advertisement — published per-device so others can add them to groups. Addressable event (latest supersedes previous). Was `443` before MDK 0.8.0 / Whistle v1.1.3. |
| `444` | Welcome | MLS group invitation — always delivered inside a kind-1059 gift wrap |
| `445` | Group Event | All in-group traffic: MLS commits, proposals, and application messages (chat, location, nicknames, leave requests) |
| `1059` | Gift Wrap | NIP-59 metadata-hiding envelope — used to deliver Welcomes and join-requests without leaking sender/recipient |
| `1080` | Join Request | Whistle-specific gift-wrapped rumor an invitee sends the inviter, carrying their KeyPackage inline so the admin can batch-add joiners in one commit with no relay fetch. Only seen after unwrapping the kind-1059 gift wrap, so it never reaches relays in the clear. |
| `10051` | KeyPackage Relay List | Hints for which relays hold a user's KeyPackage |

## Encryption Architecture: NIP-44 + NIP-59 + MLS

Whistle uses three independent encryption layers that compose to provide end-to-end confidentiality, forward secrecy, and metadata protection. No single layer is sufficient on its own — each addresses a different threat.

### Layer 1: MLS (RFC 9420) — Group Message Encryption

All group content (chat messages, location updates, nicknames, leave requests) is encrypted by the MLS protocol before it touches any Nostr relay.

**How it works:**

1. `MLSService.createMessage()` takes plaintext content + an inner kind (chat=9, location=1, leaveRequest=2)
2. MDK encrypts the content as an MLS application message using the group's current epoch secrets
3. The ciphertext is placed in the `content` field of a kind-445 Nostr event, signed by the sender's Nostr key, and published to relays

**What's inside a kind-445 event:**

```
┌─────────────────────────────────────────┐
│  Nostr Event (kind 445)                 │
│  pubkey: sender's hex pubkey            │
│  content: MLS ciphertext (opaque)       │  ← only group members can decrypt
│  tags: [["d", group-id], ...]           │
│  sig: sender's Nostr signature          │
└─────────────────────────────────────────┘
         │ MLS decrypt (group secret)
         ▼
┌─────────────────────────────────────────┐
│  Inner unsigned event                   │
│  kind: 9 (chat) / 1 (location) / 2     │
│  content: {"type":"chat","text":"Hi"}   │  ← or location with batt, leaveRequest, etc.
│  pubkey: sender                         │
└─────────────────────────────────────────┘
```

**Cipher:** ChaCha20-Poly1305 with keys derived via HKDF from MLS tree secrets (RFC 9420 Section 8). Every epoch rotation produces fresh key material — old keys are deleted, providing forward secrecy.

**What MLS protects against:** A relay operator or network observer who reads kind-445 events sees only opaque ciphertext. They cannot read messages, determine message types, or extract location data. Only current group members with the epoch key can decrypt.

### Layer 2: NIP-44 — Pairwise Encryption

NIP-44 provides authenticated encryption between two Nostr identities using X25519 ECDH + HKDF + ChaCha20-Poly1305. Whistle does not call NIP-44 directly — it is used internally by the NostrSDK as part of the NIP-59 gift-wrap construction.

**Where NIP-44 appears:**

- Inside `RelayService.giftWrap()` — the NostrSDK encrypts the seal and the outer wrapper using the receiver's public key
- Inside `RelayService.unwrapGiftWrap()` — decrypts the layers using the receiver's private key

NIP-44 ensures that even if a relay stores the gift-wrap event, only the intended recipient can unwrap it.

### Layer 3: NIP-59 — Gift Wrap (Metadata Protection)

NIP-59 hides the sender's identity, the recipient's identity, and the content type of a message from relay operators. Whistle uses it exclusively for Welcome delivery (kind 444).

**Why Welcomes need gift wrapping:**

A Welcome is a 1:1 message from admin to invitee. Without gift wrapping, the relay sees who invited whom (leaking social graph). NIP-59 solves this by wrapping the Welcome in three layers:

```
┌──────────────────────────────────────────────────────┐
│  Outer Event (kind 1059 — gift wrap)                 │
│  pubkey: ephemeral throwaway key                     │  ← hides sender
│  content: NIP-44 encrypted seal                      │  ← hides content
│  tags: [["p", receiver-hex]]                         │  ← only receiver can find it
│  created_at: randomised                              │  ← hides timing
│  sig: signed by ephemeral key                        │
└──────────────────────────────────────────────────────┘
         │ NIP-44 decrypt (receiver's key)
         ▼
┌──────────────────────────────────────────────────────┐
│  Seal (unsigned)                                     │
│  content: NIP-44 encrypted rumor                     │
└──────────────────────────────────────────────────────┘
         │ NIP-44 decrypt (receiver's key)
         ▼
┌──────────────────────────────────────────────────────┐
│  Rumor (unsigned kind 444 — Welcome)                 │
│  content: MLS Welcome message                        │
│  pubkey: admin's real pubkey                         │  ← only visible after unwrapping
└──────────────────────────────────────────────────────┘
```

**What NIP-59 protects against:**

- **Relay operators** see kind 1059 from an ephemeral key — they cannot determine who sent it or what it contains
- **Network observers** cannot correlate the gift wrap to any real identity
- **Timing analysis** is mitigated by the randomised `created_at` timestamp
- The `p` tag lets the receiver's relay filter deliver it, but reveals nothing about the sender or group

### How the Three Layers Compose

| Threat | MLS | NIP-44 | NIP-59 |
|--------|-----|--------|--------|
| Relay reads message content | Encrypted | — | — |
| Relay reads location data | Encrypted | — | — |
| Relay knows group members | Member list never on relay | — | — |
| Relay sees who invited whom | — | — | Sender hidden by ephemeral key |
| Relay correlates Welcome timing | — | — | Randomised timestamp |
| Compromised old keys decrypt past messages | Forward secrecy (epoch rotation) | — | — |
| Attacker impersonates sender | MLS authenticates senders | — | — |

### Welcome Delivery Flow (Full Path)

In the current (v1.7+) flow the admin gets the invitee's KeyPackage **inline** from the gift-wrapped `kind:1080` join-request, so step 1 is normally a local read with no relay round-trip; the `kind:30443` relay fetch remains only as a manual fallback. Several joiners are added in a single commit — see [Join and Invite Flow](Join-and-Invite-Flow.md).

```
Admin's device                            Relay                         Invitee's device
─────────────────                         ─────                         ──────────────────
1. KeyPackage from join-request      ←    kind-1080 rumor (inline, primary)
   (fallback: fetchKeyPackage         →    kind 30443 query
                                       ←    invitee's KeyPackage)
2. mls.addMembers(keyPackage)
   → MLS Welcome + Commit
3. publish kind-445 commit           →    stored
4. verifyEventOnRelay(commitId)      →    confirmed (MIP-02)
5. giftWrap(welcome, receiver)
   → NIP-44 encrypt (seal)
   → NIP-44 encrypt (outer)
   → sign with ephemeral key
6. publish kind-1059                 →    stored
                                                                       7. receive kind-1059
                                                                       8. unwrapGiftWrap()
                                                                          → NIP-44 decrypt (outer)
                                                                          → NIP-44 decrypt (seal)
                                                                          → extract kind-444 rumor
                                                                       9. mls.processWelcome(rumor)
                                                                          → MLS joins group
                                                                       10. Group appears in list
```

### Group Message Flow (Full Path)

```
Sender's device                           Relay                         Recipient's device
───────────────                           ─────                         ──────────────────
1. mls.createMessage(plaintext)
   → MLS encrypt with group secret
   → wrap in kind-445 event
   → sign with sender's Nostr key
2. publish kind-445                  →    stored
                                                                       3. receive kind-445
                                                                       4. mls.processIncomingEvent()
                                                                          → MLS decrypt with group secret
                                                                          → extract inner kind + content
                                                                       5. routeApplicationMessage()
                                                                          → kind 9: update chat
                                                                          → kind 1: update map pin
                                                                          → kind 2: queue leave request
```

## Reliability Notes

- `fetchMissedGiftWraps()` catches up on Welcomes that arrived while the app was offline
- Pending gift-wrap IDs are retried after key package refresh
- `clearPendingCommit()` runs on launch to recover from mid-commit crashes
- MLS epoch advances (key rotation) on a configurable schedule (default 7 days) for post-compromise security
- Membership changes trigger group refresh and view-model updates
