# Contributing to Whistle

Thanks for your interest in Whistle. It's an open-source, decentralised family
location app built on Nostr + MLS (RFC 9420) via the
[Marmot Protocol](https://github.com/marmot-protocol/marmot), with native iOS
(Swift/SwiftUI) and Android (Kotlin/Compose) clients that share the same MDK
(Rust via UniFFI) and payload formats.

## License of contributions

Whistle is released under the [Unlicense](LICENSE) — a public-domain
dedication. By submitting a contribution you agree that your work is likewise
dedicated to the public domain and may be used by anyone for any purpose.
Please only contribute code you have the right to release this way.

## Getting set up

**iOS** (requires macOS, Xcode 16+, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

```bash
./scripts/build.sh               # generate project + build (simulator)
./scripts/build.sh compile-tests # type-check the test target without running it
./scripts/build.sh test          # generate + build + test
```

`build.sh` handles the mdk-swift vendor clone automatically. On an Intel Mac,
`build.sh test` can't run the suite (mdk-swift ships arm64 only) — use CI to
run tests; `compile-tests` still works locally.

**Android** (Android Studio, SDK 36+, Java 17):

```bash
cd android
./gradlew assembleDebug
./gradlew test
```

More detail on architecture and the wire protocol lives in the
[wiki](website/docs/wiki/index.md).

## Branch & PR workflow

**All changes go through a branch and a pull request. There are no direct
commits to `master` — this is enforced by a repository ruleset, for everyone.**

1. Branch from `master`. Naming: `feature/vX.Y-description`,
   `bugfix/vX.Y.Z-description`, or `chore/description`.
2. Make your change, with tests (see below).
3. Open a PR against `master`. Every CI check — iOS Build & Test, Android Build
   & Test, WhistleCore Tests, SwiftLint, Dependency Review — is a required merge
   gate and must be green.
4. Keep one logical change per PR. `ROADMAP.md` tracks branch history; update it
   when a feature branch merges.

## Coding conventions

- **Match the surrounding code.** Follow the naming, structure, and comment
  density already present in the file you're editing rather than introducing a
  new style.
- **iOS:** SwiftLint runs in CI with `--strict`, so warnings fail the build.
  Run it (or `./scripts/build.sh`) before pushing.
- **Cross-platform parity:** iOS and Android share payload formats and protocol
  constants. A change to a wire format, event kind, or shared behaviour should
  land on both platforms (or be explicitly scoped to one, and say so). Shared
  Swift types live in `WhistleCore/`; the Android equivalents under
  `android/app/src/main/java/org/findmyfam/`.
- **No secrets in the tree.** Signing keys and tokens are GitHub Actions
  secrets, never committed.

## Testing

- **New functionality should ship with tests.** Add unit tests under
  `WhistleTests/` (iOS) / `WhistleCore/Tests/` (shared) and
  `android/**/src/test/` (Android) covering the behaviour you add or change.
- **Before pushing an iOS change, run `./scripts/build.sh compile-tests`.** The
  plain build only compiles the app target, so the test target can silently stop
  compiling while the build still passes — this catches it locally instead of as
  a red CI run.
- Payload schemas, encoding/decoding, and protocol constants are the
  highest-value things to test — they're what keep the two platforms in sync.

## Changelog & versioning

- Add a `CHANGELOG.md` entry under the top section for any user-facing change,
  in [Keep a Changelog](https://keepachangelog.com/) style
  (`### Added / Changed / Fixed / Security / Improved`), leading with a platform
  badge — `(iOS)`, `(Android)`, or `(iOS & Android)`.
- Whistle follows [SemVer](https://semver.org/): features bump the minor
  version, fixes bump the patch.
- **Version bumping is a release step, not part of a feature PR.** When cutting a
  release, follow the [Release Checklist](website/docs/wiki/Release-Checklist.md),
  which enumerates every version-label location that must agree.

## Reporting bugs and vulnerabilities

- **Bugs and feature requests:** open a
  [GitHub issue](https://github.com/sjmcnamara/whistle/issues).
- **Security vulnerabilities:** do **not** open a public issue. Follow
  [SECURITY.md](SECURITY.md) and report privately by email.
