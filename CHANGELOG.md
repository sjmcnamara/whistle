# Changelog

All notable changes to Famstr will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
