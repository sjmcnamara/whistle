# Changelog

All notable changes to Whistle will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

### Fixed
- **Groups lost after force quit** (iOS): MLS database was deleted on every launch because `MLSService.initialise()` unconditionally called `deleteDatabase()` in the `newMdk` failure path — which always fails while MDK #243 (keyring-core UniFFI exposure) is unresolved. The delete calls have been removed; the unencrypted fallback now opens the existing database directly, preserving all groups and messages across relaunches
- **Android unit test coverage** (CI): switched from a custom `JacocoReport` task (which produced ~0% because AGP 8.x writes compiled classes to a different path) to the AGP built-in `createDebugUnitTestCoverageReport` task; Android coverage now reports correctly in Codecov

### Added
- **Android unit tests**: 6 new test suites (LocationFuzz, LocationViewModel, MemberSort, GroupListItem, ChatMessageItem, MemberAnnotation) — 60 new tests covering location fuzzing math, map annotation staleness, group filtering, member sort order, unread logic, and chat message type filtering; total Android tests now 90
- **MockK + coroutines-test**: added test dependencies for mocking Android services and testing coroutine-based ViewModels
- **Protocol round-trip tests — Tier 1** (iOS): 27 tests covering group lifecycle (create, rename, relays), member add/remove via Welcome, message delivery (chat, location, nickname payloads), key rotation (epoch advancement, post-rotation messaging), leave requests, invite code round-trip, and subscription setup
- **Failure & recovery tests — Tier 2** (iOS): 40 tests covering uninitialised MLS errors, health tracker threshold/recovery, invalid/corrupt event handling, message ordering and pagination, concurrent group and message operations, identity lifecycle (generate/restore/destroy/import), MLS reset, store deduplication (PendingInvite, PendingLeave, PendingWelcome), and Welcome decline

### Changed
- **Codecov: exclude Compose UI from coverage**: `ui/`, `MainActivity`, `FindMyFamApp`, and `di/` excluded from Codecov metrics — these require instrumentation tests and were dragging overall coverage to 3%
- **`fuzzCoordinate` extracted for testability**: location fuzzing algorithm extracted from `AppViewModel` to an `internal` top-level function with injectable `Random` for deterministic testing
---

## [1.0.1] — 2026-04-03

### Fixed
- **Chat timestamps** (iOS): message timestamps now display wall-clock time ("2:30 PM") instead of relative age ("5 minutes ago"), matching Android, Signal, and WhatsApp conventions
- **"Load earlier messages" button** (iOS): button was always visible but did nothing — `hasMore` was not `@Published` so SwiftUI never re-rendered when pagination state changed; now correctly hidden when all messages are loaded
- **Imprecise location grey pin** (iOS): when "Precise Location" is disabled in iOS Settings, the location payload timestamp is now stamped with the broadcast time rather than the OS acquisition time — prevents false stale-pin detection from cached location objects
- **Invalid location fix filtering** (iOS): locations with `horizontalAccuracy < 0` (CoreLocation's signal for no valid fix) are now dropped before entering the broadcast pipeline
- **Pin label truncation** (iOS): relative timestamp labels on map pins now scale down to fit rather than clipping to "2mins,..."

### Added
- **Location fuzzing** (iOS & Android): new "Location Privacy" section in Advanced Settings with Off / 10 m / 50 m / 200 m options; applies a random offset within the chosen radius before broadcasting — shared coordinates are approximate, not exact
- **Codecov integration**: coverage reports uploaded to Codecov on every CI run; separate flags for `ios` (WhistleTests) and `whistlecore` (WhistleCore SPM) for per-layer visibility; informational only, not a PR gate

### Changed
- **Version bump** — iOS 1.0.1 (build 16), Android 1.0.1 (versionCode 13)

---

## [1.0.0] — 2026-04-02

### Security
- **Secure Enclave-wrapped nsec** (iOS): the Nostr secret key is now AES-GCM encrypted with a symmetric key derived from a Secure Enclave-bound P-256 ECDH key agreement; hardware-bound, non-exportable; automatic one-time migration from plaintext Keychain on first launch
- **StrongBox-backed Keystore** (Android): `MasterKey` now requests StrongBox backing for hardware-bound key encryption on devices with dedicated secure elements; diagnostic log on startup
- **Plaintext nsec fallback removed** (iOS): the UserDefaults fallback that could store the nsec in plaintext (included in unencrypted backups) has been removed; Keychain-only storage with legacy migration
- **Privacy audit**: systematic review verified no metadata leakage — all group payloads MLS-encrypted (kind 445), member lists never on relays, NIP-59 gift-wrap hides sender via ephemeral key, no `p`/`e` tags leak group members

### Added
- **Relay management** (iOS & Android): add custom relays with URL validation, remove custom relays (swipe-to-delete on iOS, X button on Android), enable/disable toggle per relay; default relays cannot be removed
- **Live relay reconnect**: toggling, adding, or removing a relay immediately disconnects and reconnects with the updated relay set — connection status dots and labels update in real time
- **Per-relay connection dot**: green dot when connected and enabled, grey when disabled or disconnected (iOS & Android)
- **Dynamic connection status**: Connection section shows actual relay state (Disconnected / Connecting / Connected / Failed) and MLS crypto state (Starting / Ready / Failed) instead of hardcoded labels
- **Event dedup logging**: structured debug logs on both platforms confirm duplicate event skipping when subscribed to multiple relays (`processedEventIds` + MLS `PreviouslyFailed`)

### Improved
- **SwiftLint strict mode**: all 336 Swift files clean with 0 violations; `--strict` flag enabled in CI so any new warning fails the build
- **Android map filter parity**: pending-leave groups now hidden from the map filter picker on Android (matching iOS v0.9.4 behaviour)

### Changed
- **CI merge gate**: required status checks enabled on master — all CI jobs must pass before merge
- **Version bump** — iOS 1.0.0 (build 15), Android 1.0.0 (versionCode 12)

---

## [0.9.4] — 2026-04-02

### Security
- **Welcome consent**: unsolicited group additions now require user approval; only Welcomes matching a pending invite are auto-accepted. Prevents forced group membership via direct addMember-by-npub
- **Burn identity hardening**: old nsec is explicitly destroyed from Keychain / EncryptedSharedPreferences before the new key is written; MLS database files are overwritten with zeros before deletion; all residual UserDefaults / SharedPreferences data (chat timestamps, read timestamps, pending welcomes) is purged

### Added
- **Burn Identity**: new "Danger Zone" action in Advanced Settings generates a fresh Nostr keypair, tearing down all groups, messages, and cryptographic state (iOS & Android)
- **Admin action badge**: small orange dot on the group icon when the admin has pending actions (e.g. leave request approval); clears automatically after processing (iOS & Android)
- **Cancel stale invites**: users can now swipe-to-dismiss (iOS) or tap X (Android) on pending invites that were never accepted

### Improved
- **Create Group auto-focus**: keyboard opens automatically on the group name field when the Create Group sheet appears (iOS & Android)
- **Welcome invite UI**: compact circular checkmark / X icons replace bulky bordered buttons for accept/decline on unsolicited group invitations
- **Empty state polish**: restyled "No groups yet" screen with larger stacked buttons (iOS)

### Fixed
- **Pending-welcome groups hidden**: groups awaiting consent no longer appear as "Inactive" in the group list after pull-to-refresh (iOS & Android)
- **QR scanner auto-dismiss**: scanning an npub QR in Add Member now dismisses the camera immediately instead of lingering (iOS & Android)
- **Add Member tap targets** (iOS): fixed `.buttonStyle(.borderless)` and 44pt minimum touch targets so the QR and Add buttons don't steal each other's taps
- **Map group filter** (iOS): groups with a pending leave request are now hidden from the map filter picker; selection auto-clears when a leave is requested
- **Admin leave approval UX**: members requesting to leave now show a green "Approve" swipe action (iOS) or "Approve" button (Android) instead of the generic destructive remove gesture

### Changed
- **Version bump** — iOS 0.9.4 (build 14), Android 0.9.4 (versionCode 11)

---

## [0.9.3] — 2026-04-02

### Security
- **Commit/Welcome ordering** (MIP-02): commit events are now verified on the relay before the Welcome is sent, preventing state forks where a joiner processes a Welcome but other members can't fetch the corresponding commit
- **Post-join self-update** (MIP-02): new members immediately rotate key material after joining a group, limiting the KeyPackage exposure window
- **Gift-wrap retry expiry**: stale/unrecoverable gift-wrap event IDs are purged after one retry pass to prevent infinite retry spam

---

## [0.9.2] — 2026-04-01

### Added
- **Dark mode setting** — three-way Appearance picker (System / Light / Dark) in Settings on both iOS and Android; takes effect immediately without restart
- **Splash screen rebrand** — replaced SF Symbol logo with Whistle wordmark + zap icon (transparent PNG) on both platforms; simplified to a clean loader with progress indicator

### Changed
- **Version bump** — iOS 0.9.2 (build 12), Android 0.9.2 (versionCode 9)

---

## [0.9.1] — 2026-04-01

### Changed
- **Settings / Advanced split** — main Settings screen now shows Identity (Nostr key + display name), Location, and About; Import/Export Key, Security, Relays, and Connection moved to a new Advanced Settings screen (both platforms)
- **Android About section** — added missing Protocol ("Nostr & MLS & Marmot") and GitHub source link to match iOS
- **Version bump** — iOS 0.9.1 (build 11), Android 0.9.1 (versionCode 8)

---

## [0.9.0] — 2026-04-01

### Security
- **MLS database encryption at rest** — MDK SQLite database is now opened with SQLCipher via `newMdk(serviceId:dbKeyId:)` on both iOS and Android; previously used `newMdkUnencrypted`, leaving all MLS group keys, exporter secrets, and key packages in plaintext on-device storage
- **Key management via keyring-core** — the MDK handles 32-byte encryption key generation and storage internally through `keyring-core`, using the platform's native credential store (iOS Keychain / Android Keystore) — no app-level key management required
- **Stale DB resilience** — if an existing plaintext DB cannot be opened with the encryption key, it is deleted and recreated encrypted (force-reinstall policy; no migration)
- **iOS file sharing removed** — `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` removed from `Info.plist` now that the DB is encrypted
- **MDK binary updated** — pinned revision advanced to `c58a77f` (from `80eab77`)

### Notes
- Pre-0.9 installs must be fully uninstalled before installing 0.9 (alpha policy — no migration)
- Verify encryption: `sqlite3 /path/to/findmyfam-mdk.db "PRAGMA integrity_check;"` should return `Parse error: file is not a database`

---

## [0.8.6] — 2026-04-01

### Fixed
- **QR invite code** — iOS invite share sheet now encodes the raw base64 invite code in the QR, matching Android; previously encoded the full `whistle://invite/` deep link URL
- **Remove "Share my key with admin"** — dropped the post-join `ShareLink` from `JoinGroupView`; the admin can scan the invitee's npub QR directly via the Scan QR action in Group Details
- **Map group filter stale after leave/evict** — group filter now auto-clears on both platforms when the selected group is left or evicted (iOS `onChange`, Android `LaunchedEffect` + `clearFilterIfInvalid`)
- **Unread indicator reappears after pull-to-refresh** — MDK's `lastMessageAt` advances for every MLS event including location updates and nickname changes, not just chat messages; introduced a dedicated `lastChatTimestamps` store (iOS UserDefaults / Android SharedPreferences) updated only when a chat message arrives, so pull-to-refresh no longer re-triggers the unread dot for non-chat activity
- **Version string in Settings** — iOS and Android Settings screens now read the version dynamically from the build config (`CFBundleShortVersionString` / `PackageManager.versionName`) instead of a hardcoded string

### Changed
- **Xcode project rename** — project, app target, scheme, `PRODUCT_NAME`, and entitlements file renamed from `FindMyFam` → `Whistle` in `project.yml`
- **`FindMyFamCore` → `WhistleCore`** — Swift package directory, `Package.swift`, source/test dirs, and all imports renamed
- **`FindMyFamTests` → `WhistleTests`** — test source directory and `project.yml` path updated
- **Version bump** — iOS 0.8.6 (build 9), Android 0.8.6 (versionCode 6)

### Notes
- Bundle identifiers (`org.findmyfam`) and Android package name unchanged
- Run `xcodegen generate` after pulling to regenerate the `.xcodeproj` with the new target/scheme names

---

## [0.8.5] — 2026-03-31

### Changed
- **Branding refresh** — user-facing app name updated from Famstr to Whistle on iOS and Android (launcher label, splash title, lock prompts, and permission copy)
- **Deep-link migration** — moved invite/member approval links from `famstr://` to `whistle://` across iOS, Android, shared models, tests, and docs
- **URL scheme registration** — updated app URL handling configuration to register the `whistle` scheme on both platforms
- **Bonjour service rename** — updated local discovery services from `_famstr` to `_whistle` and regenerated iOS project outputs
- **App icons/logo** — updated launcher icon assets for both platforms to the new Whistle branding pack
- **Version bump** — iOS 0.8.5 (build 8), Android 0.8.5 (build 5)

### Notes
- Package and namespace identifiers remain unchanged (`org.findmyfam`)

---

## [0.8.4] — 2026-03-27

### Added
- **Shared core libraries** — extracted models, protocol constants, and shared logic into platform-specific internal libraries (`FindMyFamCore` Swift package on iOS, `:shared` Gradle module on Android) with full test suites (44 tests each)
- **Protocol spec** — `docs/wiki/PROTOCOL.md` documenting all Marmot event kinds, JSON payload schemas, app defaults, and deep-link URL schemes
- **`AppDefaults`** — centralised shared constants (default relays, intervals, preference keys) referenced by both platforms

### Changed
- Default relays aligned across platforms (`relay.primal.net` replaces `relay.nostr.band` on Android)
- Version bump — iOS 0.8.4 (build 7), Android 0.8.4 (build 4)

### Fixed
- **`testFetchMissedGiftWrapsRetriesPendingGiftWrapIds`** — test was silently no-oping due to nil `settings`; now injects `AppSettings.shared` before asserting

---

## [0.8.3.2] — 2026-03-27

### Fixed — Android
- **Indoor location sharing** — removed OS-level distance filter (`0f`) and time gate (`0L`) from `LocationManager` so updates fire when stationary indoors; rate limiting is now handled solely by the app-level `intervalSeconds` throttle, matching iOS behaviour
- **Map filter lost on navigation** — group filter selection on the family map is now preserved when switching tabs; `LocationViewModel` moved from composable `remember {}` scope into `AppViewModel` so it survives navigation

### Changed
- **Android version bump** — 0.8.3.2 (build 3)

---

## [0.8.3.1] — 2026-03-26

### Fixed — Android
- **QR invite join** — scanned `whistle://invite/` deep-link URLs now correctly stripped to raw base64 before decoding; previously the prefix caused silent decode failure
- **App lock bypass** — lock screen now has opaque background and consumes all touch events; previously the app was fully navigable behind the biometric prompt
- **Duplicate member crash** — LazyColumn keys use index suffix to prevent crash when MDK returns duplicate leaf nodes for the same identity
- **Keyboard dismiss on send** — chat input keyboard now dismisses after sending a message
- **Relay list in Settings** — added missing relay section with enable/disable toggles per relay
- **QR scan navigation** — scanned invite code now passed via shared Compose state instead of savedStateHandle which was silently failing across navigation entries
- **Member list dedup** — `getMembers()` results deduplicated with `.distinct()` in both GroupDetailViewModel and ChatViewModel

### Fixed — iOS
- **Add Member by npub** — admin GroupDetailView now has a manual npub/hex input field to add members directly (was missing from UI despite ViewModel support)

### Changed
- **Android version bump** — 0.8.3.1 (build 2)

## [0.8.3-android] — 2026-03-26

### Added — Android
- **Android app** — full native port using Kotlin, Jetpack Compose, and Hilt DI
- **Cross-platform messaging** — Android and iOS devices communicate via the same MLS-encrypted Nostr groups
- **OpenStreetMap** — family map using osmdroid (no Google Play Services dependency, works on GrapheneOS)
- **Location sharing** — Android LocationManager with configurable throttle, broadcasts to all groups
- **QR code flow** — ZXing generation on invite share, CameraX + ML Kit scanner on join
- **NIP-49 key import/export** — encrypted backup and cross-platform identity transfer
- **Biometric app lock** — BiometricPrompt with fingerprint/face/device credentials
- **Settings** — display name, relay config, location interval, key rotation, app lock
- **MDK Kotlin bindings** — built from mdk-uniffi crate for arm64-v8a and x86_64
- **NostrSDK Kotlin** — rust-nostr v0.44.2 via Maven Central

### Architecture
- Monorepo: iOS at root, Android in `android/` directory
- Shared CHANGELOG and ROADMAP across platforms
- Pre-built native `.so` libs checked in; rebuild instructions in `android/BUILD.md`

## [0.8.3] — 2026-03-25

### Added
- **Automatic key rotation** — MLS group encryption keys are rotated via self-update (epoch advance) on a configurable schedule (default 7 days); stale groups are rotated on launch and rechecked every 6 hours while the app is active
- **Key Rotation Interval setting** — picker in Security settings (1 / 3 / 7 / 14 / 30 days) to control rotation frequency
- **Forward secrecy audit logging** — structured logs track epoch transitions (old → new) on rotation and incoming commits; unprocessable events confirm old epoch keys are deleted per RFC 9420 §14.1
- **Epoch mismatch warning** — groups with persistent decryption failures show a "Decryption failed" badge in the group list and a red banner in the chat view advising re-invite

### Fixed
- **Map group filter** — left/inactive groups no longer appear in the group picker on the family map
- **Key package relay broadcast** — key packages now published to all enabled relays on invite accept, fixing race condition where admin couldn't fetch the invitee's key package

### Changed
- **Version bump** — app version updated to 0.8.3 (build 6)

## [0.8.2] — 2026-03-25

### Added
- **Identity export (NIP-49)** — encrypt your private key with a password and export as an ncryptsec string for secure backup or transfer
- **Identity import** — import an existing Nostr identity from a plaintext nsec or encrypted ncryptsec, replacing the current keypair
- **Import / Export Key settings page** — new sub-page under Identity in Settings with dedicated export and import flows
- **Full identity replacement** — importing a key tears down all key-bound state (MLS groups, caches, relay subscriptions) and restarts the app with the new identity

### Changed
- **IdentityCardView** — updated informational text to mention encrypted backup availability
- **Version bump** — app version updated to 0.8.2 (build 5)

### Fixed
- **Startup UI responsiveness** — relay connect and MLS init now run in parallel (`async let`), `Task.yield()` drains the main run loop between heavy steps, and `startSubscriptions()` no longer blocks `onAppear()` with its infinite notification loop
- **Deferred post-ready work** — nickname broadcast and key-package refresh now run after the splash dismisses so the UI becomes interactive sooner

## [0.8.1] — 2026-03-24

### Added
- **App Lock security layer** — optional lock screen shown at app launch to protect app access
- **Security settings controls** — new Settings toggles for App Lock and "Require Unlock on Reopen" session behavior
- **Explicit passcode path** — lock screen includes a dedicated "Use Passcode" action for reliable non-biometric unlock
- **Map mode selector** — toolbar menu on the family map to switch between Default and Satellite views

### Changed
- **Authentication flow hardening** — lock lifecycle no longer repeatedly re-triggers auth around scene phase changes
- **Version bump** — app version updated to 0.8.1 (build 4)

### Fixed
- **Face ID setup issue** — added `NSFaceIDUsageDescription` to app configuration and plist generation source
- **"Authentication cancelled" noise** — expected cancel/system-cancel cases no longer surface as persistent lock errors
- **Passcode fallback regression** — explicit passcode action now routes to passcode-only evaluation instead of re-triggering Face ID

## [0.7.3] — 2026-03-24

### Fixed
- **Group details compile regression** — fixed member removal swipe action scoping in `GroupDetailView` (`member` is now resolved correctly in row scope)
- **Settings compile regression** — corrected `SettingsView` structure/scope and switched app-settings navigation to SwiftUI `openURL`
- **Export compliance key** — restored `ITSAppUsesNonExemptEncryption=false` in `Info.plist`

### Changed
- **About projects links** — Settings now shows direct links to Nostr, OpenMLS, and Marmot Protocol project pages

---

## [0.7.2] — 2026-03-22

### Fixed
- **Delayed welcome handling** — gift-wrap events that fail with "No matching key package" are now queued for retry, and retries are run after key package refresh
- **Pending welcome retry** — `fetchMissedGiftWraps()` now re-checks pending failing gift-wrap IDs in addition to new relay events

### Changed
- **Key package refresh now triggers welcome fetch** — `AppViewModel` calls `marmot.fetchMissedGiftWraps()` after refreshing key packages for pending invitations

---

## [0.7.1] — 2026-03-22

### Fixed
- **Member count stale after removal** — member count in group list and chat header now updates immediately when a member leaves or is removed
- **Member list subtitle in chat** — fixed member names not displaying in group chat header subtitle; now loads on view appearance and updates when membership changes
- **Stale member names after removal** — ChatViewModel now subscribes to membership change events and refreshes member names when members join/leave
- **Cache cleared on failed remove** — `removeMember()` now only clears cached locations after successful group event publication, preventing cache corruption on MLS errors
- **Overzealous cache clearing** — changed group member removal to clear only the removed member's location instead of all members in the group
- **Missing state refresh on proposal events** — MarmotService now calls `refreshGroups()` and notifies subscribers on `proposal` and `pendingProposal` event processing, ensuring consistent UI updates across all event types

### Changed
- **Member removal fine-grained** — introduced per-member location cache removal (`LocationCache.removeLocation()`) instead of batch group clearing for better UX when admins manage members

---

## [0.7.0] — 2026-03-17

### Added
- **AirDrop / deep-link invites** — invites are now shared as `whistle://invite/<code>` URLs; accepting an AirDrop or tapping a link opens the app and pre-fills the Join Group sheet — no copy-paste required
- **QR code scanning** — "Scan QR Code" button in Join Group opens a live camera scanner; pointing at an inviter's QR code auto-populates and submits the join request
- **NFC read** — "Tap NFC Tag" button (iPhone 7+) reads an NDEF invite URL from any NFC tag and auto-joins
- **NFC write** — "Write to NFC Tag" button in the Invite sheet writes the `whistle://` invite URL to a blank NFC sticker; anyone can tap their phone to the sticker to join
- **One-tap member approval** — after joining, invitee can share a `whistle://addmember/` URL with the admin; admin tap approves without pubkey copy-paste
- `InviteCode.asURL()` — wraps the base64 code in a `whistle://invite/` deep-link URL
- `InviteCode.from(url:)` — decodes an invite from a `whistle://` URL or raw base64 (backwards compatible)
- `InviteCode.approvalURL(pubkeyHex:groupId:)` — builds a `whistle://addmember/` approval deep link for admin confirmation flow
- `NFCReadCoordinator` — `@StateObject` helper for NDEF tag reading
- `NFCWriteCoordinator` — `@StateObject` helper for writing NDEF URL records to NFC tags
- `QRScannerView` — AVCaptureSession-based QR scanner with scan-frame guide

### Changed
- **InviteShareView** — "Share" button now shares the `whistle://` URL (AirDrop auto-handles it); QR now encodes the URL; legacy raw code still shown for copy
- **JoinGroupView** — accepts `initialCode` param for deep-link/QR/NFC pre-fill; added QR scan and NFC read buttons

---

## [0.6.1] — 2026-03-17

### Added
- **AirDrop / deep-link invites** — invites are now shared as `whistle://invite/<code>` URLs; accepting an AirDrop or tapping a link opens the app and pre-fills the Join Group sheet — no copy-paste required
- **QR code scanning** — "Scan QR Code" button in Join Group opens a live camera scanner; pointing at an inviter's QR code auto-populates and submits the join request
- **NFC read** — "Tap NFC Tag" button (iPhone 7+) reads an NDEF invite URL from any NFC tag and auto-joins
- **NFC write** — "Write to NFC Tag" button in the Invite sheet writes the `whistle://` invite URL to a blank NFC sticker; anyone can tap their phone to the sticker to join
- `InviteCode.asURL()` — wraps the base64 code in a `whistle://invite/` deep-link URL
- `InviteCode.from(url:)` — decodes an invite from a `whistle://` URL or raw base64 (backwards compatible)
- `NFCReadCoordinator` — `@StateObject` helper for NDEF tag reading
- `NFCWriteCoordinator` — `@StateObject` helper for writing NDEF URL records to NFC tags
- `QRScannerView` — AVCaptureSession-based QR scanner with scan-frame guide

### Changed
- **InviteShareView** — "Share" button now shares the `whistle://` URL (AirDrop auto-handles it); QR now encodes the URL; legacy raw code still shown for copy
- **JoinGroupView** — accepts `initialCode` param for deep-link/QR/NFC pre-fill; added QR scan and NFC read buttons

---

## [0.6.1] — 2026-03-17

### Added
- **Auto centre self on map** — map auto-centres on own pin when location first appears; "locate me" button (location arrow) in toolbar re-centres on self at any time
- **Next-update countdown** — own location pin shows "in X min" countdown to the next scheduled broadcast instead of "X ago"; other members' pins continue to show elapsed time

---

## [0.6.0] — 2026-03-17

### Added
- **Pending group join state** — after accepting an invite, a "Pending" row appears in the group list until the Welcome event arrives; state persists across app restarts (`PendingInviteStore`, UserDefaults-backed)
- **Offline catch-up** — subscriptions now use a `since` filter based on the last processed event timestamp, so missed events are replayed when reconnecting after an offline period
- **Subscription retry loop** — if the Nostr notification stream drops (relay disconnect, network change), automatically reconnects and resumes subscriptions with backoff
- **MLS crash resilience** — `GroupHealthTracker` monitors consecutive processing failures per group; groups exceeding the threshold (5) show an "Out of sync" warning badge in the group list
- **Startup epoch cleanup** — `clearPendingCommit()` called for all groups on launch to recover from mid-commit crashes
- **Background location audit logging** — foreground/background mode logged on every location callback for debugging wake intervals
- **File sharing enabled** — app container visible in Finder/Files for MLS database inspection (temporary, until SQLCipher encryption is restored in v0.7)
- `GroupHealthTracker` — tracks consecutive MLS failures per group, resets on success
- `PendingInvite` model — Codable struct for pending group invites
- `PendingInviteStore` — UserDefaults-backed store with auto-cleanup on Welcome receipt
- 15 new unit tests for `PendingInviteStore` (8) and `GroupHealthTracker` (7)

### Changed
- **SettingsView polish** — Display Name label no longer wraps on narrow screens (`.lineLimit(1)`), Update Interval picker has clock icon, Authorization row has shield icon
- `MarmotService.startSubscriptions()` — refactored into retry loop with `openSubscriptionsAndListen()` inner method
- `MarmotService.handleGroupEvent()` — records success/failure in health tracker
- `MarmotService.handleIncomingEvent()` — updates `lastEventTimestamp` high-water mark on success
- `GroupListViewModel` — receives `PendingInviteStore` and `GroupHealthTracker`, forwards their changes
- `GroupRowView` — shows "Out of sync" badge for unhealthy groups
- `AppViewModel` — owns `PendingInviteStore`, wires to MarmotService, cleans up resolved invites on startup
- Version bumped to 0.6.0

---

## [0.5.1] — 2026-03-16

### Added
- Display name auto-broadcast — nicknames sent to all groups on app launch, name change, group create, and group join
- `NicknameStore` seeded with own display name at startup
- `ChatViewModel` and `GroupDetailViewModel` reactively re-resolve display names when `NicknameStore` updates
- `MarmotService.lastJoinedGroupId` publisher for post-welcome nickname broadcast
- "Allow Always for Background Sharing" button in Settings when location is only "When In Use"
- 10-second location interval option for live debugging
- Own location now appears on the map immediately (self-cached before relay round-trip)

### Changed
- "Enable Location" button now requests "Always" authorization (needed for background location sharing)
- `AppViewModel` forwards `objectWillChange` from child ObservableObjects (`settings`, `locationService`, `relay`) so SettingsView re-renders when nested @Published properties change

### Fixed
- Display names not shown — only hex pubkey was visible because nicknames were never written to NicknameStore or broadcast to groups
- MDK "group not found" errors flooding console — demoted to debug (kind-445 subscription is relay-wide, so unknown group events are expected)
- **Groups lost on app relaunch** — rewrote `MLSService.initialise()` to never silently delete the database; removed the "last resort delete-and-recreate" path that was destroying group data
- **Groups empty on app relaunch** — moved `GroupListViewModel` ownership from inline SwiftUI construction (vulnerable to view identity resets) to `AppViewModel`; `refreshGroups()` now runs before `self.marmot` is published to the UI so groups are loaded before the chat tab renders
- **Zero location events** — `LocationService.startUpdating()` called CLLocationManager with `.notDetermined` authorization which silently does nothing on iOS 17+; now guards on authorization status and defers via `wantsUpdating` flag
- **Location callback nil (hasCallback=false)** — race condition where CLLocationManager delegate fires via Task after LocationService.init(), triggering `applyLocationPauseSetting()` before `onAppear()` wires the pipeline callback; now defers `startUpdating()` until pipeline is ready
- **Own location missing from map** — `broadcastLocation()` only sent to relay; relays don't echo back own events so own pin never appeared; now inserts into `LocationCache` immediately
- **SettingsView not reacting to changes** — nested ObservableObject problem: SwiftUI only observes AppViewModel's own @Published, not child objects; fixed by forwarding `objectWillChange` from settings, locationService, and relay
- **Location auth delegate auto-start** — `locationManagerDidChangeAuthorization` now checks `wantsUpdating` and `isUpdating` to auto-start deferred location updates when permission is granted
- **Location pipeline never wired** — `startSubscriptions()` calls NostrSDK `handleNotifications()` which runs an infinite event loop; everything after it in `onAppear()` was dead code (location wiring, nickname broadcast). Moved subscriptions to last step
- Chat messages displayed newest-first — reversed to natural chat order (oldest top, newest bottom) with `.defaultScrollAnchor(.bottom)`
- GroupDetailView stuck after adding a member — now auto-dismisses back to chat on success
- Update interval observer race — Combine subscriptions moved from async `onAppear()` to `init()`
- Throttle timer resets on interval change so shorter intervals take effect immediately
- Version bumped to 0.5.1

---

## [0.5.0] — 2026-03-16

### Added
- **Group chat** — end-to-end encrypted messaging via MLS
- `GroupListView` — Chat tab root showing group list with Create / Join actions
- `GroupChatView` — chat thread with message bubbles and send bar
- `ChatBubbleView` — right-aligned blue (me) / left-aligned grey (others) message bubbles
- `GroupRowView` — group list row with name, member count, last activity
- `CreateGroupView` — sheet for creating new groups
- `JoinGroupView` — sheet for joining groups via invite code
- `InviteShareView` — QR code + copy/share for invite codes
- `GroupDetailView` — member list, invite generation, admin member removal
- `ChatViewModel` — loads messages from MDK, observes incoming, sends via MarmotService
- `GroupListViewModel` — drives group list, create/join actions
- `GroupDetailViewModel` — member management, invite generation
- `ChatPayload` / `NicknamePayload` — Codable JSON schemas for chat and nickname messages
- `NicknameStore` — UserDefaults-backed pubkey → display name mapping
- Display Name field in Settings (broadcasts as nickname to groups)
- "Enable Location" button in Settings (fixes iOS permission prompt issue)
- Group picker in Map toolbar — filter pins by group
- `FMFLogger.chat` log category
- `NSCameraUsageDescription` for QR scanning
- 15 new unit tests for ChatPayload, NicknamePayload, NicknameStore, and MarmotService

### Changed
- `MarmotService` — routes chat/nickname sub-types, `lastChatMessageGroupId`, `activeRelayURLs`, `sendNicknameUpdate`
- `LocationViewModel` — `selectedGroupId` filter, NicknameStore integration for display names
- `AppViewModel` — wires NicknameStore, observes interval changes, `myPubkeyHex`
- `FamilyMapView` — group picker toolbar menu
- `RootView` — `GroupListView` replaces `ChatPlaceholderView`
- `SettingsView` — display name, location enable button, version 0.5.0
- Version bumped to 0.5.0

### Fixed
- Location authorisation prompt never appeared (was called too early in lifecycle)
- Update interval selector had no effect (interval changes now forwarded to LocationService)
- Update interval observer race — Combine subscriptions moved from async `onAppear()` to `init()` so they're active immediately
- Throttle timer resets on interval change so shorter intervals take effect without waiting
- Groups disappear on app restart — `refreshGroups()` now called on startup to reload from MDK database
- Chat tab stuck on "Connecting…" spinner — `marmot` property marked `@Published` for SwiftUI reactivity
- MLSService init failures on iOS 26 — 3-step recovery: keyring → local key → delete stale DB + fresh key
- Keychain unavailable on iOS 26 — UserDefaults fallback for identity persistence
- Noisy "MLSError.notInitialised" log spam — demoted to debug, subscriptions gated on MLS readiness
- Invite/join flow — admins can now add members by pasting npub/hex pubkey in Group Detail

---

## [0.4.0] — 2026-03-16

### Added
- **Live family map** — `FamilyMapView` with iOS 17 `Map { }` API replaces placeholder
- `LocationService` — CoreLocation wrapper with throttling and background-mode support
- `LocationCache` — in-memory cache of latest location per group member
- `LocationViewModel` — transforms cache entries into map annotations with stale detection
- `LocationPayload` — Codable model for location JSON payloads inside MLS messages
- `MemberLocation` — per-member location model with coordinate, stale check, display name
- `MemberPinView` — custom map annotation (blue = fresh, grey = stale)
- `MarmotService.sendLocationUpdate` — encode and send location as kind-1 application message
- `MarmotService.routeApplicationMessage` — decode incoming location messages to `LocationCache`
- Location section in Settings: pause toggle, interval picker (5m/15m/30m/1h), auth status
- 17 new unit tests for LocationPayload, LocationCache, and MarmotService location features

### Changed
- `MarmotService.sendMessage` now accepts explicit `kind` parameter (default: chat)
- `handleGroupEvent` routes application messages through `routeApplicationMessage`
- `AppViewModel` creates and wires `LocationService`, `LocationCache`, `LocationViewModel`
- `RootView` uses `FamilyMapView` instead of `MapPlaceholderView`
- Version bumped to 0.4.0

---

## [0.3.0] — 2026-03-16

### Added
- `MarmotService` orchestration layer bridging MLSService (MLS) ↔ RelayService (Nostr)
- Kind 443 — Key Package publishing and fetching
- Kind 10051 — Key Package Relay List publishing and fetching
- Kind 444 — Welcome delivery via NIP-59 gift-wrap
- Kind 445 — Group event publishing, message encryption/sending
- `RelayServiceProtocol` abstraction for testable relay I/O
- `MockRelayService` in-memory mock for unit tests
- `NotificationHandler` — relay subscription callback bridge
- `InviteCode` model — base64-encoded invite tokens for group sharing
- Subscription management — auto-subscribes to group events and gift-wraps
- Invite flow — `generateInviteCode` / `acceptInvite`
- 19 new unit tests for MarmotService, InviteCode, and integration
- `RelayService` extended with `sendEvent`, `fetchEvents`, `subscribe`, `handleNotifications`, `giftWrap`, `unwrapGiftWrap`
- `FMFLogger.marmot` logger category
- `MarmotKind.giftWrap` (1059) constant

### Changed
- `AppViewModel` now creates and wires up `MarmotService` on startup
- Version bumped to 0.3.0

---

## [0.2.0] — 2026-03-16

### Added
- `MLSService` actor wrapping mdk-swift (Marmot Dev Kit) for MLS group operations
- `MLSModels` — convenience types, Marmot event kind constants, sort order helpers
- `mdk-swift` SPM dependency pinned to commit `80eab77`
- 18 new unit tests covering key packages, group lifecycle, messaging, and self-update

### Changed
- `project.yml` — added `MDKBindings` package
- Renamed app to **Famstr** (display name, permissions, docs)
- Bundle ID changed from `com.findmyfam` to `org.findmyfam`
- Version bumped to 0.2.0

### Fixed
- Asset catalog not compiled into app bundle (moved `.xcassets` to `sources` in XcodeGen)
- Added explicit XcodeGen scheme with test action
- Set `DEVELOPMENT_TEAM` for device builds
- Added Famstr app icon (1024×1024)

---

## [0.1.0] — 2026-03-16

### Added
- XcodeGen project skeleton (`project.yml`), `scripts/build.sh`
- Nostr identity generation and Keychain persistence (`IdentityService`, `KeychainService`)
- `SecureStorage` protocol with `InMemorySecureStorage` for testability
- Relay connectivity with configurable relay list (`RelayService`, `RelayConfig`)
- `AppSettings` — UserDefaults-backed preferences (relays, location interval, pause toggle)
- UI shell: tab bar with Map, Chat, Settings placeholders
- Identity card with npub QR code display
- Settings view: identity, relays, connection status, about section
- `FMFLogger` — structured os.Logger categories
- `nostr-sdk-swift` 0.44.2 as SPM dependency
- 20 unit tests covering identity, relay config, and keychain abstraction
