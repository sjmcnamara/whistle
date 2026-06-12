# CLAUDE.md — Whistle project notes for AI agents

## What this project is

Whistle is an open-source, decentralised family location app built on Nostr + MLS (RFC 9420) via the [Marmot Protocol](https://github.com/marmot-protocol/marmot). No accounts, no servers, no plaintext data on relays. iOS (Swift/SwiftUI) and Android (Kotlin/Compose) share the same MDK (Rust via UniFFI) and NostrSDK.

## Build

```bash
./scripts/build.sh          # generate project + build (simulator)
./scripts/build.sh test     # generate + build + test
./scripts/build.sh clean    # xcodebuild clean + wipe DerivedData
```

Requires XcodeGen (`brew install xcodegen`). The script auto-detects the newest available iPhone simulator and handles the mdk-swift vendor clone automatically.

**Intel Mac:** `./scripts/build.sh test` is not supported — mdk-swift only ships arm64 slices and building x86_64-apple-ios requires the full Rust toolchain. Use CI for the test suite; local `./scripts/build.sh` (build only) works fine for development.

For Android: `cd android && ./gradlew assembleDebug` / `./gradlew test`.

## Version bumping

**iOS**: edit `project.yml` — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (build number). Then add a CHANGELOG entry and update the README status line.

**Android**: `android/app/build.gradle.kts` — `versionName` and `versionCode`.

Both platforms share `CHANGELOG.md` and `ROADMAP.md`.

## Cutting an Android release

Tagging `vX.Y.Z` and pushing the tag triggers `.github/workflows/release-android.yml`, which builds a signed APK and creates the GitHub release.

```bash
git tag v1.2.0
git push origin v1.2.0
```

The workflow expects four repo secrets:

- `ANDROID_KEYSTORE_B64` — base64 of `whistle-release.jks` (`base64 -i whistle-release.jks | pbcopy` on macOS)
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS` — e.g. `whistle-release`
- `ANDROID_KEY_PASSWORD` — usually the same as the keystore password

The release attaches both a versioned APK (`whistle-vX.Y.Z.apk`) and a stable `whistle.apk` so `releases/latest/download/whistle.apk` always points at the most recent build. The keystore is generational — if lost, existing Android installs can never be updated.

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
WhistleTests/    Unit tests (iOS)
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

Currently pinned to `revision: 8a7a0a59208e28f721a3abd16c9bd2c0d12af0be` (MDK 0.8.0). We previously tracked `branch: main` but upstream silently added a required `disappearingMessageSecs` parameter to `createGroup` and friends; the CI mdk-swift cache hid it until CodeQL (which fresh-clones) exposed the break. Bump the pin deliberately when adopting a newer MDK; switch to a tag once mdk-swift publishes one.

**Local development** — Xcode's embedded git does not smudge LFS objects during SPM package resolution, so the remote URL leaves `libmdk_uniffi.a` as an LFS pointer text file and the build fails with "unknown file type". `./scripts/build.sh` handles this automatically: it clones `vendor/mdk-swift` with the system git (LFS-aware) on first run, patches `project.yml`, runs xcodegen, then restores `project.yml` so the working tree stays clean.

`vendor/` is gitignored. CI does the same thing. Re-run `./scripts/build.sh` after deleting `vendor/mdk-swift` or switching to a branch with a different MDK reference.

## Known test failures (pre-existing, not ours)

None currently known. All 253 tests should pass on simulator.

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

**All changes must go via a branch and PR — no direct commits to master, no exceptions.** This includes housekeeping, roadmap updates, changelog entries, and version bumps.

Branch naming: `feature/vX.Y-description`, `bugfix/vX.Y.Z`, `chore/description`. PR per branch → review → merge to master. ROADMAP.md tracks branch history; update it when a branch merges.

## CHANGELOG format

Keep a Changelog style (`### Added / Changed / Fixed / Security / Improved`). New entry at the top of CHANGELOG.md. Lead with platform badge `(iOS)` / `(Android)` / `(iOS & Android)` when platform-specific. Match MARKETING_VERSION in `project.yml`.

## Roadmap

Current version: **v1.4.1 — Bugfixes** (shipped). See ROADMAP.md for next steps.
