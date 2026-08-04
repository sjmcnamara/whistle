---
name: android-release
description: Cut an Android release for Whistle — tagging, the signed-APK GitHub Actions workflow, the four required repo secrets, and publishing the release to Zapstore. Use when tagging a version, publishing an Android build, or debugging the release/Zapstore workflow.
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

## Publishing to Zapstore

[Zapstore](https://zapstore.dev) is a decentralized Android app catalog built on Nostr — Whistle's listing there is driven by `zapstore.yaml` at the repo root, published via the `zsp` CLI (https://github.com/zapstore/zsp).

Once the GitHub release above looks good, publish it to Zapstore by running the **`Zapstore publish`** workflow manually (Actions tab → "Zapstore publish" → Run workflow, or `gh workflow run zapstore-publish.yml`). It is deliberately **not** triggered automatically on tag push — publishing broadcasts signed events to public relays under a real identity, so it stays an explicit, separate step.

The workflow needs one repo secret:

- `ZAPSTORE_NSEC` — the raw nsec for the Nostr identity dedicated to this publish (npub `npub19j68858e0e72uz9ypqg29q42ulr9cs95pu93pjt3ca0lgqa5jdrq3ft4pe`). **This must be a single-purpose identity, never a personal npub** — CI holds it as plaintext for the run, so a leak should only expose the ability to impersonate the Zapstore listing, which is bounded and recoverable (rotate to a fresh identity, update `zapstore.yaml`'s `pubkey`, redo the identity-linking proof below).

To run the same publish locally instead of via CI:

```bash
SIGN_WITH=nsec1... ./scripts/zapstore-publish.sh          # publish
SIGN_WITH=nsec1... ./scripts/zapstore-publish.sh --check  # dry run, no publish
```

`SIGN_WITH` also accepts a `bunker://` NIP-46 URL if you're signing through a remote signer (e.g. `nak bunker`) instead of a raw nsec — see the git history around 2026-08-04 for how that was set up for the first Zapstore publish.

### One-time setup (already done for the current identity)

A fresh publisher pubkey needs two bootstrapping steps before the relay accepts its events — both already done for `npub19j68858e0e72uz9ypqg29q42ulr9cs95pu93pjt3ca0lgqa5jdrq3ft4pe`, but needed again if the identity ever rotates:

1. **Relay whitelisting** — `relay.zapstore.dev` rejects events from unknown pubkeys until it can verify them against `zapstore.yaml`'s `pubkey` field committed to the repo. Once that's merged, the first publish attempt whitelists the key automatically.
2. **NIP-C1 certificate linking** — proves the release keystore's signing certificate belongs to this Nostr identity, or GrapheneOS/hardened installs refuse the APK with "release or signer are missing":
   ```bash
   SIGN_WITH=nsec1... zsp identity --link-key /path/to/whistle-release.jks
   ```
   Verify it landed: `zsp identity --verify /path/to/whistle-vX.Y.Z.apk <<< "npub1..."`.
