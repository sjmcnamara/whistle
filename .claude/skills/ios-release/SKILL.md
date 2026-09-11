---
name: ios-release
description: Cut an iOS release for Whistle — tagging, the archive/export/TestFlight-upload GitHub Actions workflow, and the seven required repo secrets. Use when tagging a version, publishing an iOS build, or debugging the release-ios workflow.
---

# Cutting an iOS release

Tagging `vX.Y.Z` and pushing the tag triggers `.github/workflows/release-ios.yml`, which
archives, exports a signed `.ipa`, and uploads it straight to TestFlight via an App Store
Connect API key — the same tag push that triggers `release-android.yml`.

```bash
git tag v1.2.0
git push origin v1.2.0
```

**What the workflow does not do:** submit the TestFlight build for App Store review. That
stays a deliberate manual step in App Store Connect — a release decision, not a build step.

## The seven required repo secrets

Signing (archive won't succeed without these):

- `IOS_DIST_CERTIFICATE_B64` — base64 of the Apple Distribution certificate `.p12`
- `IOS_DIST_CERTIFICATE_PASSWORD` — the password you set when exporting the `.p12`
- `IOS_PROVISIONING_PROFILE_B64` — base64 of the App Store provisioning profile `.mobileprovision`
- `IOS_KEYCHAIN_PASSWORD` — any password; only used for the throwaway CI keychain created and deleted within the job

Upload (TestFlight push won't succeed without these):

- `APPLE_API_KEY_B64` — base64 of the App Store Connect API key `.p8` file
- `APPLE_API_KEY_ID` — the Key ID shown next to it in App Store Connect
- `APPLE_API_ISSUER_ID` — the Issuer ID at the top of the Keys page (shared across all keys)

### Generating the Distribution certificate + provisioning profile

1. **Certificate**: [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates) → create an **Apple Distribution** certificate (or reuse the existing one from Keychain Access if you already have it installed locally).
2. Export it as a `.p12` from Keychain Access: select the certificate *and* its private key → right-click → **Export 2 items…** → set an export password (this becomes `IOS_DIST_CERTIFICATE_PASSWORD`).
3. Base64-encode it: `base64 -i DistributionCert.p12 | pbcopy` → paste as `IOS_DIST_CERTIFICATE_B64`.
4. **Provisioning profile**: [developer.apple.com/account/resources/profiles](https://developer.apple.com/account/resources/profiles) → create an **App Store** profile for `org.getwhistle.whistle`, signed with the certificate above. Download the `.mobileprovision`.
5. Base64-encode it: `base64 -i Whistle_App_Store.mobileprovision | pbcopy` → paste as `IOS_PROVISIONING_PROFILE_B64`.

The workflow reads the profile's UUID and name at runtime (`security cms -D` + `PlistBuddy`),
so nothing about the profile's name needs to be hardcoded anywhere — re-uploading a renewed
profile under the same secret is a drop-in replacement.

### Generating the App Store Connect API key

1. [appstoreconnect.apple.com](https://appstoreconnect.apple.com) → **Users and Access** → **Integrations** → **App Store Connect API** → **Generate API Key** (or **+**).
2. Give it the **App Manager** role (needed to upload builds). Download the `.p8` **once** — Apple does not let you re-download it.
3. Note the **Key ID** and the **Issuer ID** (issuer ID is shared across all keys on the team, shown at the top of the page).
4. Base64-encode the `.p8`: `base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy` → paste as `APPLE_API_KEY_B64`.

### Rotation / loss

- **Certificate/profile expired or revoked**: regenerate both (a new distribution cert requires a new provisioning profile bound to it) and replace all three `IOS_*` secrets together.
- **API key revoked or lost**: generate a new one in App Store Connect and replace all three `APPLE_*` secrets. Revoking a key has no effect on already-uploaded TestFlight builds.

## After the workflow finishes

The build is in TestFlight. To ship it further:

- **Internal testers** see it automatically once processing finishes (no extra step).
- **External testers / public release**: open App Store Connect → TestFlight (or App Store tab) → submit the build for review manually.

The `.ipa` is also attached to the tag's GitHub release (alongside Android's `.apk`, if that
workflow has already created the release) and uploaded as a workflow artifact, so a given
release's exact binary is always recoverable without re-running the archive.
