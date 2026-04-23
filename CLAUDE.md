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

**Normal state (CI / other devs)**: `project.yml` references the remote mdk-swift repo at a pinned commit:
```yaml
MDKBindings:
  url: https://github.com/marmot-protocol/mdk-swift
  revision: <commit>
```

**Local development state** (current working state): pointing at a local clone to test unreleased changes:
```yaml
MDKBindings:
  path: ../mdk-swift/crates/mdk-uniffi/src/swift
```

The local clone lives at `../mdk-swift` (sibling directory). Branch `testing-hardening` tracks `maintainer/codex/sqlcipher-pr252-hardening`.

**When switching back to remote**: restore the `url`/`revision` form and delete the `path` line. Commit `project.yml` only when pointing to a published remote revision.

### Building the xcframework locally (Intel Mac)

The upstream mdk-swift xcframework only ships arm64 slices. On Intel Mac, build x86_64-sim and create a fat library:

```bash
cd ../mdk-swift
IPHONEOS_DEPLOYMENT_TARGET=15.0 cargo build --release --lib -p mdk-uniffi --target x86_64-apple-ios

XFWK=crates/mdk-uniffi/src/swift/Binary/mdk_uniffi.xcframework
lipo -create \
  "$XFWK/ios-arm64-simulator/libmdk_uniffi.a" \
  target/x86_64-apple-ios/release/libmdk_uniffi.a \
  -output /tmp/libmdk_uniffi_sim_fat.a

rm -rf "$XFWK"
xcodebuild -create-xcframework \
  -library "$XFWK/../../../../../../../MDK.xcframework/ios-arm64/libmdk_uniffi.a" \  # or existing arm64 slice
  -headers <headers-dir> \
  -library /tmp/libmdk_uniffi_sim_fat.a -headers <headers-dir> \
  -output "$XFWK"
```

Simpler: use the recipe in `../mdk-swift/justfile` (`just gen-binding-swift`) — but it only builds arm64 targets; the x86_64-apple-ios target must be added manually for Intel Mac.

## Known test failures (pre-existing, not ours)

`SecureEnclaveServiceTests` — 3 tests fail on iOS 26 simulator because Apple added Secure Enclave availability to the simulator. Tests assert `isAvailable == false`; simulator now returns `true`. Affects:
- `testSecureEnclaveIsAvailableReturnsBool`
- `testEncryptThrowsWhenSEUnavailable`
- `testDecryptThrowsWhenSEUnavailable`

Cascade: `IdentityServiceTests` and `EncryptedSecureStorageTests` also fail (20 additional failures) because `EncryptedSecureStorage` takes the SE path on a simulator that reports SE available, but SE operations aren't fully functional there.

**Total pre-existing failures on simulator: 23 out of 242.** All MLS/protocol suites pass.

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

- **marmot-protocol/mdk#252** — `feat(uniffi): auto-init platform keyring store in new_mdk()`. Still open; a contributor's improvement was merged on the `codex/sqlcipher-pr252-hardening` branch in mdk-swift instead. Our PR can be closed when the upstream mdk-swift publishes a new release incorporating this.

## Branch strategy

`feature/vX.Y-description` off master. PR per feature → merge to master. Patch releases use `bugfix/vX.Y.Z`. ROADMAP.md tracks branch history. Update ROADMAP.md when a feature branch merges.

## CHANGELOG format

Keep a Changelog style (`### Added / Changed / Fixed / Security / Improved`). New entry at the top of CHANGELOG.md. Lead with platform badge `(iOS)` / `(Android)` / `(iOS & Android)` when platform-specific. Match MARKETING_VERSION in `project.yml`.

## Roadmap

Next planned: **v1.1.4 — Smart Location Intervals** (parked). See ROADMAP.md.
