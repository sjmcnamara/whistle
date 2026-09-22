# Whistle Roadmap

An open-source, decentralized group location sharing app powered by Nostr.
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

### v1.3.0 — UX Polish ✅
_Smoothing over rough edges surfaced during 1.2.x on-device testing — released 2026-06-10_

- **Member detail sheet** (iOS & Android): tapping a member's map pin opens a bottom sheet with nickname, "last seen Xs ago" (anchored on local `receivedAt`), and the publisher's update cadence (e.g. "every 10 sec" / "every 1 hour"). Surfaces the `LocationPayload.interval` field added in 1.2.1 without crowding the map. Own pin also shows "Currently stationary" while Movement Aware is active.
- **Tappable group chat header** (iOS & Android): tapping the group title or the member-list strip in the chat view now opens the group detail (invite codes, member management). The small info icon to the right stays as a secondary affordance.
- **Debounce stationary→moving on Android**: `MotionService` now requires 30 s of confirmed non-stationary activity before flipping the multiplier back from 4× to 1×, mirroring the iOS `movingDebounceSeconds` (which already debounced this direction). A spurious `EXIT_STILL` — phone bumped on a desk, indoor motion noise — no longer immediately cancels the battery-saving backoff. iOS was already correct; no iOS change in this release.

### v1.3.1 — Motion backoff bugfix ✅
_Released 2026-06-11_

- **Motion-adaptive backoff stuck at 4× while moving** (iOS): `MotionService` only re-evaluated the 30 s moving-debounce inside a `CMMotionActivityManager` callback, but that API is edge-triggered — during steady walking only the initial callback arrives, so `isStationary` never flipped back and the device kept publishing at the slowed (e.g. 1-hour) cadence. Debounce is now driven by a one-shot timer. Android was already timer-driven and unaffected.

### v1.4.0 — Manual Whistle ✅
_Released 2026-06-12_

- **Whistle button** (iOS & Android): circular broadcast-icon button that force-publishes location to every active group immediately, bypassing the update timer, motion-aware backoff, and stationary multiplier. One-shot override that fires even while paused (stays paused afterwards). Fresh fix with last-known fallback; icon swaps to spinner/checkmark/warning for feedback. Stamped `LocationPayload.interval` still reflects the normal cadence so receivers' staleness grading isn't skewed.

### v1.4.1 — Bugfixes ✅
_Released 2026-06-12_

- **App update could wipe group membership** (iOS & Android): `MLSService` deleted and recreated the MLS database on *any* `newMdk` failure — intended for a pre-v0.9 unencrypted DB, but the catch-all also fired when a healthy *encrypted* DB failed to open transiently (e.g. Keychain/Keystore not yet readable on a background launch), silently destroying every group. The recreate path is now gated on a plaintext-SQLite header check; any other failure fails loudly without deleting so a later launch can recover.
- **iOS device never went stationary until pause toggled** (iOS): `CMMotionActivityManager` is edge-triggered, so opening the app while already still produced no callback and `isStationary` stuck at false. `startMonitoring()` now seeds the initial state from recent motion history via `queryActivityStarting`. Complements the v1.3.1 fix for the inverse case.
- **Map pins showed no staleness counter** (Android): OSM pins now carry a live relative-time counter matching iOS `MemberPinView` — others count up ("2 min ago"), own pin counts down ("in 30s").

### v1.5.0 — Group onboarding ✅
_Released 2026-06-24_

- **Join requests** (iOS & Android): invitees gift-wrap a join-request (kind 1080) directly to the inviter carrying their MLS KeyPackage inline. Private by construction — rides inside a NIP-59 kind-1059 gift-wrap; nothing on a public relay leaks membership intent.
- **Pending-joiners list** (iOS & Android): admins see a "Ready to Join" list in Group Details showing who has sent a request and when.
- **"Add all" batch add** (iOS & Android): one button calls `addMembers([…])` for all pending KeyPackages — a single MLS epoch bump, one kind-445, N Welcomes. Laggards stay pending and retry on next launch.
- **Group Details redesign** (iOS): cleaner layout with pending joiners surfaced at the top.
- **`ChatViewModel` `@StateObject` fix** (iOS): was `@ObservedObject` in a parent that created it inline, causing SwiftUI to tear it down on every re-render.

### v1.6.0 — Group avatar ✅
_Released 2026-06-29_

- **Group avatar** (iOS & Android): tap the group icon in Group Details to pick a photo from the library. Shown in the group list row, local/per-device only. Long-press hero circle to remove.

### v1.7.0 — Presence & identity ✅
_First slice of the v1.7 presence work — released 2026-07-19_

- **Stationary state shared cross-device** (iOS & Android): the Movement Aware stationary indicator (pin badge + "Currently stationary" in the member detail sheet) was computed from the local motion sensor and hard-gated to the own pin, so you could never see another member as stationary. `LocationPayload` now carries an optional `stationary` boolean. Deliberately tri-state — an omitted field means *unknown*, never `false`, so a pre-1.7 client (or one with Movement Aware off) shows no badge rather than being wrongly rendered as moving. Backward-compatible exactly as `interval` was in v1.2.1. Closes the item deferred from v1.4.1.
- **Share Nearby / Join Nearby removed** (iOS): the MultipeerConnectivity peer-to-peer invite exchange is gone — QR scanning covers the same in-person handoff, and it was iOS-only with no Android equivalent. It was also the only join path that skipped explicit member approval. The local-network permission prompt no longer appears on first run.
- **`build.sh` no longer discards uncommitted `project.yml` edits**: `restore_local_changes()` ran `git checkout -- project.yml`, silently reverting version bumps made before a build.

_Still to come in v1.7: member avatars over MLS, avatar map pins, shared encrypted group avatar._

### v1.7.1 — Member avatars ✅
_Released 2026-07-19_

- **Member avatars** (iOS & Android): a photo set in Settings is shared with every group and shown on your map pin. Carried **inline** as base64 JPEG inside the MLS application message rather than as a blob reference — a family group is small and the image is tiny, so this stays fully end-to-end encrypted with no blob server, consistent with the project's no-servers position. Capped at 16 KB with quality stepped down to fit; an image that cannot fit is refused at pick time rather than published for a relay to silently drop. Empty payload = explicit removal. Wiped on identity burn.
- **Initials fallback**: members with no photo get a coloured circle, the colour derived from their pubkey via FNV-1a so it is stable across launches and identical on both platforms.
- **iOS SwiftUI render fixes** surfaced by on-device testing: photo picker reloading on a loop, display-name field re-rendering Settings per keystroke, avatar encoding blocking the main thread. All trace back to `AppViewModel.forwardChildChanges()` re-rendering every observer on any relay event.

### v1.7.2 — Avatar UX & group rename fix ✅
_Released 2026-07-20_

- **Group rename reachable again** (iOS): the hero `PhotosPicker` in Group Details had no explicit frame, so inside a list row its hit region expanded past the circle and swallowed taps meant for the group name and rename pencil. Now a plain button with `.contentShape(Circle())`.
- **Avatar tap opens a menu** (iOS & Android): Choose/Change Photo, Remove Photo when set, Cancel — replacing a jump straight into the library plus a cramped inline remove link (Settings) and a hidden long-press context menu (group details). Each menu states who sees the photo, since the group photo is device-local and the member photo is shared.

### v1.7.3 — Shared group photo ✅
_Released 2026-07-20_

- **Shared group photo** (iOS & Android): admin-set, seen by every member. Carried inline as base64 JPEG inside the MLS application message, reusing the member-avatar encoder and 16 KB ceiling — no blob storage, consistent with the no-servers position.
- **Admin-only enforced on receive**: MLS guarantees the sender is a member, not an admin, so each client checks the sender against the group's `adminPubkeys` before applying and drops anything else. The UI gate alone would only bind honest clients.
- **Personal override wins**: the per-device group photo from v1.6.0 sits above the shared one, resolved in a single place (`SharedGroupAvatarStore.resolvedImage`) so the group list and detail screen cannot disagree.
- **Designated re-announce on join**: the admin with the lexicographically smallest pubkey re-broadcasts on membership change. Sorted key rather than list position, because list order is not guaranteed identical across clients — an index rule could duplicate the send or drop it entirely.

### v1.8.0 — Share Diagnostics ✅
_Released 2026-07-20_

- **Share Diagnostics** (iOS & Android): Advanced Settings → Share Diagnostics exports a deterministic, redacted JSON snapshot of app/build/OS, pinned MDK revision, and per-group epoch/member/admin/health state — built to be diffed so two members' reports reveal a fork as a single differing `epoch` line. Safe to share in public (no messages, locations, or names; identifiers truncated), enforced by a build-guard test.
- **(Android) Diagnostics screen back button**: the screen now has a `TopAppBar` with a back arrow, matching the other settings screens (it previously relied solely on the system Back gesture).
- **(iOS & Android) Burn Identity warning corrected**: the confirmation no longer claims burning "leaves all groups" — it deletes local state only and strands a leaf other members keep encrypting to. The zombie-member cleanup (sole-admin handling, leave-before-burn) is roadmapped under Deferred.

### v1.8.1 — Avatar oversampling fix ✅
_Released 2026-07-23_

- **(iOS) Avatars encoded at up to 9× the intended pixel count**: the avatar downscaler built its `UIGraphicsImageRenderer` at the target *point* size without pinning `format.scale`, so on a Retina device it rendered at the screen scale — a 128 pt target became a 384 px JPEG on a @3x phone. Still fit under the 16 KB wire cap, so nothing failed visibly, but every member and shared-group avatar travelled larger than designed. Renderer now pins `scale = 1`. Present since member avatars shipped in v1.7.1. Android was unaffected (scales in pixels via `Bitmap.createScaledBitmap`).
- **(Android) Version bump for lockstep**: `versionName`/`versionCode` bumped to 1.8.1/43 alongside the iOS fix — no Android behavior change in this release.
- **Test coverage backfill**: added unit tests for recently-shipped services (`AppSettings`, `ChatMessageCache`, `DiagnosticsCollector`, `LocationViewModel`, avatar stores, `BatteryAlertService`) and closed several iOS↔Android test parity gaps.

### v1.8.2 — Map pin crash + group photo picker reload ✅
_Released 2026-07-30_

- **(iOS) Crash while panning/zooming the map**: map pins rendered `MemberAvatarView`, which reaches for `MemberAvatarStore` via `@EnvironmentObject`. MapKit hosts `Annotation` content in its own `_UIHostingView` with none of the root environment, built from `MKAnnotationManager.updateVisibleAnnotations` (a timer callback outside SwiftUI's update pass) — so the lookup trapped and killed the app with `EXC_BREAKPOINT` in `EnvironmentObject.error()`. `MemberPinView` now takes a resolved `UIImage?` from `MapView` and reads nothing from the environment. Latent since v1.7.1, reported from the field on 1.8.1 / iOS 26.6. Android was structurally immune (`MapScreen` already passes a resolved bitmap per pin). Supersedes the unreleased #187, which fixed the same crash by re-injecting the store per pin — this removes the environment dependency instead of re-supplying it.
- **(iOS) 3D map terrain restored**: #187's speculative `.realistic` → `.flat` elevation change is reverted. It was made before the root cause was confirmed and is unrelated to it; `.flat` only ever existed on unreleased master.
- **(iOS) Photo library reloaded repeatedly while setting a group photo**: `GroupDetailView` observes `AppViewModel`, whose `forwardChildChanges()` republishes on every settings/location/relay change, and the `.photosPicker` modifier sat inline in the hero header — so background relay traffic tore down and re-presented the picker every couple of seconds, resetting scroll position before a photo could be picked. Extracted `GroupAvatarPickerButton` as an `Equatable` view taking plain values and closures, applied with `.equatable()`. Same fix `AvatarPickerRow` got in v1.7.2, never applied to the group photo path. Android unaffected (picker is a separate activity).
- **Regression guards for both**: `AvatarPickerEquatableTests` asserts both picker views compare equal across distinct closure instances and still register each value input — the missing guard that let the picker bug regress silently. `MemberPinViewHostingTests` hosts the map pin with an empty environment and forces layout, reproducing MapKit's exact sequence, so a reintroduced environment read fails in CI instead of on a phone.
- **(Android) Version bump for lockstep**: `versionName`/`versionCode` bumped to 1.8.2/44 — no Android behavior change in this release.

### v1.8.3 — Relay connection status accuracy ✅
_Released 2026-07-31_

- **(iOS & Android) Unreachable relays reported as connected**: `RelayService.connect` built `connectedRelayURLs` from the relays it had successfully *added* to the client. Adding only registers a URL — `Client.connect()` returns as soon as the background connection tasks are spawned — so the list was written before any socket opened and never corrected. A dead host, a typo, or an address the device cannot resolve at all (a `.onion` relay with no Tor proxy) showed a green dot in Advanced Settings indefinitely, and `MarmotService` counted it toward the relay set gating member adds and resyncs. Status now comes from `Client.relays()` filtered on `Relay.isConnected()`; `connect` waits up to 5s for sockets before reporting, and Advanced Settings re-reads status every 5s so the dots track background drops and reconnects.
- **`Client.connect()` kept over `tryConnect()`**: `tryConnect` reports failures synchronously but explicitly schedules no retries, which would strand a phone that briefly loses signal. The wait-then-read-status approach gets accurate reporting without giving up automatic reconnection.
- **Relay-gated operations re-check before failing**: an accurate list can legitimately be empty for a moment while relays reconnect, so the three `MarmotService` sites that gate on it (add member, resync member, batch add) go through a new `hasConnectedRelays()` that re-reads live status before throwing. Without this, making the status honest would have converted a false "connected" into a false "not connected".
- **URL normalisation**: `RelayUrl.parse` normalises (it can append a trailing slash), so registered relays are tracked as a `RelayUrl` → settings-string map. Callers compare against their own settings strings, and would otherwise never match.
- **Regression guards**: `RelayServiceStatusTests` covers the no-client, no-registered-relay, unparseable-URL, and disconnect paths, plus the consumer contract that the published list means *connected*, not *registered*. Tests deliberately avoid the network.
- Found while assessing whether Whistle could talk to `.onion` relays — it cannot today (neither binding ships a Tor `ConnectionMode`), but the silent-failure mode that investigation exposed was not onion-specific.

### v1.8.5 — Group avatar sync on join + resync duplicate-invite fix ✅
_Released 2026-08-04_

- **(iOS & Android) New members didn't see the group avatar until manually resynced**: the group avatar travels as a plain MLS application message, not group state, so MLS forward secrecy makes it structurally undecryptable by anyone who joined after it was sent — the designated admin is meant to re-announce it on every membership change (`rebroadcastGroupAvatarIfDesignated`), but that only fired when the admin's own client happened to re-observe its just-published add-commit come back over the live relay subscription. `addMember`, `addMembers`, and `resyncMember` now trigger the re-announce directly instead of depending on that asynchronous self-echo.
- **(iOS & Android) Hard resync showed a stale "Inactive" row plus a duplicate "Accept" invitation for the same group**: `resyncMember`'s remove-then-re-add issues a fresh Welcome outside the invite-code path, so it was misclassified as unsolicited and required approval even though the Welcome's cryptographic validity already proves a real admin sent it. Such a Welcome for a group we have any local record of (active or not) is now auto-accepted as a resume. The group list also now reacts immediately when a pending welcome is added or resolved, instead of waiting for an unrelated MDK group-state event to re-run the filter that hides pending-welcome groups from the main list.
- Found while investigating a real cross-platform join: an Android admin created a group, set an avatar, and invited an iOS member who saw the group but not the avatar until the admin resynced them — which incidentally fixed the avatar but surfaced the duplicate-entry bug on the confirm-rejoin step.

### v1.8.7 — iOS bundle ID rename + NFC removal ✅
_Released 2026-08-18_

- **(iOS) `PRODUCT_BUNDLE_IDENTIFIER` moved from `org.findmyfam.app` to `org.getwhistle.whistle`**: mirrors the Android `applicationId` rename in v1.8.4, and for the same reason — `org.findmyfam` predates the app's rename to Whistle, and this is the last point it can move before a real App Store listing makes it permanent. Requires a new App ID and a new App Store Connect app record; existing TestFlight testers on `org.findmyfam.app` are not migrated forward and lose local identity/groups on the old install, same trade-off Android made. Internal-only identifiers (`KeychainService`'s keychain service string, `MLSService`'s MDK `serviceId`, the logger subsystem) deliberately stay `org.findmyfam` — private storage labels, not worth the risk of touching for no external benefit, matching Android leaving its Kotlin package name and `FindMyFamApp` class alone.
- **(iOS) Removed unused NFC tag read/write**: `NFCReadCoordinator`/`NFCWriteCoordinator` had no remaining call sites in `Sources/Views` — deleted both files, the NFC entitlement, the `NFCReaderUsageDescription` usage string, and two stray UI mentions. Closes the Deferred item below.

### v1.8.6 — Duplicate self-pin on the multi-group map ✅
_Released 2026-08-05_

- **(iOS) A member of two or more groups saw their own location pinned twice on the "All Groups" map, at slightly different coordinates**: `LocationCache` keys entries by `"groupId:pubkeyHex"`, so belonging to two groups produces two separate cache entries for yourself, and `LocationViewModel.refresh()` built one annotation per entry with no dedup step. The two entries normally track each other, since `broadcastLocation()` writes an identical fresh payload into every active group on each fix — but `LocationCache.update()` had no ordering guard, so an out-of-order relay echo of your own event in one group could leave that group's entry pointing at a stale coordinate, which is what produced the visible drift between the two pins. `refresh()` now collapses to the single freshest self entry when showing all groups (a specific-group filter still shows exactly that group's entry), and `update()` ignores an incoming payload older than what is already cached for that key.
- **Android parity gap**: `android/app/src/main/java/org/findmyfam/services/LocationCache.kt` has the same key scheme and the same missing ordering guard, so the underlying divergence can occur there too — not fixed here since it wasn't the reported symptom, but worth folding into a parity pass.

### v1.8.8 — Groups tab rename + invite/QR polish ✅
_Released 2026-08-19_

- **(iOS) Bottom tab and Group list renamed from "Chat" to "Groups"**: the tab's row design (`GroupRowView`) already reads as a group roster (name, member count, last-activity time) with no message preview, not a chat inbox, even though tapping a row does open straight into that group's chat thread. Tab icon changed from `bubble.left.and.bubble.right.fill` to `person.3.fill` to match. Android was already labeled "Groups" throughout — `RootScreen.kt` / `GroupListScreen.kt` never said "Chat" — so no rename needed there.
- **(iOS & Android) Removed the redundant "Group" nav title on Group Detail**: iOS hides the bar entirely (`.toolbar(.hidden, for: .navigationBar)`) with a floating back button over the hero section, since an empty title still reserves the nav bar's full height there. Android's `TopAppBar` doesn't reserve extra height for a title either way, so blanking it (`title = {}`) is the complete fix on that platform.
- **(iOS & Android) Invite QR restyled on both platforms**: brand-dark-grey dot-style modules with rounded finder-pattern corners and a center logo badge. iOS via the new `dagronf/QRCode` package (`exactVersion: "9.2.1"`); Android via the new `qrose` package (`1.1.2`, same author's Compose-native sibling — plain `Painter` via `rememberQrCodePainter`, no `Drawable`/`Bitmap` interop), replacing `ZXing` (no styling hooks, used nowhere else in the app). Both tuned to medium error correction to balance badge safety against module density for the ~250-char invite payload.
- **(iOS) Invite sheet also got icon-only share/copy buttons** (dropped the "Share via AirDrop / Messages…" label, which named specific share-sheet apps a user can hide or reorder) plus a group name/avatar header and a card-wrapped QR. Android's sheet already said "the person you want to add to the group" and its buttons were already plainly labelled, so no change needed there.
- **(iOS & Android) Admin's approve/deny on a pending joiner now uses filled circular check/cancel icons on both platforms**: `checkmark.circle.fill` / `xmark.circle.fill` on iOS, matching `GroupListView`'s existing pending-welcome pattern (was `person.badge.plus` / `xmark.circle`); `CheckCircle` (green) / `Cancel` (error red) on Android, reusing the green/red convention already established in `AdvancedSettingsScreen.kt` (was `PersonAdd` / `Close`).

### v1.8.9 — App Store rejection fix (Guideline 5.1.1(iv)) ✅
_Released 2026-08-28_

- **(iOS) Onboarding's pre-permission screen let users bypass the system location prompt entirely**: Apple rejected the app over the "One last thing" screen's "Enable Location" button (a directive verb; wants neutral "Continue"/"Next") and its "Skip for now" button, which dismissed onboarding without ever calling `requestAlwaysAuthorization()` — the system dialog only appeared later if the user found the "Authorization" row in Settings. Renamed the button to "Continue" and removed "Skip for now"; the final onboarding page always triggers the system prompt now.
- **(iOS) Permission usage-description strings say "group" instead of "family"**, matching the v1.8.8 "Groups" tab rename.

### v1.8.10 — Invite QR crash fix ✅
_Released 2026-09-01_

- **(Android) Fixed a 100%-reproducible crash on tapping "invite via QR / code"**: `InviteShareSheet` badged the QR center with `painterResource(R.mipmap.ic_launcher)`, but on this app's minSdk 26+ that resource always resolves to the `<adaptive-icon>` XML in `mipmap-anydpi-v26`, which Compose's `painterResource` rejects outright. Caught on a GrapheneOS Pixel via `adb logcat`. Added a dedicated flat badge asset (`drawable/invite_qr_mark.png`), reusing the same mark iOS already has (`InviteQRMark`) for its own QR badge, instead of reaching for the launcher icon.

### v1.8.11 — Deep-link symmetry fixes ✅
_Released 2026-09-01_

- **(Android) `whistle://invite/` deep links only worked one-way** — the manifest registered the intent-filter, but `MainActivity` never read `intent.data`, so tapping a link foregrounded the app and dropped the invite silently. Added `onNewIntent` + `launchMode="singleTask"` + `AppViewModel.handleIncomingUri()`, mirroring iOS's `handleIncomingURL(_:)`. Verified live via `adb shell am start -a android.intent.action.VIEW -d "whistle://invite/…"` against a running install.
- **(Android) Invite sheet's Share button sent the raw code instead of the deep link**, unlike iOS's Share. Now sends `whistle://invite/<code>` like iOS does; Copy is unchanged (still the raw code the manual-entry field expects).
- **(iOS) Pasting a full `whistle://invite/<code>` link into the manual invite-code field failed to join** — `joinGroup` used the strict `InviteCode.decode(from:)`. Added `InviteCode.fromUri(_:)` (matching Android's existing helper of the same name) and re-encode-before-`acceptInvite`, matching Android's pattern exactly.

### v1.8.12 — Android background subscription recovery ✅
_Released 2026-09-01_

- **(Android) Admins never saw pending join requests after backgrounding the app.** Reproduced live across two devices (Pixel + Samsung): create a group, switch away (screen lock, or jumping to Settings to grant a permission), switch back — the admin's relay subscriptions never resumed, so a join request sent while backgrounded (or any time after) vanished silently. Two root causes: an Android `Activity` can be destroyed and recreated while merely backgrounded, clearing its `ViewModelStore` and firing `AppViewModel.onCleared()` → `MarmotService.stopSubscriptions()` with nothing to restart them; and `onAppear()`'s "no identity yet" bailout permanently latched its one-shot startup guard instead of resetting it for a retry, unlike iOS's equivalent. `MainActivity.onResume()` now calls `MarmotService.ensureSubscriptionsActive()` to restart if inactive, and the startup guard resets to match iOS.

### v1.8.13 — PreviouslyFailed health-tracker blind spot ✅
_Released 2026-09-03_

- **(iOS & Android) A group permanently stuck behind the leader's MLS epoch could report `healthy: true` forever.** Surfaced during a 3-Android-device sync test (diagnosed via a 4-agent deep dive — see PR): out-of-order kind-445 commit delivery causes MDK to permanently blacklist a commit as `PreviouslyFailed`, and that result touched neither `recordFailure` nor `recordSuccess` in `GroupHealthTracker`, so a permanently-desynced group looked perfectly healthy in diagnostics. `GroupHealthTracker` now records failures by type independent of the per-group counters, feeding the previously-`Reserved`-but-always-empty `DiagnosticsReport.recentFailures` field. This is diagnostic visibility only — a device this happens to still needs the admin's hard-resync (remove+re-add) path to actually recover, since MDK never retries the blacklisted commit.
- Same session surfaced several other Android-specific gaps, tracked as follow-up work rather than bundled into this release — see v1.8.14 and the Deferred section below.

### v1.8.14 — Android foreground catch-up sweep ✅
_Released 2026-09-03_

- **(Android) A gift-wrap, group commit, or key-rotation missed while merely backgrounded stayed invisible until the app was force-quit and relaunched — resuming was not enough.** `AppViewModel.onForeground()` only called `MarmotService.ensureSubscriptionsActive()`, which restarts the subscription coroutine if cancelled but does nothing if it's still `isActive`. Nothing else in the resume path re-fetched anything: gift-wraps carry no `since` filter (NIP-59 randomises their timestamp) so only `fetchMissedGiftWraps()`'s dedicated one-shot fetch reliably catches a missed "ready to join" Welcome, `catchUpGroup()` never ran on resume at all, and `rotateStaleGroups()` was in the same boat — all three previously only ran once, at cold-start `onAppear()`. `onForeground()` now re-runs the same three-call sweep on every resume, not just full relaunch.

### v1.8.15 — Nav-scoped AppViewModel leak + stale relay-connection cache ✅
_Released 2026-09-03_

- **(Android) Ordinary in-app navigation could silently kill relay subscriptions and location updates app-wide, with no recovery until a real background/foreground cycle.** `GroupListScreen`/`GroupDetailScreen` each independently called `hiltViewModel()` for their own `AppViewModel` instead of using the one `RootScreen` already passes down — since both render inside `NavHost` routes, that resolved to a separate `NavBackStackEntry`-scoped instance. Its `onCleared()` still calls `marmotService.stopSubscriptions()`/`locationService.stopUpdating()`, and since those are Hilt `@Singleton`s shared app-wide, popping *that* backstack entry (navigating back out of Group Detail, or tapping the Groups tab while already on it) killed subscriptions globally — invisible to `MainActivity.onResume()`'s recovery path since nothing backgrounded. Fixed by passing the Activity-scoped instance down explicitly. Found live testing v1.8.14 on a nav-scoping-affected build; without this fix, subscriptions could die from screen-to-screen taps at any moment, independent of backgrounding.
- **(iOS & Android) `catchUpGroup()`/`fetchMissedGiftWraps()` could silently no-op after a real lock/Doze cycle killed the relay socket** — exactly when v1.8.14's catch-up sweep needed to work. `reconnectRelaysIfNeeded()` trusted a `connectionState` snapshot from whenever it was last refreshed instead of checking live, so a socket that died silently in the background (with no observer ever updating that snapshot) looked "still connected," skipping reconnection; the subsequent one-shot fetch against the dead socket then failed fast with an empty result instead of an error. Now calls `refreshConnectedRelays()` for a live read first, on both platforms. Verified live: pre-fix, a locked device's catch-up fetch returned in 18ms with 0 events; post-fix, it correctly detected 0/3 relays connected, reconnected, and recovered a genuinely-missed 501-event backlog.

### v1.8.16 — Android foreground service + boot receiver ✅
_Released 2026-09-11_

- **(Android) No foreground `Service` existed at all, so the whole app process — not just the Activity — could be killed by the OS within minutes of backgrounding, and nothing ran after a reboot until the app was manually reopened.** Reported live by a GrapheneOS user: "the app halts within minutes of closing and does not run on startup... you can never see anyone's position unless they have the app open." `FOREGROUND_SERVICE`/`FOREGROUND_SERVICE_LOCATION` were declared in the manifest but dead — `RelayService`/`MarmotService`/`LocationService` were ordinary Hilt singletons with no lifetime independent of the process. New `WhistleForegroundService` calls `startForeground()` and owns no business logic itself (the existing singletons keep working once the process survives); started/stopped by `AppViewModel` to track whether there's an active group to share with, and restarted after reboot by a new `BootCompletedReceiver`. A new `BackgroundSessionCoordinator` runs the relay-connect/MLS-init/subscribe sequence headlessly — nothing outside `AppViewModel.onAppear()` previously did that at all, which would have left a foreground-priority process running with nothing wired up on a cold headless start. Deliberately kept as a second, independent bootstrap path rather than merged into `onAppear()`'s splash-screen state machine — every step both paths call is idempotent by construction, so it's safe for both to run in the same process. The Service is declared/started as `dataSync`, not `location`, despite what it's for: verified live on an emulator reboot that Android throws `SecurityException` the instant a location/camera/microphone-typed FGS calls `startForeground()` from a `BroadcastReceiver`, even inside `BOOT_COMPLETED`'s own background-start allowlist — a real restriction no amount of code review would have caught, only found by actually rebooting a test device with the first version of this fix installed. `dataSync` describes the job (syncing relay/MLS/location state) accurately without hitting it; the same reboot test after switching confirmed boot receipt, foreground start, and a real headless relay connection (`relay=CONNECTED`) all succeed, and the Service correctly self-stops for an account with zero groups instead of leaving a misleading persistent notification.
- **(Android) `ensureSubscriptionsActive()` could false-positive on a dead relay connection.** Checked only whether the subscription coroutine was still `isActive`, not whether the relay it depended on was actually connected — Doze/network loss can kill the socket without the coroutine ever throwing. Now also checks `RelayService.hasConnectedRelays()`.
- **(Android) `ACCESS_BACKGROUND_LOCATION` was declared but never requested at runtime.** `MapScreen` only asked for fine/coarse; now requests background location as a separate follow-up once foreground location is granted (Android disallows batching the two together from API 30+).

### v1.9.0 — Per-group location controls & diagnostics ✅
_Released 2026-09-13_

- **(iOS & Android) Per-group location-sharing pause.** The only pause control was the global "Pause Sharing" switch, which stopped location updates entirely — all-or-nothing across every group. Group Detail now has its own "Pause Sharing to This Group" toggle (`pausedGroupIds`), which skips just that group in the location-broadcast loop — you keep receiving and viewing everyone else's location there as normal. The global switch still overrides every group at once when it's on. A paused group shows a "Paused" badge in the group list.
- **(iOS & Android) Diagnostics' last-event timestamp is now per-group.** `secondsSinceLastGroupEvent` was a single device-wide value in the diagnostics report — with multiple groups it could only reflect whichever one updated most recently, hiding a different group silently stalling out. Moved into each group's own snapshot as `secondsSinceLastEvent`, computed from that group's own MDK `lastMessageAt`. Diagnostics schema version bumped to 2.
- **(iOS & Android) Nickname-less members now show an abbreviated npub instead of a raw hex prefix.** The nickname fallback showed 8 raw hex characters, useless to compare against anything. It now bech32-encodes and abbreviates the same way the Identity card does (`npub1abc...xyz`, via `NostrIdentity.shortNpub`). Matters most for the places a nickname-less pubkey reaches the UI before someone has joined — the pending-join-request row on both platforms, and (iOS) the admin's join-approval banner / (Android) the pending-welcome sender row — since it's now the same string the joiner can read off their own Identity card, giving an actual out-of-band identity check instead of unmatchable hex.

    _Deliberately out of scope for this release_: a per-relay "last synced" diagnostic (nothing currently tracks per-relay last-success, only aggregate `connected: Bool`) — real instrumentation work in `RelayService`/`MarmotService`'s subscription handling, scoped separately; and the diagnostics group-id truncation (`DiagnosticsReport.shortHex`, 8 hex chars) is unchanged — MLS group ids have no bech32/npub-equivalent human-readable encoding, unlike pubkeys, so there's nothing better to show there without weakening the deliberate anonymization the diagnostics report relies on for safe public pasting.

### v1.9.1 — iOS background-relaunch visibility ✅
_Released 2026-09-14_

- **(iOS) No provable story for surviving a background kill or device reboot.** Found while checking whether iOS had an equivalent to v1.8.16's Android foreground-service/boot-receiver work — it didn't, and unlike that release, this had never been verified or even instrumented. `Info.plist` declared `UIBackgroundModes: [location, fetch]`, but `fetch` was dead — background fetch needs an `AppDelegate` to receive `application(_:performFetchWithCompletionHandler:)`, and this app had none at all (pure SwiftUI App lifecycle, no `AppDelegate`/`SceneDelegate` anywhere). The `location` mode does actually work — `LocationService` sets `allowsBackgroundLocationUpdates` and runs `startMonitoringSignificantLocationChanges()`, which is what lets iOS relaunch a terminated app (including after a reboot) when a new location event fires — but nothing ever checked *why* a launch happened, so recovery relied entirely on CoreLocation's documented behavior plus the emergent fact that SwiftUI always instantiates the view tree (and therefore runs `AppViewModel.performFullStartup()` via the root view's `.task`) on any process launch, headless or not. Added a minimal `AppDelegate` (`@UIApplicationDelegateAdaptor`) that checks `launchOptions[.location]` and logs it explicitly, so a location/reboot-triggered relaunch is provable rather than assumed. Removed the dead `fetch` background mode. The startup sequence itself is unchanged — this adds visibility, not a new code path.

    **Known limitation**: unlike Android's fix (verified live on an emulator reboot cycle), this can't be verified the same way — iOS Simulator doesn't reliably reproduce real-device reboot/background-relaunch semantics for CoreLocation, so there's no equivalent "confirmed live" story here. Recommend a real-device test (reboot a phone with Whistle installed and location permission granted, confirm the `.location` launchOptions log line appears and location sharing resumes) before treating this as fully closed. A `BGTaskScheduler`/`BGAppRefreshTask` fallback was considered and deliberately deferred — mirrors Android's own `WorkManager` deferral in v1.8.16 ("lower priority now that a foreground Service exists"); the primary CoreLocation relaunch mechanism should cover the common case, and a periodic background task is opportunistic/OS-throttled insurance at best, not a stronger guarantee.

### v1.10.0 — Real self-remove for "Leave Group" ✅
_Released 2026-09-17_

- **(iOS & Android) "Leave Group" was cosmetic — it sent a chat message asking the admin to remove you, and the group stayed fully active (still broadcasting your location, still counted in diagnostics) for as long as the admin's device took to act.** Found while investigating a bug report: a duplicate/ghost self-pin on the map after leaving two groups, plus diagnostics still showing 4 groups when the group list showed 2. Root cause: leaving was never a protocol operation, just a social convention nothing enforced. MDK already exposes a real self-remove commit (`leaveGroup()`) on both platforms — unused. Wired it in directly: a plain member leaves instantly, no admin involved; an admin with a co-admin self-demotes first (MIP-03 requires it) then leaves, transparently; the sole admin of a multi-member group gets a clear error rather than the raw MDK message, since there's no one to hand admin duties to; a solo group is just deleted locally, since there's no one to notify. Also discovered along the way: a self-remove commit is never merged locally like other mutations — `deleteGroup()`, not `mergePendingCommit`, is what actually finalizes it, confirmed against real MDK via 8 new protocol-level tests. Removed the obsolete `PendingLeaveStore`/leave-request-approval UI on both platforms.

    **Known limitation, deliberately out of scope**: the sole-admin-of-a-multi-member-group case surfaces a clear error but no in-app flow to promote someone else and retry — that's the same open design question as the sole-admin case in the Burn Identity item below (MIP-03's "last admin must designate a successor" rule), and deserves the same deliberate treatment rather than an improvised UI here.

### v1.10.1 — Diagnostics ID on Group Detail ✅
_Released 2026-09-17_

- **(iOS & Android) Diagnostics exports were impossible to interpret with more than one group.** The diagnostics report deliberately shows only an 8-char group-id prefix per group and no name, to keep a report meant for pasting elsewhere from leaking group names. But nothing on the Group Detail screen showed that same id, so there was no way to match a diagnostics entry back to an actual group. Added a small tap-to-copy "Group ID" row under the member count showing the identical prefix (`DiagnosticsReport.shortHex`) diagnostics already uses.

### v1.10.2 — Reveal a member's npub on Group Detail ✅
_Released 2026-09-17_

- **(iOS & Android) No way to verify a *named* member's identity out-of-band.** Found while investigating a report of a stale, non-"(you)" admin in a long-lived group. A nickname-less member already shows an abbreviated npub as a stand-in name; once a nickname is cached there was no way to see the pubkey behind it. Added a tap-to-reveal sheet/dialog on any member row showing the full npub with a copy button.

### v1.10.3 — Fix stale admin cache blocking leave ✅
_Released 2026-09-17_

- **(iOS & Android) `leaveGroup`'s admin check read a cached admin list that can diverge from live MLS truth**, wrongly concluding a live admin wasn't one and throwing MDK's raw "must self-demote first" error instead of handling it. `leaveGroup` no longer decides admin status from any cached read — it unconditionally attempts `selfDemote` first and interprets MDK's own authoritative response.

    **Known limitation**: Group Detail's own admin-status *display* still reads the same cache and can remain visibly wrong for an affected group — only the ability to actually leave is fixed here.

### v1.10.4 — Root cause: silent identity swap from a bundle-id rename ✅
_Released 2026-09-18_

- **(iOS) Root cause found for the v1.10.2/1.10.3 stale-admin symptom.** Ruled out a true MLS fork via forward secrecy (the affected device decrypted a message encrypted moments earlier by another member, which a forked/behind device cannot do). Real cause: an earlier bundle-id rename removed the pre-rename Keychain access group from `Whistle.entitlements` outright instead of keeping both during a transition. On that device's first post-rename launch, the nsec under the old access group became unreachable; the app read "no nsec" as "first launch" and silently generated a new identity, no warning. The MLS database isn't Keychain-scoped, so it was untouched — every existing group kept running under the *old* identity's leaf and its fixed-at-creation credential, unrecognized by the app as "you". `IdentityService` now treats "no nsec, but real local group data already on disk" as a distinct anomaly and blocks on an explicit choice instead of silently generating a replacement identity.

    **Same-day correction**: the first attempt at this fix also widened `Whistle.entitlements` to list the pre-rename access group indefinitely, to make the old identity reachable again. This broke a live, working account — Keychain queries (ours, and MDK's own internal keyring-core ones) don't pin a specific access group, so with two groups listed and a dormant pre-rename item present, an unscoped query became ambiguous and picked the wrong item for both the nsec and MDK's database encryption key. No data was destroyed; reverting to a single access group immediately restored the account. Recovering the dormant old identity, if ever wanted, needs a dedicated one-time tool, not an ambient entitlements change.
- **(iOS & Android) Closed the remaining gaps in the v1.10.3 admin-cache fix.** "Invite People" (including "Add by npub"), "Ready to Join" approvals, and group rename no longer read the same stale cached admin list. `MarmotService.addMember` no longer refuses to add the app's own current pubkey — it was doing so unconditionally, before ever checking real membership. `MemberRowView`'s "Make Admin" swipe action no longer hides on your own row (Resync/Remove correctly still do). Together, these let an account affected by the identity-swap scenario above recover: add the current identity back into the group and promote it. Confirmed live end-to-end on the originally-affected account.

    **Kept from earlier v1.10.x commits, after re-review**: `leaveGroup`'s cache-free `selfDemote`-first rewrite; `promoteToAdmin`'s "always include your own pubkey" hardening; the `syncGroupMetadataFromMls()` call in `GroupDetailViewModel.load()` (still correct and useful generally, just not sufficient alone for a group whose live extension genuinely lacks the user's identity).

    **Known remaining gap, deliberately deferred**: the group-photo picker's admin gate and `MarmotService.isAdmin(_:ofGroup:)` underneath it still read the same stale cache. Lower stakes than being locked out of leaving or inviting, and tangled with a policy question (should any member set the group photo?) not worth deciding as a side effect here.

### v1.10.5 — Re-hide self-promote swipe action ✅
_Released 2026-09-19_

- **(iOS) "Make Admin" no longer shows on your own member row.** Unhidden deliberately in v1.10.4 to let an identity-swap-recovery account promote itself after being re-added to a group. On review this is a broader self-promotion surface than that one-time recovery needs, and the receive-side enforcement it depends on (does `MDK.updateGroupData`'s admin-list change get rejected by other devices when the sender isn't already an admin?) can't be confirmed from this repo — `mdk-core`'s Rust source isn't vendored, only the compiled bindings, and `updateGroupData` carries no explicit admin-only doc annotation unlike the neighboring `upgradeGroupCapabilities`. Reverted to hiding on your own row, same as Resync, rather than depend on unverified protocol enforcement for a capability the identity-swap recovery no longer needs day to day.

### v1.10.6 — Re-hide self-promote swipe action (Android) ✅
_Released 2026-09-19_

- **(Android) "Make Admin" no longer shows on your own member row.** v1.10.5's revert only touched iOS's `GroupDetailView.swift`; Android's `GroupDetailScreen.kt:680-685` had the identical "deliberately not gated on `isMe`" change from the same v1.10.4 commit (`15bc238`) and was missed — caught when asked why v1.10.5 was labeled iOS-only. Same fix and rationale as v1.10.5: reverted to hiding on your own row, same as Resync/Remove. Lesson: a CHANGELOG entry tagged "(iOS & Android)" doesn't guarantee a later single-platform revert covers both — check the other platform's equivalent file explicitly.

### v1.11.0 — Profile re-announce on join + Burn Identity leaves groups ✅
_Released 2026-09-20_

- **(iOS & Android) Burn Identity now leaves every group it safely can.** Closes items 2 and 3 of the "Burn Identity leaves zombie members" Deferred entry below. A pre-burn plan is computed before any confirmation: not-sole-admin groups are queued for the real self-remove `leaveGroup()`; sole-admin groups surface a combined review screen with a per-group picker to promote another member (defaulting to "end this group" rather than guessing) or accept the group ends. Admin lists are re-synced from live MLS state first — this is a one-way decision, so it shouldn't be made against a cache that can drift (same guard `GroupDetailViewModel` already uses). Execution is best-effort per group; one group's failure doesn't block the burn. The common case (no sole-admin groups) skips the review screen and goes straight to the existing confirmation, reworded to describe the new auto-leave behavior accurately.
- **(iOS & Android) A new joiner sees existing members' avatars and correct nicknames immediately.** Found live: an admin's avatar never reached a member who joined after it was set — the group photo already re-announces on any membership change, personal avatars and nicknames didn't. Both now piggyback on the same `lastGroupMembershipChangeId` signal the group photo uses; no designated-sender guard needed since each device resends only its own profile. Scaling note: costs one extra message per existing member with a profile set, per membership change — fine for a small group, would need throttling at scale.

    **Process note**: this shipped as two separate PRs merged together into one release rather than two point releases, since neither individually warranted its own tag/TestFlight/Zapstore cycle — batch small related changes into one release rather than shipping each the moment it's committed.

### v1.11.1 — Burn review UI polish + auto-committed proposal merge fix ✅
_Released 2026-09-21_

- **(iOS & Android) Burn review's promote-or-end section split into three clearly labeled camps** ("Leaving" / "Choose a new admin" / "Will end") with group names and an outcome icon in every section — previously "leaving" was a bare count and the sole-admin section mixed groups with a real decision alongside dead solo groups with nothing to decide. Icon in the middle section is dynamic, tracking the current promote/end choice live.
- **(iOS & Android) Group rename pencil hidden for non-admins.** A non-admin could tap it, type a new name, and save with no error shown — the edit never survived a live sync, since MDK's `updateGroupData` merges locally for a non-admin caller instead of rejecting it, and the next metadata sync silently reverted it. Gated on `isAdmin` instead of relying on enforcement that doesn't hold for this specific operation.
- **(iOS & Android) Root cause found and fixed for v1.11.0's auto-leave: a departed member stayed listed on the promoted admin's device, confirmed live even after a full restart.** A plain member's self-remove — what a burning admin's leave becomes once they've already self-demoted — arrives on other devices as an auto-committed proposal, not a ready commit. MDK prepares the resulting commit but doesn't merge it into the auto-committing device's own local state automatically, unlike every other self-authored commit path in this codebase (promote, rename, self-update: generate → merge → publish). That device broadcasts a correct evolution event everyone else applies fine as a normal commit — it just never applied the commit to itself. Regression test reproduces the exact production sequence against two real in-memory MDK instances; fix confirmed live on a real two-device burn (member count correctly dropped to 1 on both previously-affected groups).

---

### Deferred

- **MLS dependency strategy** _(open question, blocks nothing yet — parked pending upstream announcement)_: we are pinned to `mdk-swift` at MDK 0.8.0, and that binding line is frozen (last updated 2026-05-22). Upstream restructured: `mdk-core`/`mdk-uniffi` are gone from the workspace, merged into a rewrite with whitenoise-rs, replaced by `cgka-engine` / `cgka-session` / `cgka-traits` / `storage-sqlite` / `transport-*`, with the published **MarmotKit** bindings exposing a high-level account/chat SDK (`accountRef`, `ChatListSubscription`, agent streams) rather than the MLS primitives we drive ourselves.

    **Confirmed directly with upstream** (Danny, mdk maintainer, [mdk#938](https://github.com/marmot-protocol/mdk/issues/938), 2026-07-22): mdk-swift/mdk-kotlin *will* resume once the rewrite settles, raw-event send/view (our exact non-chat use case) is explicitly planned, and consumers in our position should stay on 0.8 until they announce readiness. **Do not chase `main` or hand-roll FFI over the `cgka-*` crates** — that was the live option before this response; it's now superseded by "wait for the announcement." [Haven](https://github.com/mehmetefeumit/Haven-App) still proves the low-level capability is consumable (it drives `cgka-session`/`cgka-engine`/`cgka-traits`/`storage-sqlite`/`transport-nostr-peeler` directly, forbidding the account/app layers in its own CI), so that path remains available if upstream goes quiet for an extended period — but it is not the current plan. Issue left open to track the announcement; offered to test Swift/Kotlin bindings against a non-chat consumer once ready. See `CLAUDE.md` MDK section for the pin details and full context — this entry should stay in sync with it rather than duplicate the analysis.

- **Android feature parity with iOS sharing flows** _(parity backlog)_: several invite/onboarding features exist only on iOS. Worth aligning (to discuss/prioritise):
    - **Onboarding** (`OnboardingView`) — three-card welcome carousel + permission framing before the system location prompt. Android goes straight to the main screen on first launch. _Parity matters._
    - ~~**NFC tag read/write**~~ — dropped rather than ported. Removed from iOS in v1.8.7 (`NFCReadCoordinator`/`NFCWriteCoordinator` had no remaining call sites).
    - ~~**Nearby Share**~~ — dropped rather than ported (QR scanning covers the same in-person handoff). Removed from iOS in `chore/remove-nearby-share`.

- ~~**Optional Google Maps on Android**~~ — dropped (2026-09-22) rather than pursued. No correctness motivation, and it cuts against the deliberate GrapheneOS-friendly positioning (osmdroid/OSM-only, no Google Play Services). Revisit only if a real user asks.

- **Push Notifications via MIP-05** _(parked)_: MIP-05 specifies a privacy-preserving push pipeline. Devices encrypt their APNs/FCM tokens to a notification server's pubkey (probabilistic encryption with ephemeral keys, no cross-group linkability) and gossip the encrypted tokens to group members via kinds 447/448/449. To deliver a push, the sending client gift-wraps a `kind:446` rumor with the bundled tokens (plus decoys) and publishes it to the server's inbox relays; the server decrypts each token and dispatches a silent content-available push.

    **Why parked**: iOS ties APNs credentials to our bundle ID, so we have to run the notification server ourselves — there's no generic third-party operator. That means committing to small but real infra (VPS uptime, APNs `.p8`, Firebase project, monitoring, reproducible-build hygiene so users can trust the deployment). Not worth it for TestFlight-only scale; revisit when we commit to Play Store / App Store distribution.

    **Phased plan when we pick this up**:
    1. **MDK UniFFI bindings** — `crates/mdk-core/src/mip05/` exists in MDK 0.8.0 (encrypt/decrypt, rumor builders, batching), but `mdk-uniffi` doesn't expose it yet. Contribute upstream the way we did for keyring (PR #252). Reconcile the spec-vs-impl padding-size drift (spec: 280-byte encrypted token, impl: 1084).
    2. **Notification server** — minimal stateless Rust service: subscribe to inbox relays for `kind:1059` addressed to its pubkey, unwrap → decrypt token → dispatch APNs/FCM. Open source, deployable to fly.io / small VPS, reproducible builds.
    3. **Client token gossip** — local token store keyed by MLS leaf index; handlers for kinds 447/448/449; refresh on join / token change / 25-35 day periodic; auto-cleanup on MLS Remove.
    4. **Notification trigger** — on outbound chat / location / battery-alert send, collect active-leaf tokens + decoys (self ±50%, 10-20% from other groups, min 3), shuffle, gift-wrap as `kind:446` rumor + `kind:13` seal + `kind:1059` wrap, publish to server inbox relays.
    5. **Platform integration** — APNs registration via `UNUserNotificationCenter` on iOS; FCM via Firebase SDK on Android. Ship behind an opt-in setting initially.

- ~~**Dependabot backlog needs a coordinated Kotlin/AGP pass**~~ ✅ Done (2026-09-01) — all 9 open Dependabot PRs (#174–#183) merged. The predicted risk didn't hit: #180 (`kotlin-gradle-plugin` 2.3.21→2.4.10) and #183 (`ksp` 2.3.8→2.3.10) each merged cleanly standalone, so AGP 9's bundled KGP tolerated the bump without the feared Compose-compiler mismatch. The real breakage was elsewhere, in #182 (`kotlin-test-junit` 2.3.21→2.4.10): its bundled `kotlin-test` core changed how `assertNotEquals<T>` infers `T`, and `assertNotEquals(false, payload.stationary)` in `LocationPayloadTest.kt` — a non-null `Boolean` paired with a `Boolean?` — could no longer resolve it ("the value of the type parameter 'T' must be mentioned in input types"). Fixed with an explicit type argument (`assertNotEquals<Boolean?>(...)`) rather than reverting the bump; `:shared`/`:app` unit tests pass unchanged. Separately, #174 (`actions/setup-python` v6→v7) and #177 (`actions/checkout` v6→v7) hit an unrelated adjacent-line merge conflict in `docs.yml` — both PRs' diffs sit on neighboring `uses:` lines in the same step, so Git flagged an overlapping-hunk conflict even though the actual pins never collided. Resolved by hand (`git merge origin/master`, keep both new pins).

- ~~**iOS releases have no CI automation at all**~~ ✅ Done (2026-09-11) — flagged as a follow-up during the v1.8.12 release (2026-09-01) when a fully-manual Xcode archive/upload was found to be why 1.8.7 sat "live" for several versions after it, and then lost — never written down anywhere until now. `release-ios.yml` now mirrors `release-android.yml`: the same `v*` tag push triggers `xcodebuild archive` → `-exportArchive` → direct-to-TestFlight upload via an App Store Connect API key (no Apple ID/password/2FA in CI), with the `.ipa` attached to the same GitHub release Android's workflow creates. Submitting the TestFlight build for App Store review is deliberately left manual — a release decision, not a build step, and Apple's review is a real gate regardless. Needs seven repo secrets (signing cert/profile + API key); see the `ios-release` skill for generating and rotating them. Chose this over full submit-for-review automation (removes a human checkpoint for no time saved) and over build-only-no-upload (still ends in a manual step someone can forget, the exact failure this was fixing).

    **First real run (2026-09-11) hit three sequential failures before succeeding**, each instructive: (1) `IOS_DIST_CERTIFICATE_B64`/`IOS_DIST_CERTIFICATE_PASSWORD` mismatched — the two secrets are a pair and must come from the same export, not be set independently; (2) after regenerating the certificate, the provisioning profile (unchanged) no longer referenced it — a profile is tied to specific certificates, not just a bundle ID, so regenerating one requires regenerating the other; (3) ✅ **fixed** — App Store Connect began hard-rejecting uploads built with less than the iOS 26 SDK (Xcode 26+) as of this date; `macos-15` only carries Xcode up to 16.4 (iOS 18.5 SDK). Bumped `release-ios.yml` to `macos-26` (GA since 2026-02, ships Xcode 26). `ci.yml`'s iOS jobs deliberately left on `macos-15` for now — Xcode 26 is a big enough jump to verify separately whether the app itself still compiles under it, rather than bundling that into the fix for what was actually blocking releases.

- **Android background execution has no durable story at all** _(reliability, Android — found alongside v1.8.13)_: a 4-agent deep dive into a 3-device sync test found that Android has zero infrastructure to survive backgrounding. v1.8.14 fixed the cheapest gap (catch-up calls not running on resume). **v1.8.16 fixed the three largest remaining gaps**, prompted by a live GrapheneOS report ("halts within minutes of closing and does not run on startup... you can never see anyone's position unless they have the app open"):
    - ~~No foreground `Service`~~ ✅ Fixed (v1.8.16) — `WhistleForegroundService` now holds `startForeground()` so the whole process gets foreground priority instead of being killed like any other backgrounded app within minutes. Started/stopped by `AppViewModel` to track whether there's an active group to share with; restarted after reboot by a new `BootCompletedReceiver`. Neither owns business logic directly — `BackgroundSessionCoordinator` (new) runs the relay-connect/MLS-init/subscribe sequence headlessly, since nothing outside `AppViewModel.onAppear()` previously did that at all, which would have left a foreground-priority process running with nothing wired up on a cold headless start.
    - ~~`ensureSubscriptionsActive()` coroutine-`isActive` false-positive~~ ✅ Fixed (v1.8.16) — now also checks `RelayService.hasConnectedRelays()`.
    - ~~`ACCESS_BACKGROUND_LOCATION` never requested at runtime~~ ✅ Fixed (v1.8.16) — requested as a follow-up once foreground location is granted (`MapScreen.kt`).
    - ~~No `WorkManager` anywhere in the module~~ — dropped (2026-09-22) rather than pursued. Would mainly help the rare case where the OS kills the process despite foreground status; marginal value for a small trusted test group at this scale.
    - No battery-optimization exemption request (`ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS`) — the app never asks to be exempted from Doze/App Standby, and Samsung's separate "sleeping apps" battery manager isn't covered by that exemption even if it were requested. Deferred out of v1.8.16 deliberately — GrapheneOS (the reporting platform) is close to stock AOSP on Doze behaviour, so a foreground Service alone should cover it; revisit if a report comes in from a more aggressive OEM skin.
    - `AppViewModel.onCleared()` stops subscriptions/location but never calls `relay.disconnect()`, which can leave the websocket client half-torn-down. Unrelated to `onCleared()` no longer being the thing that matters for staying alive in the background (that's the foreground Service's job now), but still worth cleaning up.

- **MLS commits are applied in relay-delivery order, not epoch order** _(protocol-level, iOS & Android — found alongside v1.8.13)_: `handleIncomingEvent` hands kind-445 events straight to MDK as they arrive from the relay(s), with no buffering or epoch-sorting on either platform. NIP-01 doesn't guarantee chronological backlog replay, so a commit can reach MDK ahead of its predecessor — which is what triggers the `PreviouslyFailed` blacklist v1.8.13's health-tracker fix now makes visible. The health-tracker fix only makes the stuck state *visible*; it doesn't prevent it. A real fix would need either client-side epoch-ordered buffering before dispatch, or an MDK change to retry a blacklisted commit once its prerequisite epoch lands (out of scope while pinned to MDK 0.8.0 — see the MLS dependency strategy entry above). Also worth doing once the health-tracker signal exists: auto-trigger the hard resync (remove+re-add) when a device is detected durably behind the group's leading epoch, instead of requiring a human to notice and tap the manual Resync button.

    **Note (2026-09-21):** initially suspected as the cause of a live burn-flow bug (a departed member staying listed on another device), since the burn sequence fires several commits on one group in quick succession. It wasn't — the actual cause (fixed in v1.11.1) was `.proposal` results never being merged locally before publishing, a distinct bug in a different code path. This entry remains open and real, just confirmed unrelated to that incident.

- **A third `GroupHealthTracker` blind spot: thrown decrypt exceptions on our own group are recorded nowhere** _(diagnostics, iOS & Android — found live testing v1.8.13/14, not yet fixed)_: `handleIncomingEvent`'s outer `catch (e: Exception)` block handles a genuine MDK decrypt failure (e.g. `"Failed to decrypt message with any exporter secret from epochs X to Y"`, reproduced live — 24 of them in one cold-start burst) by setting `_lastError` (a single latest-error string, overwritten by the next error of *any* kind) and logging — it never calls `recordFailure` or `recordFailureType`, unlike the two `ProcessMessageResult`-typed failure modes v1.8.13 fixed. This is a different code path: MDK *throwing* rather than returning a typed result. Deliberately left unmarked-processed so catch-up can retry it (existing, correct behaviour) — the gap is purely that `GroupHealthTracker`/`DiagnosticsReport.recentFailures` never hears about it happening at all. Fix should mirror v1.8.13's approach: classify by a generic type (not the raw message, which `FailureCount` deliberately never carries) and call `recordFailureType` from the non-foreign-group branch of that catch block.

---

## Branch Strategy

Each phase = `feature/vX.Y-description` branch off `master`.
PR per phase → review → merge to `master`.
Bug-fix releases use `bugfix/v0.x.y` branches.
Other housekeeping uses `chore/description`. Full branch history lives in `git log`, not here.

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
