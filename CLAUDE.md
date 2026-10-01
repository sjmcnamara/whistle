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

**`./scripts/build.sh test` does NOT run WhistleCore's own test suite.** It builds the Xcode `WhistleTests` target; `WhistleCore` is a separate SPM package with its own tests, run by CI's "WhistleCore Tests" job. A green local `build.sh test` therefore says nothing about them — a change to `AppDefaults` passed 514 Xcode tests locally and went red in CI for the WhistleCore assertions on the same constant. Before pushing a change that touches `WhistleCore/`:

```bash
cd WhistleCore && swift test   # 78 tests, not covered by build.sh
```

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
- **MarmotKitFFI requires iOS 18.0+** (DISTRIBUTION.md's SwiftPM section), and since step 3d-iii-a put `MarmotKitBindings` in the **app** target, `project.yml`'s `options.deploymentTarget` is now 18.0 app-wide. That is a real drop of iOS 17 device support, taken deliberately as part of the one breaking release.
  - **Release-sequencing consequence, and it is easy to trip over**: the moment this branch merges to `master`, `master` is an iOS 18 app. A 1.x patch cut from `master` afterwards would silently drop iOS 17 for existing users. So either v2.0 ships from this line before any further 1.x release, or a 1.x patch is cut from the last 1.x tag rather than from `master`. The bump was held at test-target-only for exactly this reason until the app target genuinely needed it.
- **The XCFramework's own `Headers/module.modulemap` collides with NostrSDK's `nostr_sdkFFI.xcframework`** — both are "raw static-library slice" XCFrameworks (Apple's newer format, no `.framework` bundle) with a bare, identically-named `module.modulemap`. Xcode's build engine stages every such XCFramework's headers into one *shared* per-build `include/` directory rather than one per framework, so two of them collide with "Multiple commands produce ... include/module.modulemap". Known, unresolved upstream bug: https://github.com/swiftlang/swift-build/issues/1746. Renaming or nesting the modulemap file only trades that error for a silent one (Clang's module-map auto-discovery doesn't recurse into subdirectories or look for non-default names, so `#if canImport(marmot_uniffiFFI)` in the generated bindings just skips the import with zero diagnostic, cascading into hundreds of unrelated "cannot find X in scope" errors).
  - **The actual fix — proven, because `MDKBindings`/mdk-swift already does it**: `vendor/mdk-swift/Package.swift` never lets Xcode discover `mdk_uniffi.xcframework`'s own headers as a module at all — that xcframework ships no modulemap, just a bare header, and the real Swift-imported module (`mdk_uniffiFFI`) is an ordinary SPM target (`Sources/mdk_uniffiFFI`, `publicHeadersPath: "include"`) that depends on the binaryTarget only for the compiled `.a`. Ordinary SPM targets compile their headers through Xcode's normal per-target path, never the shared XCFramework bucket, so they never collide. `MarmotKitBindings/Package.swift` mirrors this exactly via its own `marmot_uniffiFFI` target; `scripts/vendor_marmotkit.py` strips `module.modulemap` out of the vendored XCFramework copy to match (see that script's header comment for the full account of what didn't work first).
  - `scripts/vendor_marmotkit.py` + `build.sh`'s `ensure_local_marmotkit()`/`restore_marmotkit_changes()` mirror `ci_use_local_mdk.py`'s vendor/patch/restore pattern for `project.yml` — but with one critical difference: `restore_marmotkit_changes()` must run **after** the `xcodebuild` invocation, not right after `xcodegen generate` like `project.yml`'s restore does. `project.yml`'s content stops mattering once xcodegen bakes it into the `.xcodeproj`; `MarmotKitBindings/Package.swift`'s content is read live by SwiftPM during xcodebuild's own package resolution, so restoring it early silently un-does the local patch before it's ever used.
- **`mdk#1990`** (opened 2026-09-23, unresolved) — MarmotKit 0.10.4's Android `.so` has 4KB ELF load-segment alignment. Discovered via White Noise Android hitting a Google Play warning, and **that is their distribution problem, not ours**: Whistle ships Android as a raw APK from the website (`releases/latest/download/whistle.apk`) and through Zapstore, never Play. So Play's policy gate and its 2027-02-01 deadline do not apply to us, and this is **not** a release blocker for the Android port.
  - Do not restate it as one. An earlier revision of these notes called step 5 "blocked upstream" on this issue — imported from the upstream framing without checking it against how this project actually distributes.
  - **What does still need checking**, before the port ships: how a 4KB-aligned `.so` behaves at *runtime* on a device configured for 16KB pages. [Likely] it fails to load rather than degrading, which would be a real compatibility limit for sideloaded APKs too — and GrapheneOS on recent Pixels, which is this project's most-reported platform, is exactly where 16KB page mode shows up. Verify on hardware or an emulator image in 16KB mode; don't assume either way from the Play warning, which proves only that Google's static check rejects the alignment.
- **Verified as of this spike**: `MarmotKitBindings` wired into `WhistleTests` only (not the app target) resolves and compiles cleanly (`./scripts/build.sh compile-tests`), and the full existing suite (477 tests) still passes with zero regressions. A gated round-trip test (`WhistleTests/MarmotKitSpikeTests.swift`, `MARMOTKIT_SPIKE_LIVE_RELAY` env var, skipped by default) proves the real generated API's call shapes against `crates/marmot-uniffi/API-REFERENCE.md` — but hasn't yet been run to a real pass: setting that env var on the `xcodebuild test` invocation didn't propagate into the simulator-hosted test process's own environment. Unresolved, next-session follow-up, not investigated further this session.
- **The vendoring must be wired into every CI workflow separately — `build.sh` is not the CI entry point.** The first CI run of this spike went red with the same `include/module.modulemap` collision even though it passed locally, because `ci.yml`, `codeql.yml` and `release-ios.yml` each replicate the mdk vendoring inline (`ci_use_local_mdk.py` + `xcodegen generate` + a direct `xcodebuild` call) and never invoke `./scripts/build.sh` — so `ensure_local_marmotkit()` never ran, `Package.swift` kept its committed remote URL, and SwiftPM fetched the pristine upstream XCFramework with its colliding modulemap. All three now call `scripts/vendor_marmotkit.py` before `xcodegen generate`. In CI nothing restores the patch afterwards, which is exactly what's needed (SwiftPM reads `Package.swift` live during `xcodebuild`'s resolution) — unlike locally, where `build.sh` must restore it after the build. `ci.yml`/`release-ios.yml` cache the 91MB zip, not the 347MB extracted tree (re-extracting costs seconds, and the script skips the download when the verified zip is present); `codeql.yml` is deliberately uncached, since its value is being the fresh-clone build that catches what a warm cache hides. `ci.yml`'s DerivedData cache key also now includes `MarmotKitBindings/**`, so a wrapper-package change can't be masked by a stale resolved-package cache.

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

- **Steps 3a–3c are done** (see ROADMAP.md for the full verdict table). Hard-won facts worth not rediscovering:

  - **MarmotKit exposes no injectable transport.** Its entire FFI surface has exactly two callback interfaces — `SecretStore` and `ExternalAccountSignerFfi` — and neither is a transport. Controlling what an instance receives means *being* the relay it dials; `RelayPolicyFfi.allowLoopback` is upstream's explicit opt-in for that. `WhistleTests/Support/LoopbackRelay.swift` is that relay, with replay-order control and hold/release live delivery.
  - **MarmotKit cannot reach the platform keychain from an XCTest bundle** — `KeystoreUnavailable: "A required entitlement isn't present."`, thrown *before any networking*. The symptom is a relay that accepts nothing and a test that burns its timeout, which is indistinguishable from a transport fault and cost two misdiagnoses. Tests inject `InMemorySecretStore` via `MarmotOptions.secretStore`. **In the app it works** — confirmed on device, identity created and cleanly removed.
  - **MarmotKit refuses "retired" relay hosts at the dial boundary**, failing identity creation outright rather than skipping them — and **`wss://relay.damus.io` is one of them** — verified on device: `relay.damus.io=retired`, `nos.lol=allowed`, `relay.primal.net=allowed`. It is the first entry in `AppDefaults.defaultRelays`, so the v2 default list must change. Use `classifyRelayEndpoints` / `retiredRelayHosts` to filter before handing any relay list over, including a user's saved Advanced Settings list.
  - **MarmotKit rejects any symlink in the root path it is given**, with `ELOOP` — `Io(details: "open complete authorized directory path at …: Too many levels of symbolic links (os error 62)")`. On iOS `/var` is a symlink to `/private/var`, and `FileManager.urls(for:in:)` returns the **unresolved** `/var/mobile/Containers/…` form, so passing it straight through fails startup outright. Call `resolvingSymlinksInPath()` — *after* creating the directory, since it only resolves components that exist.
    - The error names the **leaf** directory, which reads like the leaf is broken when the problem is the prefix. Cost a device build.
    - Nothing caught it earlier because every path that had ever been handed to MarmotKit came from `NSTemporaryDirectory()` (tests, and the on-device spike harness), which reports `/private/var/…` already resolved. The relay-policy probe in the same startup sequence succeeded for exactly that reason, which made it look like the runtime was fine and the directory was not.
    - **Use `realpath(3)` (`MarmotKitService.fullyResolved`), not `URL.resolvingSymlinksInPath()`.** The Foundation call is a trap here: it *does* resolve `/var` to `/private/var`, and then reading `.path` back off the result standardizes the `/private` prefix away again, handing back the original unresolved string. The round trip looks like a no-op, so the first attempt at this fix changed nothing and the device error returned byte-identical. `realpath` resolves every component and never re-standardizes. The path must exist first, so resolve *after* creating the directory.
    - `defaultRootPath()` logs the exact string it returns (`[marmot] MarmotKit root: …`). Without it, "same error" is ambiguous between "the fix didn't apply" and "the fix was wrong" — and the two were only distinguishable here because the app container UUID happened to change between runs.
    - A test asserting `resolvingSymlinksInPath().path == itself` is worthless — that identity is exactly what the bug satisfies, so it passed while the bug was live. The real test builds an actual symlink and asserts `realpath` sees through it.
    - The simulator container is under `/Users/…`, not a symlinked prefix, so **no simulator test can reproduce this**. It also confirms the space in `Application Support` is harmless: MarmotKit accepts that path there.
  - **`beginOnboarding` is only the first half of account setup, and onboarding blocks on caller input.** Measured, not inferred: after `beginOnboarding` all six steps (`profile`, `follows`, `relays`, `inboxRelays`, `singleDevice`, `keyPackage`) are `pending` and readiness is `initializing`. One `runOnboarding` moves `profile` to `needsInput` and **every later step stays `pending` behind it** — the machine is sequential, so `runOnboarding` alone can never finish. Until it does, anything needing a published account fails with `OnboardingRequired` (this broke "my member code" on device).
    - `MarmotKitService.completeAccountSetup()` is the driver: loop `runOnboarding`, resolve the first step reporting `needsInput`/`retryableFailure` using the actions *that step offers*, stop when `ready` or when a pass changes nothing. For Whistle, `profile` and `follows` take `continueOnboardingWithout` — display names and avatars travel inside the group as MLS payloads, so a kind-0 profile and a follow list are out of scope, not merely optional. Never `cancelOnboarding`: it discards the account.
    - `MarmotKitService.onboardingDiagnostics()` dumps the step/status/actions table, with each finding's `issue` and `endpoint`; `relayDiagnostics()` dumps `relayHealth()` counters. Both are logged on every launch, success or failure. Use them *first* when setup will not complete — guessing from the error string cost several cycles here, and one of those cycles was spent on "no relay connectivity" that the counters later showed was never real (`connected=2 successes=2`, lists `complete: true`).
    - **`snapshot.proposal != nil` means the machine is waiting on consent, and it reduces the blocking step's actions to `[approveRepair, cancelRepair, cancelOnboarding]`.** This is the normal path, not an error: `setAccountInboxRelays` publishes the list correctly (kind 10050 appears, `complete: true`) and *then* a proposal is raised to reconcile it. `approveRepair` must be tried before any step-specific strategy, or the loop exhausts itself while the machine sits waiting. Re-read the snapshot before approving — `approveOnboardingRepair` is revision-scoped and the revision moves as the machine works.
    - A strategy that reports "not applicable" must **not** be recorded as attempted. `approveRepair` is inapplicable until a proposal exists, so marking it on the first pass permanently skips the only action later offered.
    - The offered action list is a hint about what a UI might present, **not** a guarantee the matching call is valid: `editRelays` is offered for `inboxRelays` while `proposeOnboardingRelays` throws `OnboardingActionUnavailable` for that step. Let each attempt fail on its own and move on — a propagating throw aborted a whole run with four strategies untried.
    - **The two identity paths end in different states.** `start(adoptingNsec:)` + `completeAccountSetup()` reaches `networkReady`; `startWithNewIdentity()` (`createIdentityWithProfile`) settles at `localReady` with **no onboarding session at all**, so `runOnboarding` throws `OnboardingActionUnavailable` on it. Only the adopt path is used in the app. Tests used the create path, which is why nothing caught this.
  - **Root ownership outlives `shutdown`.** It is held until the `Marmot` handle is *dropped*, so two services on one root fail with `RuntimeBusy`. Anything that rebuilds the service must release the previous handle first.
  - **`acceptLocalOnly` restricts to the local *link*, not loopback.** An `NWListener` with it set binds, reports `.ready`, and silently never accepts; the client sees only `-1005 "network connection was lost"`, identical to a failed handshake.
  - **`XCTAssert*`/`XCTUnwrap` take autoclosures, which cannot contain `await`.** Hoist the await into a `let` first. Hit three times.
  - **`./scripts/build.sh xcode` before building in Xcode**, then `restore` afterwards. Every other command restores the vendored-MarmotKit patch before returning, but Xcode re-resolves `MarmotKitBindings/Package.swift` itself on every build, so a restored tree sends it back to the upstream XCFramework and the `module.modulemap` collision returns. The vendoring is a requirement of *every* build entry point — `build.sh`, `ci.yml`, `codeql.yml`, `release-ios.yml` and Xcode — and was missed three times by being treated as a one-off each time.

- **The app target now runs MarmotKit (step 3d-iii-c1).** `AppViewModel` and every downstream view model/view point at `MarmotKitService`; `chat = 3` is live on the wire. The v1 stack (`MarmotService`, `MLSService`, `MDKBindings`) is still compiled in but no longer reached from the app — step 3d-iii-c2 deletes it. Until then **both** Rust archives link, which is why the Debug app is ~129MB.
- **Identity carries over; groups do not.** `start(adoptingNsec:expecting:)` feeds MarmotKit the nsec `IdentityService` already holds via `beginOnboarding`, so users keep their npub across the v2 update. Two things are easy to get wrong here and are now pinned by tests:
  - Match the account **by id**, never `listAccounts().first`. After an import or burn the old account is still in MarmotKit's database, so `.first` silently resumes the *previous* identity while reporting success.
  - `replaceIdentity` must call `forgetCurrentAccount()` **before** the handle is dropped. v1 only wiped its own `whistle.db`; MarmotKit's store is separate and survived it. Deleting the root directory instead is not safe — the runtime owns that root while its handle lives.
- **`wss://relay.damus.io` is removed from `AppDefaults.defaultRelays`** and filtered at runtime by `MarmotKitService.allowedRelayEndpoints(from:)`, which is a static because startup needs the answer before a service exists (it probes with a throwaway runtime on a temp root — a *separate* root, deliberately, since two handles on one root give `RuntimeBusy`).
- **Not yet done**: v1 deletion (step 3d-iii-c2), relay-settings validation UI (step 4), Android port (step 5).

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
