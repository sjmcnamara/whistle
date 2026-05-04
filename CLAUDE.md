# CLAUDE.md — Whistle project notes for AI agents

## What this project is

Whistle is an open-source, decentralised family location app built on Nostr + MLS (RFC 9420) via the [Marmot Protocol](https://github.com/marmot-protocol/marmot). No accounts, no servers, no plaintext data on relays. iOS (Swift/SwiftUI) and Android (Kotlin/Compose) share the same MDK (Rust via UniFFI) and NostrSDK.

## Build

```bash
./scripts/build.sh          # generate project + build (simulator)
./scripts/build.sh test     # generate + build + test
./scripts/build.sh clean    # xcodebuild clean + wipe DerivedData
```

Requires XcodeGen (`brew install xcodegen`). The script auto-detects the newest available iPhone simulator.

For Android: `cd android && ./gradlew assembleDebug` / `./gradlew test`.

## Version bumping

**iOS**: edit `project.yml` — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number). Then add a CHANGELOG entry and update the README status line.

**Android**: `android/app/build.gradle.kts` — `versionName` and `versionCode`.

Both platforms share `CHANGELOG.md` and `ROADMAP.md`.

## Key architecture

```
Sources/
  App/           AppViewModel (root coordinator)
  Models/        Data types, payload schemas
  Services/      MLSService · MarmotService · RelayService · IdentityService
                 LocationService · LocationCache
                 SecureEnclaveService · EncryptedSecureStorage · KeychainService
  ViewModels/    One per screen
  Views/         SwiftUI views
WhistleCore/     Shared Swift package — AppDefaults, InviteCode, protocol constants
WhistleTests/    Unit tests (242 tests as of v1.1.3)
android/         Kotlin/Compose parity implementation
```

## MDK (Marmot Dev Kit) dependency

`MDKBindings` is the UniFFI-generated Swift wrapper around the Rust MDK library.

**Normal state**: `project.yml` references the remote mdk-swift repo at a pinned commit:
```yaml
MDKBindings:
  url: https://github.com/marmot-protocol/mdk-swift
  revision: <commit>
```

Currently pinned to MDK 0.8.0 (`f40174590f0949d7f5d4debc4814ba23af846ea9`).

**Local development state** (only when testing unreleased MDK changes): point at a local clone:
```yaml
MDKBindings:
  path: ../mdk-swift/crates/mdk-uniffi/src/swift
```

**When switching back to remote**: restore the `url`/`revision` form and delete the `path` line. Commit `project.yml` only when pointing to a published remote revision.

## Known test failures (pre-existing, not ours)

None currently known. All suites should pass on simulator.

## MLS database

- File: `whistle.db` in the app's Library/Application Support directory (iOS) / filesDir (Android)
- Encrypted with SQLCipher via MDK's `newMdk()`. Encryption key managed by `keyring-core` (iOS Keychain / Android Keystore).
- `newMdkUnencrypted` no longer exists in MDK v0.7.1+. Tests use `newMdkWithKey(dbPath: ":memory:", encryptionKey: Data(count: 32))`.
- On first launch after upgrade from pre-v0.9: stale unencrypted DB detected, deleted, fresh encrypted DB created.

To verify encryption on-device:
```bash
sqlite3 /path/to/whistle.db "PRAGMA integrity_check;"
# Should return: Parse error: file is not a database
```

## Marmot Protocol PRs we've opened

- **marmot-protocol/mdk#252** — `feat(uniffi): auto-init platform keyring store in new_mdk()`. **Merged in MDK 0.8.0.** ✓

## Branch strategy

`feature/vX.Y-description` off master. PR per feature → merge to master. Patch releases use `bugfix/vX.Y.Z`. ROADMAP.md tracks branch history. Update ROADMAP.md when a feature branch merges.

## CHANGELOG format

Keep a Changelog style (`### Added / Changed / Fixed / Security / Improved`). New entry at the top of CHANGELOG.md. Lead with platform badge `(iOS)` / `(Android)` / `(iOS & Android)` when platform-specific. Match MARKETING_VERSION in `project.yml`.

## Roadmap

Next planned: **v1.1.4 — Smart Location Intervals** (parked). See ROADMAP.md.
