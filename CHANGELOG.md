# Changelog

All notable changes to Famstr will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
