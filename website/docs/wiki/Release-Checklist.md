# Release Checklist

Whistle ships from `master`. Every release goes through a branch, a PR, and review — no direct commits to `master`, ever, including for version bumps. Branch naming follows the convention:

- `feature/vX.Y-description` for new functionality
- `bugfix/vX.Y.Z-description` for fixes
- `chore/description` for housekeeping (deps, docs, infra)

## Before cutting a release

1. **Confirm the target branch and version number.** Follow [SemVer](https://semver.org/) — features bump minor, fixes bump patch.
2. **Bump the version in all seven places.** They must all agree — miss one and the app, the store listing, or the website goes out stale (the `home.html` hero was found stale for several releases because the list wasn't explicit). Walk every item:
   1. `project.yml` — `MARKETING_VERSION` **and** `CURRENT_PROJECT_VERSION` (the latter is the iOS build number)
   2. `android/app/build.gradle.kts` — `versionName` **and** `versionCode` (Android build number is monotonically increasing)
   3. `CHANGELOG.md` — add a new `## [X.Y.Z] — YYYY-MM-DD` section at the top; follow the existing Keep a Changelog format with platform badges (`(iOS)` / `(Android)` / `(iOS & Android)`)
   4. `README.md` — update the `## Status` line (e.g. `vX.Y.Z — Production ready. iOS and Android.`)
   5. `CLAUDE.md` — update the `## Roadmap` "Current version:" line so AI agents and contributors see the latest shipped version
   6. `ROADMAP.md` — mark the completed phase with ✅, document what shipped under it, and (when relevant) update the branch-strategy history at the bottom
   7. `website/overrides/home.html` — update the `v1.X.Y` label in the hero CTA `<span class="w-meta">` block. The APK download link auto-resolves to `releases/latest`, but the displayed version is hardcoded.
3. **Regenerate the Xcode project** — `./scripts/build.sh` will run XcodeGen automatically; do this so the version change actually lands in the Xcode build settings.

## Validation

1. **Run CI checks locally** to catch issues before pushing:
   ```bash
   # WhistleCore (fast, no simulator needed)
   cd WhistleCore && swift test

   # SwiftLint — strict (any warning fails the build)
   swiftlint lint --strict

   # iOS unit tests (full Xcode build)
   ./scripts/build.sh test

   # Android unit tests
   cd android && ./gradlew :shared:test :app:testDebugUnitTest
   ```
2. **Push the branch** — every CI job listed in [Testing-and-CI.md](Testing-and-CI.md) must pass; they are required merge gates.
3. **Smoke-test critical flows on a real device** (simulator/emulator isn't enough for background location + push paths):
   - Create a group, invite via at least one transport (QR / NFC / link), accept the invite from a second device
   - Send chat messages, verify locations exchange both directions
   - Leave the group from one device, verify the admin sees + confirms it, then rejoin
   - Toggle relays off/on, add a custom relay, verify reconnect
   - Burn the identity from Settings → verify the app returns to first-run state cleanly
   - Battery / Movement Aware paths: leave the device stationary for >30s and confirm location intervals back off; drop battery below the threshold and confirm the alert fires for the rest of the group
4. **Check group-list state badges** — no stuck "Pending", "Leaving", or "Out of sync" rows after the smoke tests.

## PR hygiene

1. PR description focuses on user-visible behaviour, not implementation details.
2. Include test evidence (CI results, screenshots, simulator logs as relevant) and call out any environment caveats.
3. UI text or layout changes should include screenshots or short screen recordings.
4. Link the CHANGELOG and ROADMAP changes in the PR description.

## Post-merge

1. Pull latest `master` and confirm the version bump landed as expected.
2. Re-run smoke checks if the release branch was long-lived (rebase divergence sometimes reintroduces flaky paths).
3. **Tag the release**:
   ```bash
   git tag v1.2.0
   git push origin v1.2.0
   ```
4. If the release is going to TestFlight or beyond, archive and upload from Xcode using the matching `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` from `project.yml`.
