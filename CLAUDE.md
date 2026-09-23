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

Releasing is a separate step from bumping: merging does not publish. See the `android-release` skill for tagging Android, and the `ios-release` skill for tagging iOS (archive + export + TestFlight upload is automated via `release-ios.yml`; submitting the TestFlight build for App Store review stays a manual step).

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

**Superseded 2026-09-23 — see the MDK 2.0 / MarmotKit migration section below.** The "wait for a concrete direction" premise above is stale: MarmotKit `marmotkit-v0.10.4` (tagged 2026-09-20) ships a full domain-level API (`invite_members`, `send_custom_event`, `subscribe_messages`, admin/relay/recovery calls) covering our non-chat use case, confirmed directly with upstream on mdk#938. We are actively spiking the migration on `feature/v2.0-marmotkit-spike`, not waiting. This section (0.8.0 pin mechanics) stays accurate for as long as `MDKBindings`/mdk-swift itself stays wired into the shipping app — that doesn't change until the `MarmotService` rewrite (migration step 3) actually lands.

**Local development** — Xcode's embedded git does not smudge LFS objects during SPM package resolution, so the remote URL leaves `libmdk_uniffi.a` as an LFS pointer text file and the build fails with "unknown file type". `./scripts/build.sh` handles this automatically: it clones `vendor/mdk-swift` with the system git (LFS-aware) on first run, patches `project.yml`, runs xcodegen, then restores `project.yml` so the working tree stays clean.

`vendor/` is gitignored. CI does the same thing. Re-run `./scripts/build.sh` after deleting `vendor/mdk-swift` or switching to a branch with a different MDK reference.

## MDK 2.0 / MarmotKit migration (spike in progress)

Branch `feature/v2.0-marmotkit-spike` — see ROADMAP.md's "Deferred" section for the full plan and sequencing. Status and hard-won facts, so the next session doesn't re-derive them:

- **MarmotKit has no git-hosted SPM package.** GitHub-wide search for a repo named "MarmotKit" returns nothing — it's GitHub Release assets (`MarmotKitFFI-<version>.xcframework.zip`, `MarmotKit-<version>.swift`, `PrivacyInfo-ios-<version>.xcprivacy`) published from inside `marmot-protocol/mdk`, tagged `marmotkit-v<version>`. Consumers hand-author the wrapper `Package.swift` themselves, per `crates/marmot-uniffi/DISTRIBUTION.md` upstream. `MarmotKitBindings/` in this repo is that hand-authored wrapper.
- **MarmotKitFFI requires iOS 18.0+** (DISTRIBUTION.md's SwiftPM section). This is why `project.yml`'s `deploymentTarget` moved from 17.0 to 18.0 on this branch — that's a real, immediate drop of iOS 17 device support once `MarmotKitBindings` reaches the shipping `Whistle` target (currently it's wired into `WhistleTests` only, not the app target, so production users aren't affected yet).
- **The XCFramework's own `Headers/module.modulemap` collides with NostrSDK's `nostr_sdkFFI.xcframework`** — both are "raw static-library slice" XCFrameworks (Apple's newer format, no `.framework` bundle) with a bare, identically-named `module.modulemap`. Xcode's build engine stages every such XCFramework's headers into one *shared* per-build `include/` directory rather than one per framework, so two of them collide with "Multiple commands produce ... include/module.modulemap". Known, unresolved upstream bug: https://github.com/swiftlang/swift-build/issues/1746. Renaming or nesting the modulemap file only trades that error for a silent one (Clang's module-map auto-discovery doesn't recurse into subdirectories or look for non-default names, so `#if canImport(marmot_uniffiFFI)` in the generated bindings just skips the import with zero diagnostic, cascading into hundreds of unrelated "cannot find X in scope" errors).
  - **The actual fix — proven, because `MDKBindings`/mdk-swift already does it**: `vendor/mdk-swift/Package.swift` never lets Xcode discover `mdk_uniffi.xcframework`'s own headers as a module at all — that xcframework ships no modulemap, just a bare header, and the real Swift-imported module (`mdk_uniffiFFI`) is an ordinary SPM target (`Sources/mdk_uniffiFFI`, `publicHeadersPath: "include"`) that depends on the binaryTarget only for the compiled `.a`. Ordinary SPM targets compile their headers through Xcode's normal per-target path, never the shared XCFramework bucket, so they never collide. `MarmotKitBindings/Package.swift` mirrors this exactly via its own `marmot_uniffiFFI` target; `scripts/vendor_marmotkit.py` strips `module.modulemap` out of the vendored XCFramework copy to match (see that script's header comment for the full account of what didn't work first).
  - `scripts/vendor_marmotkit.py` + `build.sh`'s `ensure_local_marmotkit()`/`restore_marmotkit_changes()` mirror `ci_use_local_mdk.py`'s vendor/patch/restore pattern for `project.yml` — but with one critical difference: `restore_marmotkit_changes()` must run **after** the `xcodebuild` invocation, not right after `xcodegen generate` like `project.yml`'s restore does. `project.yml`'s content stops mattering once xcodegen bakes it into the `.xcodeproj`; `MarmotKitBindings/Package.swift`'s content is read live by SwiftPM during xcodebuild's own package resolution, so restoring it early silently un-does the local patch before it's ever used.
- **`mdk#1990`** (opened 2026-09-23, unresolved) — MarmotKit 0.10.4's Android `.so` has 4KB ELF load-segment alignment, failing Google Play's 16KB page-size check (Play currently permits it; Android 15+ updates must comply from 2027-02-01). Discovered via White Noise Android hitting a real Play Store warning. Doesn't block the iOS spike; relevant when migration step 5 (Android port) starts.
- **Verified as of this spike**: `MarmotKitBindings` wired into `WhistleTests` only (not the app target) resolves and compiles cleanly (`./scripts/build.sh compile-tests`), and the full existing suite (477 tests) still passes with zero regressions. A gated round-trip test (`WhistleTests/MarmotKitSpikeTests.swift`, `MARMOTKIT_SPIKE_LIVE_RELAY` env var, skipped by default) proves the real generated API's call shapes against `crates/marmot-uniffi/API-REFERENCE.md` — but hasn't yet been run to a real pass: setting that env var on the `xcodebuild test` invocation didn't propagate into the simulator-hosted test process's own environment. Unresolved, next-session follow-up, not investigated further this session.
- **Step 2 (kind mapping) resolved.** MDK's reserved inner-kind check is purely kind-value-based (`RESERVED_APP_EVENT_KINDS.contains(&kind)` in `crates/marmot-app/src/messages/intents.rs`'s `validate_custom_event_kind`, called unconditionally from `send_custom_event` — no call-path exception), against constants defined once in `crates/traits` and `crates/marmot-app` (shared by every binding, iOS and Android alike):

  | Name | Kind | Name | Kind |
  |---|---|---|---|
  | DELETE | 5 | AGENT_STREAM_START | 1200 |
  | REACTION | 7 | AGENT_ACTIVITY | 1201 |
  | **CHAT** | **9** | AGENT_OPERATION | 1202 |
  | PUSH_TOKEN_UPDATE | 447 | GROUP_SYSTEM | 1210 |
  | PUSH_TOKEN_LIST | 448 | REPORT | 1984 |
  | PUSH_TOKEN_REMOVAL | 449 | REVIEW | 1985 |
  | EDIT | 1009 | REMOVE | 4891 |
  | POLL_RESPONSE | 1018 | POLL | 1068 |

  Whistle's own `chat = 9` (`WhistleCore/Sources/WhistleCore/MarmotKind.swift`) collides directly with MDK's own `CHAT = 9` — `send_custom_event(kind: 9, ...)` will be rejected outright once we're actually calling it. `location = 1` and `leaveRequest = 2` are clear of every value above. **Target v2.0 numbering: `chat` renumbered to `3`.** Not written into `MarmotKind.swift` yet — see ROADMAP.md's step 2 entry for why (that constant is live in the shipping 0.8 protocol; bumping it now, before the real cutover, would desync chat rendering between pre/post-update clients on existing groups for no reason connected to this migration). Apply the rename as part of step 3, alongside every other breaking change.

- **Not yet done**: `MarmotService` rewrite (step 3), invite/join UI (step 4), Android port (step 5).

## NostrSDK dependency

`NostrSDK` is pinned with `exactVersion` in `project.yml`, not a floating `from:` range. It was `from: "0.44.2"` until 2026-08-06, when upstream's 0.45.0 release (published 2026-08-05) shipped a UniFFI-generated header with a C function parameter literally named `unsigned` (`uniffi_nostr_sdk_ffi_fn_method_*pow*_compute*`), which Clang rejects with `'type-name' cannot be signed or unsigned`. Nothing in our repo changed — SPM silently picked up the new minor version and CodeQL's fresh clone (no resolved-package cache) was the first build to hit it, same failure mode as the MDK `branch: main` incident above. Pinned back to `exactVersion: "0.44.8"` (last known-good). Bump the pin deliberately, and check upstream's generated header for reserved-word parameter names (`unsigned`, `id`, `new`, etc.) before doing so.

## Zapstore publish (zsp CLI) dependency

`.github/workflows/zapstore-publish.yml` and `scripts/zapstore-publish.sh` install the `zsp` CLI with `go install`, pinned to `github.com/zapstore/zsp/cmd/zsp@v0.5.1` — not `@latest`. Upstream's `v0.5.0`/`v0.5.1` (published 2026-09-15) moved `main` out of the repo root into `cmd/zsp`, so `go install github.com/zapstore/zsp@latest` started failing with `package github.com/zapstore/zsp is not a main package` — a floating-version break, same failure mode as the MDK `branch: main` and NostrSDK `from:` incidents above. Bump the pin deliberately, and confirm the new tag's main package still lives at `cmd/zsp` (check the repo root for a top-level `main.go` vs. a `cmd/` dir) before doing so.

Same v0.5.x restructuring also renamed the `publish` subcommand's short flag: `-q` no longer exists, use `--quiet`. Run `zsp publish --help` after bumping the pin to check for other flag renames before assuming the invocation still works.

**`release_notes` in `zapstore.yaml` must not point at a multi-version file.** It was `./CHANGELOG.md` until the v1.10.0 publish showed "All notable changes to Whistle will be documented in this file." as the listing's release notes — `zsp`'s `loadReleaseNotes` (`media.go`) has no per-version extraction at all, it just dumps the target file's raw bytes verbatim as the changelog field. Removed the field entirely: with `release_notes` unset, `zsp` falls back to the GitHub Release's own body, which is already correct per-version since `release-android.yml` creates it with `--generate-notes`. To fix an already-published listing's metadata after the fact (same version code, corrected content), re-run the "Zapstore publish" workflow with its `overwrite_release` input set to true (or `./scripts/zapstore-publish.sh --overwrite` locally) — plain re-publish of an unchanged version code is otherwise rejected.

## Known test failures (pre-existing, not ours)

None currently known. All 468 iOS tests should pass on simulator.

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

Current version: **v1.11.2 — Relay-delivery-order commit buffering** (bugfix, iOS & Android). See ROADMAP.md for next steps.
