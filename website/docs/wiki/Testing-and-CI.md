# Testing and CI

Whistle has six required CI jobs on every PR to `master`. They all have to pass before merge. There's nothing exotic in here — Swift tests, Gradle tests, SwiftLint, CodeQL — and most of it can be run locally with one command.

## CI pipeline

GitHub Actions runs on PRs to `master` and pushes to `master`. The jobs below are required merge gates.

| Job | Runner | What it does |
|-----|--------|-------------|
| `WhistleCore Tests` | macOS 15 | `swift test` on the shared SPM package |
| `iOS Build & Test` | macOS 15 | Full Xcode build + `WhistleTests` on iPhone simulator |
| `Android Build & Test` | Ubuntu | `:shared:test` + `:app:testDebugUnitTest` via Gradle |
| `SwiftLint` | macOS 15 | `swiftlint lint --strict` — any warning fails the build |
| `Dependency Review` | Ubuntu | Scans PR dependency changes for known CVEs (PR only) |
| `codecov/patch` | — | Patch-level coverage check on changed lines |

In addition, CodeQL runs on a separate scheduled workflow for static analysis, and OpenSSF Scorecard reports project hygiene weekly.

Dependabot checks weekly for updates to GitHub Actions, Swift packages, and Gradle dependencies. Dep bumps land via routine chore PRs — see the recent `chore/` PRs on master for examples.

## Local test commands

### iOS

```bash
# WhistleCore (pure Swift, fast — no simulator required)
cd WhistleCore && swift test

# Full app build + tests via the project's build script
./scripts/build.sh test

# Or direct xcodebuild invocation (e.g. for a specific simulator)
xcodebuild test \
  -project Whistle.xcodeproj \
  -scheme Whistle \
  -destination "platform=iOS Simulator,name=iPhone 16 Pro,OS=latest" \
  -only-testing:WhistleTests
```

### Android

```bash
cd android
./gradlew :shared:test               # shared module (fast)
./gradlew :app:testDebugUnitTest     # app unit tests
./gradlew test                       # both
```

### SwiftLint

```bash
swiftlint lint --strict
```

## Common local issues

- **Simulator destination mismatch** — `xcrun simctl list devices available` to find what's actually installed
- **Xcode 26 + new iOS runtime** — if you see `iOS X.Y.Z not installed` errors, install the matching simulator runtime via Xcode → Settings → Components
- **Stale Swift build cache** — `rm -rf WhistleCore/.build` fixes most PCH / module-cache errors
- **Xcode project out of date** — `./scripts/build.sh` regenerates the project before building; raw `xcodebuild` requires a manual `xcodegen generate` first
- **vendor/mdk-swift LFS pointer files** — `./scripts/build.sh` clones with LFS the first time; requires `git-lfs` installed locally (`brew install git-lfs`)

## Test focus areas

These are the iOS suites under `WhistleTests/` worth knowing about — they exist because the underlying flows have been reliability-sensitive in the past.

| Suite | What it pins down |
|-------|-------------------|
| `MarmotServiceTests` | Gift-wrap retry, pending-ID retry path, join reliability under flaky relays |
| `GroupHealthTrackerTests` | Failure tracking and the "Out of sync" badge threshold |
| `IdentityServiceTests` | Key generation, persistence, import, destroy |
| `EncryptedSecureStorageTests` | Secure Enclave wrapping, migration detection, Data round-trips |
| `SecureEnclaveServiceTests` | P-256 ECDH + AES-GCM round-trips, key serialisation |
| `PendingWelcomeStoreTests` / `PendingLeaveStoreTests` | Consent and leave-confirmation flows |
| `MotionAdaptiveTests` | Movement Aware backoff and resume thresholds (v1.1.4+) |
| `BatteryAlertServiceTests` | Low Battery Alert trigger logic, threshold respect, deduplication (v1.2.0+) |
| `LocationPayloadTests` / `ChatPayloadTests` / `NicknamePayloadTests` | JSON encoding/decoding and schema-version handling |

Android mirrors much of this under `android/app/src/test/java/org/findmyfam/` (services, viewmodels) and `android/shared/src/test/java/org/findmyfam/shared/` (payloads, defaults).

## When to add tests

- Any change to join / leave / rejoin logic
- Any change to the pending-state stores (`PendingInviteStore`, `PendingLeaveStore`, `PendingWelcomeStore`)
- Any change to event processing, dedup, or retry handling
- Any change to key storage or encryption (`SecureEnclaveService`, `EncryptedSecureStorage`, `IdentityService`)
- Any change to relay connectivity (`RelayService`)
- Any change to location interval / Movement Aware / Battery Alert logic
- Any new payload schema, or a `v` bump on an existing one
