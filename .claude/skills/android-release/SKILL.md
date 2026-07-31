---
name: android-release
description: Cut an Android release for Whistle — tagging, the signed-APK GitHub Actions workflow, and the four required repo secrets. Use when tagging a version, publishing an Android build, or debugging the release workflow.
---

# Cutting an Android release

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

Version numbers must be bumped before tagging — see the "Version bumping" section of `CLAUDE.md`.
