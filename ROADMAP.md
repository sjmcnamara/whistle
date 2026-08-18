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

---

### Deferred

- **Burn Identity leaves zombie members in every group** _(correctness + safety, iOS & Android)_: burning destroys local state only — `mls.resetDatabase()` zero-fills `whistle.db`, taking the ratchet tree, epoch secrets, and the device's leaf private keys with it. It sends no leave request and no removal proposal, so **every other member still has that leaf in their tree and keeps encrypting to it**. The burned user cannot decrypt anything, cannot rejoin, and cannot be recovered by re-importing the same nsec: MLS membership is key material in that database, not a property of the Nostr key.

    Three things to fix, in order of severity:

    1. ~~**The confirmation text is factually wrong.**~~ ✅ Fixed — both platforms now state that burning does not remove you from your groups, that other members will still see you, and that you cannot rejoin unless another admin re-adds you.
    2. **The sole-admin case is unrecoverable for everyone else — present it as a choice, not a block.** `adminPubkeys` lives in group state, and only an admin can remove or re-add a member. If the only admin burns, the group can never remove the dead leaf, never re-add them, and never promote anyone — it is permanently frozen for every remaining member.

        A hard block was considered and rejected: someone burning a compromised key must not be trapped. The honest framing is **"promote someone else first, or end this group now"** — name the groups where the user is the only admin, offer to promote a member, and require an explicit acknowledgement that those groups are finished if they proceed. Detection is cheap (`adminPubkeys.count == 1 && adminPubkeys.first == myPubkey` across active groups).

        **Promotion is already safe to rely on here.** `MarmotService.promoteToAdmin` appends to `adminPubkeys` via an `updateGroupData` commit — unilateral, the promoted member accepts nothing — and calls `publishAndVerifyCommits` before returning. So a successful promote means the commit is *on the relay*, and the new admin will pick it up whenever they next sync, even if they are offline at the moment of the burn. The promotion is durable before local state is destroyed.

        **The failure case is the one to design for.** If `promoteToAdmin` throws (relay unreachable, commit unverified), the promotion did not land and burning at that moment does freeze the group — and that is precisely when someone with a compromised key is in a hurry. So this must not be a single atomic "promote and burn" action:

        - promote succeeded → burn freely; removing the stale leaf is routine admin work for the new admin
        - promote failed → say plainly that it did not reach the relay and that burning now ends the group, then **still allow the burn**

        Never block. A compromised key is a worse problem than a frozen family group, and the person holding the key is the one best placed to weigh that.

        Post-burn cleanup needs nothing new: the new admin removes the dead leaf with the existing remove-member action (relay-verified since v1.6.4), and if the burned user re-imports, their app publishes a fresh KeyPackage on launch so they can be re-added by npub.
    3. **Offer leave-before-burn.** The correct sequence is to send leave requests, let admins process the removals, then burn. Nothing prompts this today. A "leave your groups first" step (or an explicit "burn anyway, stranding N groups" acknowledgement) would make the trade visible.

    Related: the hard-resync path from v1.6.3 (admin remove + re-add) is the only existing remedy, and it requires an admin who is not the burned identity.

- ~~**Submit Whistle to `awesome-marmot`**~~ ✅ Done — [Whistle listed under Applications](https://github.com/marmot-protocol/awesome-marmot) alongside Haven and tubestr-v2, PR merged 2026-07-22.

- **MLS dependency strategy** _(open question, blocks nothing yet — parked pending upstream announcement)_: we are pinned to `mdk-swift` at MDK 0.8.0, and that binding line is frozen (last updated 2026-05-22). Upstream restructured: `mdk-core`/`mdk-uniffi` are gone from the workspace, merged into a rewrite with whitenoise-rs, replaced by `cgka-engine` / `cgka-session` / `cgka-traits` / `storage-sqlite` / `transport-*`, with the published **MarmotKit** bindings exposing a high-level account/chat SDK (`accountRef`, `ChatListSubscription`, agent streams) rather than the MLS primitives we drive ourselves.

    **Confirmed directly with upstream** (Danny, mdk maintainer, [mdk#938](https://github.com/marmot-protocol/mdk/issues/938), 2026-07-22): mdk-swift/mdk-kotlin *will* resume once the rewrite settles, raw-event send/view (our exact non-chat use case) is explicitly planned, and consumers in our position should stay on 0.8 until they announce readiness. **Do not chase `main` or hand-roll FFI over the `cgka-*` crates** — that was the live option before this response; it's now superseded by "wait for the announcement." [Haven](https://github.com/mehmetefeumit/Haven-App) still proves the low-level capability is consumable (it drives `cgka-session`/`cgka-engine`/`cgka-traits`/`storage-sqlite`/`transport-nostr-peeler` directly, forbidding the account/app layers in its own CI), so that path remains available if upstream goes quiet for an extended period — but it is not the current plan. Issue left open to track the announcement; offered to test Swift/Kotlin bindings against a non-chat consumer once ready. See `CLAUDE.md` MDK section for the pin details and full context — this entry should stay in sync with it rather than duplicate the analysis.

- **Android feature parity with iOS sharing flows** _(parity backlog)_: several invite/onboarding features exist only on iOS. Worth aligning (to discuss/prioritise):
    - **Onboarding** (`OnboardingView`) — three-card welcome carousel + permission framing before the system location prompt. Android goes straight to the main screen on first launch. _Parity matters._
    - ~~**NFC tag read/write**~~ — dropped rather than ported. Removed from iOS in v1.8.7 (`NFCReadCoordinator`/`NFCWriteCoordinator` had no remaining call sites).
    - ~~**Nearby Share**~~ — dropped rather than ported (QR scanning covers the same in-person handoff). Removed from iOS in `chore/remove-nearby-share`.

- **Optional Google Maps on Android** _(backlog)_: Android currently renders maps via osmdroid (OpenStreetMap) only — a deliberate choice that keeps the app free of Google Play Services and lets it install/run on GrapheneOS and other degoogled devices. A future option could expose a "Map provider" setting (OSM / Google Maps) via Gradle product flavors so the GMS variant is a separate APK, leaving the default GMS-free. Not a fallback — both would be deliberate user choices.

- **Push Notifications via MIP-05** _(parked)_: MIP-05 specifies a privacy-preserving push pipeline. Devices encrypt their APNs/FCM tokens to a notification server's pubkey (probabilistic encryption with ephemeral keys, no cross-group linkability) and gossip the encrypted tokens to group members via kinds 447/448/449. To deliver a push, the sending client gift-wraps a `kind:446` rumor with the bundled tokens (plus decoys) and publishes it to the server's inbox relays; the server decrypts each token and dispatches a silent content-available push.

    **Why parked**: iOS ties APNs credentials to our bundle ID, so we have to run the notification server ourselves — there's no generic third-party operator. That means committing to small but real infra (VPS uptime, APNs `.p8`, Firebase project, monitoring, reproducible-build hygiene so users can trust the deployment). Not worth it for TestFlight-only scale; revisit when we commit to Play Store / App Store distribution.

    **Phased plan when we pick this up**:
    1. **MDK UniFFI bindings** — `crates/mdk-core/src/mip05/` exists in MDK 0.8.0 (encrypt/decrypt, rumor builders, batching), but `mdk-uniffi` doesn't expose it yet. Contribute upstream the way we did for keyring (PR #252). Reconcile the spec-vs-impl padding-size drift (spec: 280-byte encrypted token, impl: 1084).
    2. **Notification server** — minimal stateless Rust service: subscribe to inbox relays for `kind:1059` addressed to its pubkey, unwrap → decrypt token → dispatch APNs/FCM. Open source, deployable to fly.io / small VPS, reproducible builds.
    3. **Client token gossip** — local token store keyed by MLS leaf index; handlers for kinds 447/448/449; refresh on join / token change / 25-35 day periodic; auto-cleanup on MLS Remove.
    4. **Notification trigger** — on outbound chat / location / battery-alert send, collect active-leaf tokens + decoys (self ±50%, 10-20% from other groups, min 3), shuffle, gift-wrap as `kind:446` rumor + `kind:13` seal + `kind:1059` wrap, publish to server inbox relays.
    5. **Platform integration** — APNs registration via `UNUserNotificationCenter` on iOS; FCM via Firebase SDK on Android. Ship behind an opt-in setting initially.

- **Dependabot backlog needs a coordinated Kotlin/AGP pass** _(maintenance, low urgency but growing)_: 10 Dependabot PRs (#174–#183) have sat unmerged since 2026-07-23 — 5 Android Gradle bumps, 5 GitHub Actions bumps. The Actions ones (#174, #176–#179) are independent and safe to merge individually. The Kotlin-related Android ones (#180 `kotlin-gradle-plugin`, #182 `kotlin-test-junit`, plus #181 `play-services-location`, #183 `ksp`) are not: the last AGP 9 upgrade (2026-07-19, PR #150) needed a coordinated bump of Kotlin 2.3.21 + KSP 2.3.8 pinned together via the root `buildscript` block, because Dependabot bumping Kotlin alone mismatches AGP's bundled KGP and breaks the Compose compiler. Bumping #180/#182 individually will likely repeat that failure — batch them with a matching KSP version rather than merging one at a time.

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
