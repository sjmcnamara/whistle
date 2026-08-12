# CLAUDE.md — Whistle project notes for AI agents

## What this project is

Whistle is an open-source, decentralised group location sharing app built on Nostr + MLS (RFC 9420) via the [Marmot Protocol](https://github.com/marmot-protocol/marmot). No accounts, no servers, no plaintext data on relays. iOS (Swift/SwiftUI) and Android (Kotlin/Compose) share the same MDK (Rust via UniFFI) and NostrSDK.

## Build

```bash
./scripts/build.sh               # generate project + build (simulator)
./scripts/build.sh compile-tests # type-check the test target without running it
./scripts/build.sh test          # generate + build + test
./scripts/build.sh clean         # xcodebuild clean + wipe DerivedData
```

Requires XcodeGen (`brew install xcodegen`). The script auto-detects the newest available iPhone simulator and handles the mdk-swift vendor clone automatically.

**Intel Mac:** `./scripts/build.sh test` is not supported — mdk-swift only ships arm64 slices and building x86_64-apple-ios requires the full Rust toolchain. Use CI to *run* the suite.

**Always run `./scripts/build.sh compile-tests` before pushing.** Plain `build.sh` only builds the app target, so `WhistleTests` can stop compiling while the build still passes — and that surfaces as a red CI run rather than a local error. `compile-tests` builds the test target for a generic arm64 device, which works on Intel Macs even though running it does not. It catches signature changes that break test call sites (a service turning `async`, a model gaining a field).

For Android: `cd android && ./gradlew assembleDebug` / `./gradlew test`.

## Version bumping

Edit **every** item in this list — it is the complete set, and a partial bump ships an inconsistent release:

1. `project.yml` — `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (iOS build number)
2. `android/app/build.gradle.kts` — `versionName` and `versionCode`
3. `CHANGELOG.md` — new entry at the top, matching `MARKETING_VERSION`
4. `README.md` — the status line
5. `ROADMAP.md` — release entry

The **website version is automatic** — do not hand-edit it. `website/overrides/home.html` renders `{{ config.extra.app_version }}`, which `.github/workflows/docs.yml` injects from `project.yml`'s `MARKETING_VERSION` at build time; `project.yml` is in that workflow's `paths` trigger so a bump redeploys the site on its own. The site's Android APK link points at `releases/latest/download/whistle.apk` and likewise needs no edit. (Both used to be hand-maintained and were repeatedly missed — that is why they are generated now.)

Releasing is a separate step from bumping: merging does not publish. See the `android-release` skill for tagging.

## MDK (Marmot Dev Kit) dependency

`MDKBindings` is the UniFFI-generated Swift wrapper around the Rust MDK library.

**Normal state**: `project.yml` references the remote mdk-swift repo at a pinned commit:
```yaml
MDKBindings:
  url: https://github.com/marmot-protocol/mdk-swift
  revision: <commit>
```

Currently pinned to `revision: 8a7a0a59208e28f721a3abd16c9bd2c0d12af0be` (MDK 0.8.0). We previously tracked `branch: main` but upstream silently added a required `disappearingMessageSecs` parameter to `createGroup` and friends; the CI mdk-swift cache hid it until CodeQL (which fresh-clones) exposed the break. Bump the pin deliberately when adopting a newer MDK; switch to a tag once mdk-swift publishes one.

**mdk-swift is archived (2026-08-05) — the pin still resolves, but there will never be another commit to that repo.** The archive banner points at `marmot-protocol/mdk`'s own generated bindings ("MarmotKit") instead, but as of v0.9.11 those only expose the account/chat layer (`account`, `chat_list`, `directory`, `draft`, `group`, `media`, `message`, `notification`, `push`, `relay`, `subscription`, `timeline`) — the low-level MLS primitives we call (`processMessage`, `selfUpdate`, `addMembers`) aren't exposed anywhere in `marmot-uniffi`. Per Erskine Gardner (mdk#938, 2026-08-12): **0.8 / protocol v1 is now deprecated** — 0.9.0+ runs Marmot protocol v2, which is not wire-compatible with v1. Low-level bindings for non-chat payloads (our exact use case) aren't designed yet; he's weighing whether they land as additions to `marmot-uniffi` or a separate low-level package, and hasn't committed to a shape or timeline.

**Stay pinned to 0.8.0 for now — we are not asking upstream to keep 0.8/v1 supported.** MDK is pre-1.0 and WIP, so chasing backward compatibility isn't the goal; we're waiting on a concrete direction for how non-chat apps (our own payload over MLS application messages, not text/chat) should use MLS/MDK's security properties on v2. Do **not** chase `main` or hand-roll FFI over the `cgka-*` crates in the meantime — wait for Jeff to propose something. Tracking issue: https://github.com/marmot-protocol/mdk/issues/938

**Local development** — Xcode's embedded git does not smudge LFS objects during SPM package resolution, so the remote URL leaves `libmdk_uniffi.a` as an LFS pointer text file and the build fails with "unknown file type". `./scripts/build.sh` handles this automatically: it clones `vendor/mdk-swift` with the system git (LFS-aware) on first run, patches `project.yml`, runs xcodegen, then restores `project.yml` so the working tree stays clean.

`vendor/` is gitignored. CI does the same thing. Re-run `./scripts/build.sh` after deleting `vendor/mdk-swift` or switching to a branch with a different MDK reference.

## NostrSDK dependency

`NostrSDK` is pinned with `exactVersion` in `project.yml`, not a floating `from:` range. It was `from: "0.44.2"` until 2026-08-06, when upstream's 0.45.0 release (published 2026-08-05) shipped a UniFFI-generated header with a C function parameter literally named `unsigned` (`uniffi_nostr_sdk_ffi_fn_method_*pow*_compute*`), which Clang rejects with `'type-name' cannot be signed or unsigned`. Nothing in our repo changed — SPM silently picked up the new minor version and CodeQL's fresh clone (no resolved-package cache) was the first build to hit it, same failure mode as the MDK `branch: main` incident above. Pinned back to `exactVersion: "0.44.8"` (last known-good). Bump the pin deliberately, and check upstream's generated header for reserved-word parameter names (`unsigned`, `id`, `new`, etc.) before doing so.

## Known test failures (pre-existing, not ours)

None currently known. All 449 iOS tests should pass on simulator.

Note: the avatar `downscaled` helpers (`MemberAvatarStore`, `LocalGroupAvatarStore`) render at `format.scale = 1` so output is exactly `targetEdge` pixels. Before v1.8.1 they produced `targetEdge × screen-scale` pixels (e.g. 384px on a @3x device for a 128pt target), which made `MemberAvatarStoreTests.testEncodeDownscalesToTargetEdge` fail on any @2x/@3x simulator. If it regresses, check the renderer scale.

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

Current version: **v1.8.6 — Duplicate self-pin on the multi-group map** (bugfix). See ROADMAP.md for next steps.
