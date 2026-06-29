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
│  Marmot Event Handlers (kinds 30443 / 444 / 445)             │
│  MIP-00→03: KeyPackages, Groups, Welcomes, Messages          │
├──────────────────────────────────────────────────────────────┤
│  Location Payload Schema (app-defined JSON in MLS msgs)      │
│  Group Chat / Nickname / Leave Payload Schemas               │
└──────────────────────────────────────────────────────────────┘
```

**Key design decisions:**

- **MLS (RFC 9420)** for group key management — epoch-based key rotation, forward secrecy, post-compromise security
- **Marmot Protocol (MIP-00→03)** for MLS-over-Nostr event kinds (30443/444/445)
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

### v0.8.6 — Bug Fixes & Rename Cleanup ✅
_QR fix, unread fix, project rename — released 2026-04-01_

- **QR invite code**: iOS invite share now encodes raw base64 in the QR, matching Android (was encoding full deep link URL)
- **Remove "Share my key with admin"**: dropped post-join ShareLink; admin scans invitee's npub QR directly
- **Map group filter stale after leave/evict**: auto-clears on both platforms when selected group is no longer active
- **Unread indicator fix**: dedicated `lastChatTimestamps` store tracks chat-only messages; pull-to-refresh no longer re-triggers unread dot for location/nickname MLS events
- **Dynamic version string**: iOS and Android Settings read version from build config instead of hardcoded string
- **Project rename**: `FindMyFam` → `Whistle` (project, targets, schemes); `FindMyFamCore` → `WhistleCore`; `FindMyFamTests` → `WhistleTests`

---

### v0.9 — MLS Database Encryption ✅
_Storage-hardening release — wired for at-rest encryption, blocked on MDK UniFFI binding — released 2026-04-01_

- **MLS database encryption**: both platforms now call `newMdk(serviceId:dbKeyId:)` which delegates key management to MDK's `keyring-core` (iOS Keychain / Android Keystore); SQLCipher PRAGMA sequence handled internally by MDK
- **Graceful fallback**: `keyring-core` requires `set_default_store()` which is not yet exposed via UniFFI; falls back to `newMdkUnencrypted` with warning log until [marmot-protocol/mdk#243](https://github.com/marmot-protocol/mdk/issues/243) is resolved
- **Stale DB resilience**: pre-0.9 plaintext DB detected and deleted on first launch (force-reinstall policy, no migration)
- **iOS file sharing removed**: `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` removed from Info.plist
- **MDK binary updated**: pinned revision advanced to `c58a77f`

### v0.9.1 — Settings Reorganisation ✅
_Cleaner Settings UX — released 2026-04-01_

- **Settings / Advanced split**: main Settings keeps Identity (Nostr key + display name), Location, and About; Import/Export Key, Security, Relays, and Connection moved to new Advanced Settings screen
- **Android identity card**: inline QR replaced with tappable row navigating to full-screen IdentityCardScreen (matching iOS pattern)
- **Android About parity**: added missing Protocol and GitHub source link to match iOS

### v0.9.2 — Splash & Appearance ✅
_Branding polish and dark mode support — released 2026-04-01_

- **Dark mode setting**: three-way Appearance picker (System / Light / Dark) in Settings; iOS uses `preferredColorScheme`, Android overrides `isSystemInDarkTheme()` via reactive `StateFlow`
- **Splash screen rebrand**: replaced SF Symbol / text-based splash with Whistle wordmark + zap icon PNG; simplified to a clean loader view on both platforms

### v0.9.3 — Marmot Security Audit ✅
_MIP-02 compliance — released 2026-04-02_

- **Commit/Welcome ordering** (MIP-02): commit events are verified on relay before Welcome is sent, preventing state forks
- **Post-join self-update** (MIP-02): new members immediately rotate key material after joining, limiting KeyPackage exposure window
- **Gift-wrap retry expiry**: stale/unrecoverable gift-wrap event IDs purged after one retry pass

### v0.9.4 — UX & Consent Fixes ✅
_Quality-of-life fixes, welcome consent, burn hardening — released 2026-04-02_

- **Welcome consent**: unsolicited group adds require user approval; only invite-matched Welcomes auto-accept
- **Burn Identity**: Advanced Settings action to nuke identity, groups, and MLS state and start fresh; old key explicitly destroyed from secure storage, MLS DB files zero-filled before deletion, all residual data purged
- **Admin action badge**: orange dot on group icon when leave approval is pending
- **Cancel stale invites**: dismiss stuck pending invites from the group list
- **Create Group auto-focus**: keyboard opens on group name field immediately
- **Pending-welcome groups hidden**: groups awaiting consent filtered from list after refresh
- **Welcome invite UI**: compact checkmark / X icons for accept/decline
- **QR scanner auto-dismiss**: camera closes after scanning an npub
- **Add Member tap targets** (iOS): `.buttonStyle(.borderless)` + 44pt min frames prevent mis-taps
- **Map filter** (iOS): pending-leave groups hidden from picker; auto-clears on leave request
- **Admin leave approval**: green "Approve" action replaces generic swipe-to-delete

---

### v1.0 — Production Readiness
_Relay polish, security hardening, code quality gates_

- **Custom relay management** ✅: add/remove/toggle relays in Advanced Settings with URL validation, live disconnect/reconnect, per-relay connection status dots, dynamic Connection section (iOS & Android)
- **Relay dedup verification** ✅: confirmed event ID deduplication via `processedEventIds` + MLS `PreviouslyFailed` + gift-wrap retry queue; added structured debug logging on both platforms
- **Privacy audit** ✅: systematic review passed — no metadata leakage (all payloads MLS-encrypted via kind 445, member lists local-only, gift-wrap hides sender via ephemeral key, no `p`/`e` tags leak group members). Fixed: removed plaintext nsec UserDefaults fallback from KeychainService; MLS encryption mode already logged at startup
- **Secure Enclave-wrapped nsec** ✅ (iOS): nsec AES-GCM encrypted with Secure Enclave P-256 ECDH-derived key; hardware-bound, auto-migrates plaintext nsec; simulator falls back to plain Keychain. Android: `MasterKey` now requests StrongBox backing; diagnostic log on startup
- **Android map filter parity** ✅: pending-leave groups hidden from map filter picker (matching iOS v0.9.4)
- **CI merge gate** ✅: required status checks enabled on master — all CI jobs must pass before merge
- **SwiftLint strict mode** ✅: all 336 files clean, 0 violations; `--strict` flag enabled in CI

### v1.0.1 — UX Polish & Coverage ✅
_Released 2026-04-03_

- **Chat timestamps** (iOS): wall-clock time ("2:30 PM") instead of relative age — matches Android, Signal, WhatsApp
- **"Load earlier messages" fix** (iOS): `hasMore` was not `@Published`; button now hidden correctly when all messages loaded
- **Imprecise location fix** (iOS): payload stamped with broadcast time, not OS acquisition time; `horizontalAccuracy < 0` filtered before pipeline; pin label truncation fixed with `minimumScaleFactor`
- **Location fuzzing** (iOS & Android): Off / 10 m / 50 m / 200 m random offset in Advanced Settings → Location Privacy
- **Codecov coverage reporting**: informational-only upload on every CI run; `ios` and `whistlecore` flags for per-layer breakdown

### v1.0.2 — Test Coverage & DB Stability ✅
_Released 2026-04-05_

- **Groups lost after force quit fix** (iOS): removed unconditional `deleteDatabase()` call in `MLSService` fallback path; unencrypted fallback now opens existing DB directly
- **Protocol round-trip tests — Tier 1** (iOS): 27 tests covering group lifecycle, Welcome flow, message delivery (chat/location/nickname), key rotation, leave requests, invite codes, and subscription setup
- **Failure & recovery tests — Tier 2** (iOS): 40 tests covering error handling, health tracker, corrupt events, message ordering/pagination, concurrent ops, identity lifecycle, MLS reset, and store deduplication
- **Android unit tests**: 6 new test suites, 60 new tests (LocationFuzz, LocationViewModel, MemberSort, GroupListItem, ChatMessageItem, MemberAnnotation); total Android tests now 90
- **Android coverage fix** (CI): switched to AGP built-in `createDebugUnitTestCoverageReport`; Codecov Android reporting now correct
- **Codecov: exclude Compose UI**: `ui/`, `MainActivity`, `FindMyFamApp`, `di/` excluded from metrics

---

### v1.1.1 — Onboarding Flow & Startup Performance ✅
_First-run experience before location permission + cold-start speed improvements_

- **Welcome carousel**: 3-card first-run screen explaining what Whistle is (encrypted location sharing, family groups, no accounts/servers) — shown once on cold start with no existing identity
- **Permission framing screen**: dedicated screen with plain-language explanation before the `CLLocationAlwaysUsageDescription` system dialog fires
- `hasCompletedOnboarding` flag in UserDefaults gates the flow
- **Deferred Rust init on first launch**: onboarding shows immediately — identity, MLS, and relay startup run only after onboarding completes
- **Relay connect moved to background Task**: splash no longer blocks on WebSocket connections
- **MLS init off main thread**: `newMdkUnencrypted()` runs on `DispatchQueue.global()`; `newMdk()` (always-failing encrypted init) skipped entirely to avoid keyring timeout
- **Launch screen logo**: `UILaunchScreen` shows Whistle wordmark during binary loading
- **Minimum splash reduced**: 1.5s → 1.0s

---

### v1.1.2 — System Settings Deep Links ✅
_Surface settings shortcuts where the app hits permission walls + DB rename_

- **Location denied → Open Settings** (iOS & Android): tapping opens the app's Settings page to re-enable location permission
- **Location restricted** (iOS): informational label when device policy prevents location access
- **Biometric settings link** (iOS & Android): shown below App Lock toggle when enabled — opens Face ID & Passcode / Security settings
- **MLS database renamed**: `findmyfam-mdk.db` → `whistle.db` (iOS), `marmot.db` → `whistle.db` (Android) with automatic migration

---

### chore — MDK 0.8.0 upgrade ✅
_Dependency upgrade, no version bump — merged 2026-05-05_

- **MDK 0.8.0**: keyring auto-init in `newMdk()` (our PR #252 shipped), kind:30443 addressable KeyPackage events (MIP-00 migration), MIP-05 notification primitives, security hardening (admin pruning, ciphertext dedup, replay rejection)
- **CI**: resolved mdk-swift SPM/LFS checkout failure — CI now clones mdk-swift with explicit `git lfs pull` via `scripts/ci_use_local_mdk.py`; `Package.resolved` tracked in git for reproducible builds
- **SE simulator tests**: fixed 3 `SecureEnclaveServiceTests` failures — runtime `isAvailable` check replaces compile-time `#if targetEnvironment(simulator)` guard (iOS 26 simulator now reports SE available)

---

### v1.1.3 — SQLCipher Activation & Promote to Admin ✅
_Completed the deferred SQLCipher encryption story; new admin management action — released 2026-04-23_

- **MLS database encryption activated** (iOS): `MLSService.initialise()` now calls `newMdk()` directly — SQLCipher-encrypted database on first launch. Blocked since v0.9 on MDK #243 (`set_default_store()` not UniFFI-exposed); resolved via contributor improvement of [marmot-protocol/mdk#252](https://github.com/marmot-protocol/mdk/pull/252). Stale unencrypted databases from pre-v0.9 detected and replaced.
- **Promote to admin** (iOS): swipe right on a member in Group Detail to promote them; admin-only action, hidden for self and existing admins; uses MDK `updateGroupData()` to append to `admin_pubkeys`
- **CLAUDE.md**: process notes for build, versioning, MDK local/remote setup, and known test failures

### v1.1.4 — Movement Aware ✅
_Battery-saving motion-adaptive location intervals_

- **Movement Aware mode** (iOS & Android): device stationary → 4× location interval backoff; confirmed movement (30s debounce, confirmed activity types only) → resumes normal rate
- **Stationary badge on map pin**: orange `figure.stand` overlay on own pin while stationary; clears on movement
- **Accurate next-update countdown**: pin timer reflects the effective multiplied interval

### v1.1.5 — Android Parity ✅
_Brought Android up to feature parity with iOS v1.1.x — released 2026-05-08_

- **Stale DB deletion** (Android): unencrypted database from pre-v0.9 now detected and deleted on first launch, matching iOS behaviour
- **Promote to admin** (Android): swipe action in Group Detail to promote any non-admin member; admin-only, hidden for self and existing admins
- **Battery level in location payload** (Android): `LocationPayload` extended with `battery` field, consistent with iOS

### v1.2.0 — Low Battery Alerts ✅
_Notifies family members when someone's battery is critically low — released 2026-05-13_

- **Low battery alerts** (iOS & Android): `BatteryAlertService` monitors device battery; when level drops to a configurable threshold, a location message is published to the group with a battery-low flag; other members receive a local notification
- **In-app alert banner** (Android): `FamilyMapScreen` surfaces the battery-low event as a dismissible banner over the map
- **Notification icon** (Android): dedicated `ic_notification_battery` drawable for battery alert notifications

---

### v1.6.0 — Group avatar ✅
_Released 2026-06-29_

- **Group avatar** (iOS & Android): tap the group icon in Group Details to pick a photo from the library. Shown in the group list row, local/per-device only. Long-press hero circle to remove.

### v1.5.0 — Group onboarding ✅
_Released 2026-06-24_

- **Join requests** (iOS & Android): invitees gift-wrap a join-request (kind 1080) directly to the inviter carrying their MLS KeyPackage inline. Private by construction — rides inside a NIP-59 kind-1059 gift-wrap; nothing on a public relay leaks membership intent.
- **Pending-joiners list** (iOS & Android): admins see a "Ready to Join" list in Group Details showing who has sent a request and when.
- **"Add all" batch add** (iOS & Android): one button calls `addMembers([…])` for all pending KeyPackages — a single MLS epoch bump, one kind-445, N Welcomes. Laggards stay pending and retry on next launch.
- **Group Details redesign** (iOS): cleaner layout with pending joiners surfaced at the top.
- **`ChatViewModel` `@StateObject` fix** (iOS): was `@ObservedObject` in a parent that created it inline, causing SwiftUI to tear it down on every re-render.

### v1.4.1 — Bugfixes ✅
_Released 2026-06-12_

- **App update could wipe group membership** (iOS & Android): `MLSService` deleted and recreated the MLS database on *any* `newMdk` failure — intended for a pre-v0.9 unencrypted DB, but the catch-all also fired when a healthy *encrypted* DB failed to open transiently (e.g. Keychain/Keystore not yet readable on a background launch), silently destroying every group. The recreate path is now gated on a plaintext-SQLite header check; any other failure fails loudly without deleting so a later launch can recover.
- **iOS device never went stationary until pause toggled** (iOS): `CMMotionActivityManager` is edge-triggered, so opening the app while already still produced no callback and `isStationary` stuck at false. `startMonitoring()` now seeds the initial state from recent motion history via `queryActivityStarting`. Complements the v1.3.1 fix for the inverse case.
- **Map pins showed no staleness counter** (Android): OSM pins now carry a live relative-time counter matching iOS `MemberPinView` — others count up ("2 min ago"), own pin counts down ("in 30s").

### v1.4.0 — Manual Whistle ✅
_Released 2026-06-12_

- **Whistle button** (iOS & Android): circular broadcast-icon button that force-publishes location to every active group immediately, bypassing the update timer, motion-aware backoff, and stationary multiplier. One-shot override that fires even while paused (stays paused afterwards). Fresh fix with last-known fallback; icon swaps to spinner/checkmark/warning for feedback. Stamped `LocationPayload.interval` still reflects the normal cadence so receivers' staleness grading isn't skewed.

### v1.3.1 — Motion backoff bugfix ✅
_Released 2026-06-11_

- **Motion-adaptive backoff stuck at 4× while moving** (iOS): `MotionService` only re-evaluated the 30 s moving-debounce inside a `CMMotionActivityManager` callback, but that API is edge-triggered — during steady walking only the initial callback arrives, so `isStationary` never flipped back and the device kept publishing at the slowed (e.g. 1-hour) cadence. Debounce is now driven by a one-shot timer. Android was already timer-driven and unaffected.

### v1.3.0 — UX Polish ✅
_Smoothing over rough edges surfaced during 1.2.x on-device testing — released 2026-06-10_

- **Member detail sheet** (iOS & Android): tapping a member's map pin opens a bottom sheet with nickname, "last seen Xs ago" (anchored on local `receivedAt`), and the publisher's update cadence (e.g. "every 10 sec" / "every 1 hour"). Surfaces the `LocationPayload.interval` field added in 1.2.1 without crowding the map. Own pin also shows "Currently stationary" while Movement Aware is active.
- **Tappable group chat header** (iOS & Android): tapping the group title or the member-list strip in the chat view now opens the group detail (invite codes, member management). The small info icon to the right stays as a secondary affordance.
- **Debounce stationary→moving on Android**: `MotionService` now requires 30 s of confirmed non-stationary activity before flipping the multiplier back from 4× to 1×, mirroring the iOS `movingDebounceSeconds` (which already debounced this direction). A spurious `EXIT_STILL` — phone bumped on a desk, indoor motion noise — no longer immediately cancels the battery-saving backoff. iOS was already correct; no iOS change in this release.

---

### Deferred

- **Share stationary state in the location payload** _(parity feature)_: the Movement Aware "stationary" indicator (standing-man badge + "Currently stationary" in the detail sheet) is currently computed locally from the device's own motion sensor and is hard-gated to the own pin — it is **not** carried in `LocationPayload`, so a member viewing someone else never sees their stationary state. Receivers can already infer the slowdown from the `interval` field (which reflects the motion-adjusted 4× cadence), but not the explicit badge. To make it cross-device, add an **optional** `stationary` boolean to `LocationPayload` on both platforms (backward-compatible, exactly as `interval` was added in v1.2.1), serialize it for the own broadcast, and read it for non-self members. Deferred from v1.4.1 as it extends the wire protocol — a feature, not a bugfix.

- **Android feature parity with iOS sharing flows** _(parity backlog)_: several invite/onboarding features exist only on iOS. Worth aligning (to discuss/prioritise):
    - **Nearby Share** (`NearbyShareCoordinator`) — MultipeerConnectivity peer-to-peer invite exchange with no relay connectivity. Android equivalent would use Nearby Connections or custom BLE. _Parity matters._
    - **Onboarding** (`OnboardingView`) — three-card welcome carousel + permission framing before the system location prompt. Android goes straight to the main screen on first launch. _Parity matters._
    - **NFC tag read/write** (`NFCReadCoordinator` / `NFCWriteCoordinator`) — tap-to-join via NFC stickers. **Candidate to drop** rather than port — niche use, low demand.

- **Optional Google Maps on Android** _(backlog)_: Android currently renders maps via osmdroid (OpenStreetMap) only — a deliberate choice that keeps the app free of Google Play Services and lets it install/run on GrapheneOS and other degoogled devices. A future option could expose a "Map provider" setting (OSM / Google Maps) via Gradle product flavors so the GMS variant is a separate APK, leaving the default GMS-free. Not a fallback — both would be deliberate user choices.

- **Push Notifications via MIP-05** _(parked)_: MIP-05 specifies a privacy-preserving push pipeline. Devices encrypt their APNs/FCM tokens to a notification server's pubkey (probabilistic encryption with ephemeral keys, no cross-group linkability) and gossip the encrypted tokens to group members via kinds 447/448/449. To deliver a push, the sending client gift-wraps a `kind:446` rumor with the bundled tokens (plus decoys) and publishes it to the server's inbox relays; the server decrypts each token and dispatches a silent content-available push.

    **Why parked**: iOS ties APNs credentials to our bundle ID, so we have to run the notification server ourselves — there's no generic third-party operator. That means committing to small but real infra (VPS uptime, APNs `.p8`, Firebase project, monitoring, reproducible-build hygiene so users can trust the deployment). Not worth it for TestFlight-only scale; revisit when we commit to Play Store / App Store distribution.

    **Phased plan when we pick this up**:
    1. **MDK UniFFI bindings** — `crates/mdk-core/src/mip05/` exists in MDK 0.8.0 (encrypt/decrypt, rumor builders, batching), but `mdk-uniffi` doesn't expose it yet. Contribute upstream the way we did for keyring (PR #252). Reconcile the spec-vs-impl padding-size drift (spec: 280-byte encrypted token, impl: 1084).
    2. **Notification server** — minimal stateless Rust service: subscribe to inbox relays for `kind:1059` addressed to its pubkey, unwrap → decrypt token → dispatch APNs/FCM. Open source, deployable to fly.io / small VPS, reproducible builds.
    3. **Client token gossip** — local token store keyed by MLS leaf index; handlers for kinds 447/448/449; refresh on join / token change / 25-35 day periodic; auto-cleanup on MLS Remove.
    4. **Notification trigger** — on outbound chat / location / battery-alert send, collect active-leaf tokens + decoys (self ±50%, 10-20% from other groups, min 3), shuffle, gift-wrap as `kind:446` rumor + `kind:13` seal + `kind:1059` wrap, publish to server inbox relays.
    5. **Platform integration** — APNs registration via `UNUserNotificationCenter` on iOS; FCM via Firebase SDK on Android. Ship behind an opt-in setting initially.

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
  └── release/0.8.6                     ✅ merged
  └── feature/v0.9-mls-db-encryption   ✅ merged
  └── feature/v0.9.1-settings-split    ✅ merged
  └── feature/v0.9.2-splash-appearance ✅ merged
  └── security/v0.9.3-mip02-commit-ordering ✅ merged
  └── feature/v0.9.4-ux-fixes            ✅ merged
  └── feature/v1.0-production-readiness  ✅ merged
  └── feature/v1.0.1-ux-fixes           ✅ merged
  └── feature/v1.0.2-test-coverage      ✅ merged
  └── feature/v1.1.1-onboarding         ✅ merged
  └── feature/v1.1.2-settings-deep-links ✅ merged
  └── feature/v1.1.3-sqlcipher-activation ✅ merged
  └── feature/motion-adaptive             ✅ merged (v1.1.4)
  └── feature/v1.1.5-android-parity      ✅ merged
  └── feature/v1.2-low-battery-alerts    ✅ merged
  └── feature/v1.3-ux-polish             ✅ merged
  └── bugfix/v1.3.1                       ✅ merged
  └── chore/ci-mdk-cache-key              ✅ merged
  └── feature/v1.4-manual-whistle         ✅ merged
  └── bugfix/v1.4.1                       ✅ merged
  └── chore/ci-slsa-hygiene               ✅ merged
  └── feature/v1.5-join-requests-pr1      ✅ merged
  └── feature/v1.5-join-requests-pr2a     ✅ merged
  └── feature/v1.5-join-requests-pr3      ✅ merged
  └── feature/v1.5-join-requests-pr2b     ✅ merged
  └── feature/v1.5-group-details-ux       ✅ merged
  └── feature/v1.5-local-group-avatar     ✅ merged
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
