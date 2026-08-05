# Changelog

All notable changes to Whistle will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [1.8.6] — 2026-08-05

### Fixed
- **(iOS) A member of two or more groups saw their own location pinned twice on the "All Groups" map, at slightly different coordinates.** `LocationCache` keys entries by `"groupId:pubkeyHex"`, so belonging to two groups produces two separate cache entries for yourself. The map view built one annotation per cache entry with no deduplication, so both showed up as pins. The two entries normally track each other via `broadcastLocation()` writing the same fresh payload into every group, but `LocationCache.update()` had no ordering guard, so an out-of-order relay echo of your own event in one group could leave that group's entry pointing at a stale coordinate — the visible symptom was two pins with slightly different GPS. `LocationViewModel.refresh()` now collapses to the single freshest self entry when showing all groups, and `LocationCache.update()` ignores an incoming payload older than what's already cached for that key.

## [1.8.5] — 2026-08-04

### Fixed
- **(iOS & Android) New members didn't see the group avatar until an admin manually resynced them.** The group avatar travels as an ordinary MLS application message rather than group state, so MLS forward secrecy means a newly-added member can never decrypt whatever avatar message was sent before they joined — the only remedy is the admin re-announcing it as a fresh message after each membership change. That re-announce (`rebroadcastGroupAvatarIfDesignated`) was wired to fire only when the admin's own client re-observed its just-published add-commit coming back over the live relay subscription — asynchronous and not guaranteed to arrive or be classified in time. `addMember`, `addMembers`, and `resyncMember` now trigger the re-announce directly at the point the commit is made, instead of depending on that self-echo.
- **(iOS & Android) Rejoining via hard resync showed a stale "Inactive" group entry alongside a duplicate "Accept" invitation for the same group.** `resyncMember`'s remove-then-re-add produces a fresh Welcome that never goes through the invite-code path, so it was misclassified as an unsolicited invite from a stranger requiring approval — even though the Welcome's own cryptographic validity already proves it came from a real admin re-adding a known member. Such a Welcome is now auto-accepted as a resume. Separately, the group list didn't re-render when a new pending welcome arrived (only new MDK group state triggered the filter that hides a group with a pending welcome from the main list), so the old inactive row could remain visible until an unrelated event refreshed it; the list now reacts to pending-welcome changes immediately.

## [1.8.4] — 2026-08-03

### Changed
- **(Android) `applicationId` moved from `org.findmyfam` to `org.getwhistle.whistle`.** `org.findmyfam` predates the app's rename to Whistle and was never updated. Android treats `applicationId` as the app's permanent identity — Play, F-Droid, and the [Zapstore](https://zapstore.dev) listing being set up all key off it — so this was the last point it could move without becoming a breaking change for a published store listing. Existing sideloaded installs of `whistle.apk` will not receive this build as an update; they must uninstall the old `org.findmyfam` install and install the new one, which resets local app data (the encrypted MLS database) and requires rejoining groups. The Kotlin package name (`org.findmyfam`) and app class (`FindMyFamApp`) are unchanged — only the Gradle `applicationId` moved, not the `namespace`.

## [1.8.3] — 2026-07-31

### Fixed
- **(iOS & Android) Relays that could never be reached were shown as connected.** `RelayService.connect` built its connected-relay list from the relays it had successfully *added* to the Nostr client. Adding a relay only registers a URL: `Client.connect()` returns as soon as it has spawned the background connection tasks, so the list was written before any socket had opened — and never corrected afterwards. A dead host, a typo'd URL, or an address the device cannot resolve at all (a `.onion` relay, with no Tor proxy configured) therefore showed a green dot in Advanced Settings indefinitely, and `MarmotService` counted it toward the relay set it gates member adds and resyncs on. Connection state is now read from the SDK's live per-relay status, `connect` waits up to 5s for sockets to open before reporting, and the settings screen re-reads status every 5s while it is open so the dots reflect background drops and reconnects. `ensureRelay` no longer marks an invite-hint relay connected merely because it was registered.

    `Client.connect()` is kept in preference to `tryConnect()`: `tryConnect` surfaces failures synchronously but schedules no retries, which would leave a phone that briefly loses signal permanently disconnected from that relay.

### Changed
- **(iOS & Android) Relay-gated operations re-check connectivity before failing.** Adding, resyncing, and batch-adding members previously read a cached relay list; now that the list reflects real socket state it can legitimately be empty for a moment while relays reconnect, so those three call sites go through a new `hasConnectedRelays()` that re-reads live status before throwing "not connected to any relay".

## [1.8.2] — 2026-07-30

### Fixed
- **(iOS) The app crashed while panning or zooming the map.** Every map pin renders a member avatar, and the avatar view reached for its `MemberAvatarStore` through `@EnvironmentObject`. MapKit hosts `Annotation` content in its own `_UIHostingView`, which does **not** carry the environment applied at the app root — and it builds that view from `MKAnnotationManager.updateVisibleAnnotations`, a timer callback outside SwiftUI's update pass. The lookup found nothing and trapped, terminating the app with `EXC_BREAKPOINT` in `EnvironmentObject.error()`. Map pins now take a resolved image, passed in by `MapView` where the environment is valid, and read nothing from the environment themselves. Latent since member avatars shipped in v1.7.1; observed crashing on iOS 26.6. Android was unaffected — `MapScreen` already takes an `avatarFor: (String) -> Bitmap?` and hands each pin a resolved bitmap, which is the shape iOS now matches. (Pin layout is now covered by tests that host it with an empty environment, the same way MapKit does.)

    Supersedes the unreleased fix in #187, which addressed the same crash by re-injecting the store onto each pin. That worked, but left a dependency that fatals when absent inside the one hosting context known to lose it; removing the dependency altogether retires the crash class.

### Changed
- **(iOS) 3D map terrain restored.** #187 switched both map styles from `.realistic` to `.flat` elevation while hunting the repeated-zoom-out crash, on the theory that MapKit's terrain renderer was causing GPU-memory instability. The cause turned out to be the `@EnvironmentObject` fault above and had nothing to do with terrain, so the flat-map downgrade was buying nothing and is reverted. Never shipped in a release — `.flat` existed only on unreleased master.
- **(iOS) The photo library reloaded over and over while setting a group photo.** Opening the picker from Group Details left it unusable: every couple of seconds it tore itself down and re-presented, resetting the scroll position before a photo could be chosen. `GroupDetailView` observes `AppViewModel`, which republishes on every settings, location, and relay change, and the `.photosPicker` modifier sat inline in the hero header — so ordinary relay traffic arriving in the background re-presented the picker underneath the user. The picker is now an `Equatable` subview (`GroupAvatarPickerButton`) that takes plain values and closures, so SwiftUI skips re-evaluating it on an unchanged parent re-render and the presented sheet is left alone. This is the same fix `AvatarPickerRow` received for the Settings avatar picker in v1.7.2; the group photo path had never been given it. Both views' equality contracts are now pinned by tests, which is what was missing when the bug came back. Android was unaffected — it launches the picker as a separate activity, which recomposition cannot tear down.

## [1.8.1] — 2026-07-22

### Fixed
- **(iOS) Avatars were encoded at up to 9× the intended pixel count.** The avatar downscaler built a `UIGraphicsImageRenderer` at the target *point* size without pinning `format.scale`, so on a Retina device it rendered at the screen scale — a 128 pt target became a 384 px JPEG on a @3x phone. The image still fit under the 16 KB wire cap (so nothing failed visibly), but every member and shared-group avatar travelled larger than designed, and personal group thumbnails were stored oversized on disk. The renderer now pins `scale = 1` so output is exactly the target pixel dimensions. Android was unaffected — it scales in pixels via `Bitmap.createScaledBitmap`. (Present since member avatars shipped in v1.7.1.)

## [1.8.0] — 2026-07-20

### Added
- **Share Diagnostics** (iOS & Android): Advanced Settings → Share Diagnostics produces a snapshot of this device's app and group state — app/build/OS, pinned MDK revision, and per active group the **epoch**, member and admin counts, and health-tracker state — as JSON you can copy or share as a file. Built for diffing: two members' reports placed side by side show a fork as a single differing `epoch` line, which is otherwise invisible from outside the device. Deliberately safe to share in public: no messages, no locations, no nicknames, and public keys and group IDs truncated to an 8-character prefix. A build-guard test fails if any full-length identifier ever reaches the output.

### Fixed
- **(Android) Diagnostics screen had no visible way back.** The Share Diagnostics screen was the only settings screen with no toolbar — every sibling wraps its content in a `Scaffold`/`TopAppBar` with a back arrow, but this one rendered a bare `Column`, so it relied entirely on the system Back gesture. On a device using gesture navigation with no on-screen Back button it looked stuck. It now has a "Diagnostics" top app bar with a back arrow, matching the rest of Settings. (iOS was unaffected — its `DiagnosticsView` is pushed in a `NavigationStack` and gets the system back button automatically.)
- **(iOS & Android) Burn Identity no longer claims it leaves your groups.** The confirmation said burning would "leave all groups", which is not what happens: it deletes local state only — no leave request, no removal proposal — so every other member keeps you in their group and keeps encrypting to a key you no longer hold. The warning now says so plainly, including that you cannot rejoin unless another admin re-adds you. (MLS membership is key material in the local database, not a property of your Nostr key, so re-importing the same nsec does not bring your groups back.)
## [1.7.3] — 2026-07-20

### Added
- **Shared group photo** (iOS & Android): an admin can set a photo for a group and every member sees it. Like member avatars it travels **inline** — base64 JPEG inside the MLS application message, end-to-end encrypted, no blob server — and shares the same 16 KB ceiling and encoder.

    **Admin-only is enforced on receive, not just in the UI.** MLS guarantees a message came from a group *member*, not from an admin, so every client independently checks the sender against the group's admin list before applying a group photo and drops anything from a non-admin. Hiding the button would stop honest clients only. (Marmot's own group-image component lives in group state and is changed by a commit, where admin policy is enforced at the protocol layer — but that design presumes Blossom blob storage, which this project deliberately does without. Inline trades protocol-level enforcement for app-layer enforcement and no servers.)

    **A personal photo takes precedence.** The per-device group photo from v1.6.0 still works and now sits above the shared one — it *replaces* the group's image on that device only, and removes nothing for anyone else. The Group Details menu separates the two: admins get Set/Change/Remove **Group Photo**, everyone gets Set/Change/Remove **Personal Photo**. (It was previously called "my photo", which collided with the member avatar in Settings — a different feature that behaves differently.) A personal photo has no size limit, because unlike the other two it never leaves the device.

    **New members get the photo without waiting.** When membership changes, one admin re-announces it — the one with the lexicographically smallest public key. Every admin sees the same join, so without a rule a three-admin group would send three copies of the image; picking by sorted key rather than list position means every device independently agrees on the same sender.

### Fixed
- **(Android) Setting a photo that was too large did nothing, with no explanation.** The result of the attempt was discarded at the call site, so an image that couldn't be shrunk under the wire limit simply failed silently — the picker closed and no photo appeared. iOS had always shown an alert here. Present since member avatars shipped in 1.7.1, and fixed for both the member photo and the new group photo. Both failure messages now also say *why* there is a limit: the photo is sent to everyone, so it has to be small.

## [1.7.2] — 2026-07-20

### Fixed
- **(iOS) Renaming a group works again.** The rename pencil beside the group name in Group Details could not be tapped. The hero photo above it was a `PhotosPicker` with no explicit frame, and inside a list row that control's tap region expanded well past the 80pt circle, covering the name and the pencil. The rename sheet itself was fine — it was simply unreachable. The photo is now a plain button confined to the circle.

### Changed
- **(iOS & Android) Tapping an avatar opens a menu instead of jumping straight to the photo library.** Both the member photo in Settings and the group photo in Group Details now offer Choose/Change Photo and, when one is set, Remove Photo. Previously removal was a cramped inline link next to the Settings thumbnail, and on the group photo it was hidden behind a long-press almost nobody would find. Each menu also states who can see that photo, since the two differ: the group photo stays on your device, the member photo is shared with everyone in your groups.

## [1.7.1] — 2026-07-19

### Added
- **Member avatars** (iOS & Android): set a photo in Settings and it is shared with every group you belong to, appearing on your map pin for other members. Members without a photo get a coloured circle with their initials, derived from their public key so it stays the same across launches and on both platforms. The image travels **inline**, base64-encoded inside the MLS application message — end-to-end encrypted like everything else, with no blob server and no new infrastructure. It is capped at 16 KB (128×128, quality stepped down until it fits) so it comfortably clears relay event limits; an image that cannot be squeezed under the cap is refused at pick time rather than published and silently dropped. Removing your photo propagates as an explicit removal, so it disappears from everyone's map rather than lingering. Avatars are wiped on identity burn.

### Fixed
- **(iOS) Photo picker no longer reloads on a loop.** Opening the avatar picker and waiting made the photo library visibly reload every couple of seconds. `AppViewModel` republishes on every relay event and `SettingsView` observes it, so ordinary relay traffic re-rendered the view containing the `PhotosPicker`, tearing the presented sheet down and putting it back. The picker now lives in a child view that owns its own state and takes plain values, and its label is inert.
- **(iOS) Display name field no longer re-renders Settings on every keystroke.** The field wrote straight through to `@Published` settings, so each character re-rendered the whole screen — rebuilding the text field being typed into. It now holds the draft locally and commits on submit or blur, matching Android. Also stops a `UserDefaults` write per keystroke.
- **(iOS) Avatar encoding moved off the main thread.** Picking a photo decoded a full-size image, downscaled it, and JPEG-encoded it up to six times on the UI thread, stalling the app for large camera-roll photos.

## [1.7.0] — 2026-07-19

### Added
- **Stationary status now visible for other members** (iOS & Android): the Movement Aware "stationary" indicator — the orange standing-figure badge on the map pin and the "Currently stationary" row in the member detail sheet — previously only ever appeared on your own pin, because the state was read from the local motion sensor and hard-gated to self. It is now carried in `LocationPayload` as an optional `stationary` boolean and rendered for everyone. Backward-compatible in the same way `interval` was in v1.2.1: the field is tri-state, and an omitted value (a pre-1.7 client, or a publisher with Movement Aware switched off) decodes as *unknown* rather than `false`, so an older member shows no badge instead of being wrongly rendered as moving. Your own pin still reads the live sensor, which is fresher than your last broadcast.

### Changed
- **(Android) Android Gradle Plugin upgraded to 9.2.1.** AGP 9 is a major release that requires Gradle 9.4.1+ (wrapper bumped) and ships **built-in Kotlin support**, so the `org.jetbrains.kotlin.android` plugin is removed from both modules — Kotlin is now provided by AGP itself. Consequences of the migration: the top-level `kotlin { compilerOptions { jvmTarget } }` block is gone (`jvmTarget` now defaults to `compileOptions.targetCompatibility`, i.e. 17); the project's Kotlin 2.3.21 / KSP 2.3.8 are forced onto the classpath via a root `buildscript` block, since AGP 9 otherwise defaults to KGP 2.2.10; Hilt bumped 2.58 → 2.60.1 for AGP 9 compatibility (older Hilt fails with "Could not find the Android Gradle Plugin (AGP) base extension"); and the shared module's test dependency switched from `kotlin-test` to `kotlin-test-junit`, because under built-in Kotlin the plain artifact's JUnit backend auto-selection isn't wired for the Android unit-test source set. No app behaviour change.

### Removed
- **(iOS) Share Nearby / Join Nearby removed.** The MultipeerConnectivity peer-to-peer invite exchange has been dropped — QR scanning covers the same in-person handoff, it was iOS-only with no Android equivalent, and it was the only join path that skipped explicit member approval (`approveViaNearbyShare` auto-approved on the theory that physical proximity implies consent). Every join now goes through the standard approval flow. The app no longer requests the local-network permission (`NSBonjourServices` / `NSLocalNetworkUsageDescription` removed), so the "Whistle would like to find devices on your local network" prompt is gone from first run.

---

## [1.6.6] — 2026-07-18

### Fixed
- **New groups no longer fork at formation** (iOS & Android): creating a group and having someone join left both devices listing each other as members but unable to decrypt a single message or location in either direction (`Failed to decrypt message with any exporter secret`). Cause: right after accepting the Welcome, the joiner performed an immediate key rotation ("post-join self-update", MIP-02 hardening) that advanced it to a new MLS epoch during the fragile just-joined window — before the admin's subscription had settled — so the admin never converged on that epoch and the group forked permanently. The post-join self-update is now disabled; a joiner stays at the Welcome's shared epoch, which both sides agree on. (A safe rotation can be reintroduced once commit convergence is guaranteed.)
- **A dropped MLS commit no longer forks a group forever** (iOS & Android): when processing an incoming group event (kind 445) failed, it was marked permanently "processed" and skipped by every recovery path — the live subscription, soft resync (catch-up), *and* hard re-invite all honoured that flag, so a single missed or out-of-order commit stranded the device on a stale epoch with no way back. Failures for groups we belong to are now left retryable, so soft resync can re-fetch and re-apply a missed commit and catch the epoch up. (Events for groups we're not in — delivered by the relay-wide kind-445 filter — are still marked processed to avoid re-scanning.)
- **Incoming chat messages now appear live in an open thread** (Android): a message received while you were already viewing that group's chat did not show up until you navigated away and back. The internal "new chat message" signal was a `StateFlow<String?>` keyed on group id, and StateFlow drops a repeat emission of the same value — so a second message from the group you were already looking at notified nobody. It now carries a nonce so every message refreshes the thread. (iOS was unaffected.)
- **No more phantom "Group invitation received" after joining** (iOS & Android): a freshly-joined member could end up both in the group (map, chat working) *and* showing a pending invitation prompt for the same group — a split brain. The admin gift-wraps the Welcome per rumor and it can be redelivered, and the second copy was misclassified as "unsolicited" because the pending-invite marker had already been cleared by the first join. Incoming Welcomes for a group we're already an active member of are now ignored (clearing any stale pending state) instead of resurfacing as a phantom invite.

---

## [1.6.5] — 2026-07-17

### Fixed
- **Group chat no longer reloads from scratch on every visit** (iOS & Android): leaving a chat and returning showed an empty thread that then had to re-decrypt and repaint from MDK. The chat view-model is created per-group and destroyed when the chat is popped off the navigation stack, so each return started from an empty message list. Loaded threads are now held in an in-memory `ChatMessageCache` keyed by group, and a re-entered chat seeds itself from that cache synchronously — so the thread renders instantly. The background refresh now *merges* the newest page into what's shown (de-duplicated, by message id) instead of replacing it, so any older history paged in with "Load earlier messages" survives the refresh rather than being dropped. The cache is purely in-memory (the durable store remains MDK's encrypted SQLite DB) and is cleared on logout.

---

## [1.6.4] — 2026-07-10

### Fixed
- **"Load earlier messages" in group chat** (iOS & Android): paging older chat history was unreliable and often did nothing. Two compounding bugs: (1) the paging offset was advanced by the number of *displayed chat bubbles*, but it indexes the raw message store — which is dominated by frequent location updates — so successive pages overlapped and barely progressed (sometimes not at all, and could duplicate messages); (2) the chat view scrolled back to the newest message on *any* change, including when older messages were prepended, so even a successful load snapped away from what it just loaded. The offset now advances by the raw page size, `loadMore` keeps paging until it surfaces at least one older chat message (bounded), results are de-duplicated, and the view holds position on prepend (only auto-scrolling to the bottom when a message is actually sent or received). On Android the one-shot auto-trigger that could get permanently stuck is replaced with an explicit, reliable button.

### Added
- **Hard group resync** (iOS & Android): admins get a **Resync** action on each member row in Group Details for the true-fork case that soft catch-up can't reach (a commit the member merged that others never got — MDK marks it `previouslyFailed` and won't re-apply). Behind a confirmation, it removes the member and immediately re-adds them with a fresh key package, rebuilding their leaf in the MLS ratchet tree. Ordering is deliberate — the key package is fetched first, so a member is never removed unless they can be re-added; if the re-add still fails, the error prompts a retry rather than leaving them stranded. Both the remove and re-add commits are verified on the relay (the v1.6.1 anti-fork check). This completes the resync story started in v1.6.2: soft catch-up for a missed commit, hard re-invite for a genuine fork.

### Fixed
- **Remove-member commit now verified on relay** (iOS & Android): the standalone "Remove member" admin action published its removal commit fire-and-forget — the same gap v1.6.1 closed for self-update and metadata commits, but on the removal path. In a group of three or more, a dropped removal commit stranded the remaining members on the old epoch and desynced decryption. Removal now routes through the same relay-verified publish.

---

## [1.6.2] — 2026-07-09

### Added
- **Soft group resync** (iOS & Android): the in-chat decryption banner is now actionable. Tapping **Resync** re-fetches and re-processes the group's recent MLS commits (a bounded 30-day window, ignoring the normal `since` high-water mark) so a commit this device never received — because it was offline or its subscription had a gap while the commit sat on the relay — is finally applied and the epoch catches up. The banner clears automatically on success. Deliberately does not self-update (a self-update from a behind device cannot heal a fork). If catch-up does not resolve it — the true-fork case — the banner switches to directing the user to ask an admin to re-invite them (the hard-resync path, planned next).

---

## [1.6.1] — 2026-07-06

### Fixed
- **MLS commits now verified on relay** (iOS & Android): epoch-advancing commits that merge locally before publishing — self-update key rotation (post-join and the periodic 7-day rotation) and group-metadata changes (promote-to-admin, rename) — were published fire-and-forget. If the kind-445 commit failed to reach the relay, the sender's epoch advanced locally (old epoch secrets dropped for forward secrecy) while other members stayed behind, desyncing decryption in both directions and surfacing "Some messages couldn't be decrypted. A member may need to be re-invited to resync." All these paths now confirm the commit is retrievable from the relay after publishing (re-publishing if it did not land), matching the MIP-02 anti-fork check already used when adding members.

---

## [1.6.0] — 2026-06-29

### Added
- **Group avatar** (iOS & Android): tap the group icon in Group Details to set a personal photo from your library. The avatar appears in the group list row in place of the default icon. Local and per-device — not shared with other members, no protocol changes. Long-press the hero circle to remove the photo.

---

## [1.5.0] — 2026-06-24

### Added
- **Join requests** (iOS & Android): when an invitee accepts an invite link, the app automatically gift-wraps a join-request (Nostr kind 1080) directly to the inviter, carrying the invitee's MLS KeyPackage inline. Nothing leaks to relays — the request rides inside a NIP-59 kind-1059 gift-wrap.
- **Pending-joiners list** (iOS & Android): the group admin sees a "Ready to Join" section in Group Details listing everyone who has sent a join request and is waiting to be added. Each row shows the invitee's display name and when the request arrived.
- **"Add all" batch add** (iOS & Android): a single button collects all pending KeyPackages and calls `addMembers([…])` once, producing one MLS epoch bump and one kind-445 commit instead of N sequential commits. Each invitee receives an individual Welcome. Partial-failure rule: anyone whose KeyPackage is in hand is added immediately; latecomers stay pending and are retried on their next launch.
- **Group Details redesign** (iOS): the Group Details screen is rebuilt with a cleaner layout — pending joiners surface prominently at the top so admins can act without scrolling past the full member list.

### Fixed
- **`ChatViewModel` `@StateObject` crash** (iOS): `ChatViewModel` was declared `@ObservedObject` in a parent view that created it inline, causing SwiftUI to tear it down and recreate it on every parent re-render, dropping message subscriptions and sometimes crashing. Moved to `@StateObject` so SwiftUI owns the lifetime.

---

## [1.4.1] — 2026-06-12

### Fixed
- **App update could wipe group membership** (iOS & Android): `MLSService` deleted and recreated the MLS database on *any* `newMdk` failure. The intent was to discard a pre-v0.9 *unencrypted* database, but the catch-all also fired when a perfectly healthy *encrypted* database failed to open transiently — e.g. the Keychain/Keystore not yet readable on a background launch before first unlock — silently destroying every group. (This was originally removed in an earlier fix, then reintroduced when SQLCipher encryption was switched on.) The recreate path is now gated on a check that the on-disk file is a genuine plaintext SQLite database (SQLCipher encrypts the header, so a healthy encrypted DB never carries the SQLite magic); any other open failure now fails loudly without deleting, so a later launch can retry and recover.
- **iOS device never went stationary until pause toggled** (iOS): with Movement Aware on, opening the app while already sitting still left the pin flagged "moving" indefinitely — the standing-man badge and "Currently stationary" never appeared unless the user toggled location sharing off then on. `CMMotionActivityManager` is edge-triggered (it fires only when the activity *changes*), so a device that was already stationary at launch received no callback; toggling pause restarted monitoring and happened to deliver a transition. Startup now seeds the initial state from recent motion history via `queryActivityStarting`, so the device goes stationary on its own. Complements the v1.3.1 fix for the inverse "stuck at 4× while moving" case.
- **Map pins showed no staleness counter** (Android): on the OSM map, member pins displayed only the avatar and name — the relative-time line iOS shows below the name was missing entirely, so there was no at-a-glance "how fresh is this?" without tapping into the detail sheet. Pins now carry a live counter matching iOS `MemberPinView`: other members count **up** since last seen ("2 min ago"), and your own pin counts **down** to its next scheduled publish ("in 30s"), derived from the last fire time and the effective (motion-adjusted) cadence. The counter ticks once a second.

---

## [1.4.0] — 2026-06-12

### Added
- **Whistle button** (iOS & Android): a circular broadcast-icon button on the map that force-publishes your location to every active group immediately, bypassing the update timer, the motion-aware backoff, and the stationary multiplier. A one-shot override that even fires while sharing is paused (a single send; it stays paused afterwards). Requests a fresh fix and falls back to the last known location if none arrives; the icon swaps to a spinner while sending, a checkmark on success, and a warning if it can't get a location. For the "I need them to see where I am right now" moment without waiting for the next scheduled update. The stamped `LocationPayload.interval` still reflects the normal cadence, so a manual whistle doesn't skew receivers' staleness grading.

---

## [1.3.1] — 2026-06-11

### Fixed
- **Motion-adaptive backoff could get stuck at 4× while moving** (iOS): with Movement Aware on, a device that went stationary (multiplier → 4×) and then started moving could keep publishing at the slowed cadence indefinitely — e.g. a 15-min interval stayed at the stationary 1-hour rate, so the pin showed the stationary badge and stopped updating even while walking. `CMMotionActivityManager` is edge-triggered (it delivers a callback when the activity *changes*, not continuously), but `MotionService` only re-evaluated the 30 s moving-debounce *inside* that callback. During steady walking only the initial "walking" callback arrived, so the elapsed-time check never ran again and `isStationary` never flipped back. The debounce is now driven by a one-shot timer that fires after 30 s of sustained motion regardless of further activity callbacks, and is cancelled the moment a stationary reading arrives. Matches Android, which was already timer-driven and unaffected.

---

## [1.3.0] — 2026-06-10

_UX polish — smoothing over rough edges surfaced during 1.2.x on-device testing._

### Added
- **Member detail sheet** (iOS & Android): tapping a member's map pin opens a bottom sheet with their nickname, last-seen time (anchored on local `receivedAt`), and the publisher's update cadence (e.g. "every 10 sec" / "every 1 hour"). Surfaces the `LocationPayload.interval` field added in v1.2.1 without crowding the map — answers "why is mom's pin always grey?" for the curious, hidden for the 95% case. Own pin also shows "Currently stationary" while Movement Aware is active.

### Changed
- **Group chat header is now tappable** (iOS & Android): tapping the group title or member-list strip in the chat view opens group detail (invite codes, member management). The small info icon to the right remains as a secondary affordance, so the existing tap target is preserved.
- **Custom map pins** (Android): replaced osmdroid's default red marker with a custom-drawn pin matching the iOS `MemberPinView` — a white-ringed avatar circle (blue when fresh, grey when stale) with a person glyph, the member's display name labelled below with a white halo for legibility over tiles, and the orange stationary badge composited into the same bitmap (rather than a separate offset marker that could drift out of alignment). Rendered at device density so it stays crisp at any DPI.

### Fixed
- **Spurious EXIT_STILL no longer drops the 4× backoff** (Android): `MotionService` now requires 30 s of confirmed non-stationary activity before flipping the multiplier back from 4× to 1×, mirroring the iOS behaviour. Previously, a phone bumped on a desk could fire an `EXIT_STILL` transition that immediately cancelled the battery-saving backoff. The reverse direction (entering still) still applies immediately. iOS was already debounced — `MotionService.movingDebounceSeconds` (30 s) — and is unchanged.

---

## [1.2.1] — 2026-06-09

### Fixed
- **Lock screen & Face ID prompt** (iOS): replaced lingering "FindMyFam" strings on the locked-app screen and the Face ID / passcode prompts with "Whistle". Cosmetic only — no bundle ID, keychain, signing, or install identity changes.
- **GPS vs Wi-Fi selection** (Android): `LocationService` now keeps the most recent fix from each of `GPS_PROVIDER` and `NETWORK_PROVIDER` and selects per-fire by freshness then accuracy. Previously, a low-accuracy network fix could beat a soon-to-arrive GPS fix to the throttle gate. Stays GMS-free (no `FusedLocationProviderClient` dependency, GrapheneOS-compatible).
- **Live interval changes propagate on Android**: `AppViewModel` now observes `AppSettings.locationIntervalSecondsFlow` and re-applies the new value to the running `LocationService` (plus throttle reset) instead of snapshotting it at startup. Previously, changing the interval in Settings had no effect until the next app restart. Mirrors the iOS behaviour at `AppViewModel.swift:173`.
- **Cross-device stale-pin grading** (iOS & Android): `MemberLocation.isStale` now prefers the publisher's own interval (carried in the new `LocationPayload.interval` field) and only falls back to the local device's interval when the field is absent (pre-1.2.1 senders). A member on a 1-hour cadence no longer goes grey within 20s on a device polling every 10s.
- **Cross-device clock-skew resilience** (iOS & Android): staleness and the on-pin countdown are now anchored on `receivedAt` (local clock) rather than `payload.ts` (publisher's clock). Two devices whose clocks drift by even 30s would previously render each other as permanently grey; now staleness means "we haven't heard from them in a while" rather than "their stamped timestamp looks old." `payload.ts` and `payload.interval` still ride along in the wire format for telemetry/debugging but no longer drive UI staleness.
- **Self-pin countdown no longer truncates** (iOS): the next-update countdown on the user's own pin rendered as "in 2 min, 5s…" with a shrunk font, because the future-relative form of `Text(date, style: .relative)` is longer than the past-relative form used for peer pins. Switched the label from `minimumScaleFactor(0.7)` to `fixedSize()` so it takes its natural width instead of being squeezed.
- **Self-pin countdown no longer oscillates up-then-down** (iOS): the countdown is computed as `lastFireDate + (interval × motion multiplier)`, but Core Location doesn't always deliver an update right at the throttle's expiry — so the computed `nextFireDate` could fall into the past for several seconds until the next GPS fix arrived, flipping SwiftUI's `Text(date, style: .relative)` into count-up mode (e.g. `…, 1, 0, 1, 2, 3, 9, 8, 7, …`). Clamped at the viewmodel layer with `max(computed, Date())` so the timer holds at "0 sec" honestly while waiting for the late fix instead of climbing.
- **Published interval reflects motion multiplier** (iOS & Android): `LocationPayload.interval` now carries `intervalSeconds × motionMultiplier` (via the new `LocationService.effectiveIntervalSeconds`) instead of the user-configured value. Without this, a stationary device on a 10s setting publishes every 40s but stamped `interval: 10`, so receivers using the publisher's interval (above) still saw the pin go grey within 20s of every send. New helper is testable in isolation; tests on both platforms.

### Changed
- **Internal rename** (iOS): `struct FindMyFamApp` → `WhistleApp` (file renamed too), and `FMFLogger` → `WhistleLogger` swept across 19 files. No user-facing behaviour change; bundle ID `org.findmyfam.app` deliberately untouched.
- **`LocationPayload` schema**: added optional `interval` field (publisher's own update cadence in seconds). Schema version stays at `1` — older clients ignore the unknown field, and newer clients accept payloads without it. Fully backward and forward compatible.
- **Settings → About → Version row** (iOS & Android): now shows the build number alongside the marketing version, e.g. `1.2.1(24)`. Makes TestFlight / sideload-vs-release builds visually distinguishable without digging into device info.

### Docs
- **Architecture wiki**: corrected the `LocationService` line — Android uses raw `LocationManager`, not `FusedLocationProvider`. Noted OSM via osmdroid is the deliberate (GMS-free) choice, not a Google Maps fallback.
- **ROADMAP**: added an "Optional Google Maps on Android" entry to the Deferred section, framed as a future product-flavor option rather than a fallback.

---

## [1.2.0] — 2026-05-13

### Added
- **Low battery alerts** (iOS & Android): `BatteryAlertService` monitors device battery and, once it drops below the configured threshold, publishes a location message tagged with a battery-low flag. Other group members receive a local notification so they know someone's phone is about to die.
- **In-app alert banner** (Android): `FamilyMapScreen` surfaces the battery-low event as a dismissible banner overlaid on the map.
- **Notification icon** (Android): dedicated `ic_notification_battery` drawable used for battery alert notifications.

### Changed
- **Kotlin** (Android): 2.1.0 → 2.3.21, with matching Compose compiler plugin.
- **KSP** (Android): 2.1.0-1.0.29 → 2.3.7.
- **Hilt** (Android): 2.54 → 2.58.
- **Compose BOM** (Android): 2024.12.01 → 2026.05.00.
- **androidx.security:security-crypto** (Android): 1.1.0-alpha06 → 1.1.0 (stable).
- **github/codeql-action** (CI): 4.35.2 → 4.35.3.

---

## [1.1.5] — 2026-05-08

_Brought Android up to feature parity with iOS v1.1.x._

### Added
- **Promote to admin** (Android): swipe action in Group Detail to promote any non-admin member. Admin-only; hidden for self and existing admins.
- **Battery level in location payload** (Android): `LocationPayload` extended with a `battery` field, consistent with iOS.

### Fixed
- **Stale DB deletion** (Android): unencrypted database from pre-v0.9 is now detected and deleted on first launch, matching iOS behaviour.

---

## [1.1.4] — 2026-05-08

### Added
- **Movement Aware mode** (iOS & Android): detects when the device is stationary and backs off location updates to 4× the configured interval, resuming the normal rate once movement is confirmed. Saves battery during extended periods of inactivity.
  - iOS: `CMMotionActivityManager` with 30s confirmed-movement debounce (ignores `unknown`/noise activity).
  - Android: Activity Transition API (STILL enter/exit) — OS-level debouncing included.
- **Stationary badge on map pin** (iOS & Android): small orange `figure.stand` badge overlaid on the user's own pin while Movement Aware is active and the device is stationary. Clears when movement resumes.
- **Accurate next-update countdown**: pin label now reflects the effective (multiplied) interval so the timer counts down to the real next fire rather than showing the 1× interval as overdue.

---

## [chore] — 2026-05-05

### Changed
- **MDK 0.8.0** (iOS): bumped MDK dependency from 0.7.1 to 0.8.0. Includes our merged PR #252 (keyring auto-init in `newMdk()`), MIP-05 notification primitives, MIP-00 key package migration to addressable kind:30443 events, and several security hardening fixes (admin pruning, ciphertext dedup, replay rejection). `MarmotKind.keyPackage` updated from 443 to 30443.

### Fixed
- **SE test assertions** (iOS): `SecureEnclaveServiceTests` now uses runtime `SecureEnclaveService.isAvailable` checks instead of compile-time `#if targetEnvironment(simulator)`, fixing 3 test failures on iOS 26 simulator where Apple enabled SE availability.

---

## [1.1.3] — 2026-04-23

### Security
- **MLS database encryption activated** (iOS): `MLSService.initialise()` now calls `newMdk()` directly — the MLS database is SQLCipher-encrypted on first launch. Blocked since v0.9 on MDK #243 (`set_default_store()` not UniFFI-exposed); resolved via `marmot-protocol/mdk` merging a contributor improvement of PR #252 that auto-initialises the platform keyring store inside `newMdk()`. Stale unencrypted databases from pre-v0.9 are detected and replaced on first launch.

### Added
- **Promote to admin** (iOS): swipe right on any non-admin member in Group Detail to promote them to admin; action is visible only to existing admins and hidden for self. Uses MDK `updateGroupData()` to append to `admin_pubkeys` — groups support multiple admins.

### Fixed
- **`scripts/build.sh clean`**: DerivedData glob corrected from `FindMyFam-*` to `Whistle-*` (leftover from v0.8.6 rename)
- **`createMessage` API update**: added `eventTags: nil` for new outer-event-tags parameter added in MDK v0.7.1

### Changed
- **Version bump** — iOS 1.1.3 (build 20)

---

## [1.1.2] — 2026-04-09

### Added
- **System settings deep links** (iOS & Android): location section in Settings now shows "Open Settings" when permission is denied; biometric settings link shown below App Lock toggle when enabled; iOS restricted-by-policy state surfaced with explanation text
- **MLS database renamed** (iOS & Android): `findmyfam-mdk.db` → `whistle.db` (iOS), `marmot.db` → `whistle.db` (Android); automatic migration renames the old file + WAL/SHM on first launch so existing users keep their data

### Changed
- **Version bump** — iOS 1.1.2 (build 19), Android 1.1.2 (versionCode 16)

---

## [1.1.1] — 2026-04-06

### Added
- **First-run onboarding flow** (iOS): three-card welcome carousel (encrypted, no accounts, background updates) shown once after the splash screen on a fresh install; followed by a permission-framing screen that explains location access before the system prompt fires; "Skip for now" defers location permission to Settings; `hasCompletedOnboarding` UserDefaults flag gates the flow permanently after first completion
- **Launch screen logo** (iOS): `UILaunchScreen` now shows a properly sized Whistle wordmark during binary loading instead of a blank white screen

### Improved
- **Startup performance** (iOS): first-launch onboarding now appears immediately — all Rust init (identity, MLS, relay) is deferred until after onboarding completes; returning-user startup also faster with relay connect moved to background Task, MLS init moved off the main thread, and minimum splash reduced from 1.5s to 1.0s
- **Skip `newMdk()` timeout**: the always-failing encrypted MDK init (blocked on MDK #243) is no longer attempted, eliminating a multi-second keyring timeout on every cold start

### Changed
- **Version bump** — iOS 1.1.1 (build 18), Android 1.1.1 (versionCode 15)

---

## [1.0.2] — 2026-04-05

### Fixed
- **Groups lost after force quit** (iOS): MLS database was deleted on every launch because `MLSService.initialise()` unconditionally called `deleteDatabase()` in the `newMdk` failure path — which always fails while MDK #243 (keyring-core UniFFI exposure) is unresolved. The delete calls have been removed; the unencrypted fallback now opens the existing database directly, preserving all groups and messages across relaunches
- **Android unit test coverage** (CI): switched from a custom `JacocoReport` task (which produced ~0% because AGP 8.x writes compiled classes to a different path) to the AGP built-in `createDebugUnitTestCoverageReport` task; Android coverage now reports correctly in Codecov

### Added
- **Android unit tests**: 6 new test suites (LocationFuzz, LocationViewModel, MemberSort, GroupListItem, ChatMessageItem, MemberAnnotation) — 60 new tests covering location fuzzing math, map annotation staleness, group filtering, member sort order, unread logic, and chat message type filtering; total Android tests now 90
- **MockK + coroutines-test**: added test dependencies for mocking Android services and testing coroutine-based ViewModels
- **Protocol round-trip tests — Tier 1** (iOS): 27 tests covering group lifecycle (create, rename, relays), member add/remove via Welcome, message delivery (chat, location, nickname payloads), key rotation (epoch advancement, post-rotation messaging), leave requests, invite code round-trip, and subscription setup
- **Failure & recovery tests — Tier 2** (iOS): 40 tests covering uninitialised MLS errors, health tracker threshold/recovery, invalid/corrupt event handling, message ordering and pagination, concurrent group and message operations, identity lifecycle (generate/restore/destroy/import), MLS reset, store deduplication (PendingInvite, PendingLeave, PendingWelcome), and Welcome decline

### Changed
- **Codecov: exclude Compose UI from coverage**: `ui/`, `MainActivity`, `FindMyFamApp`, and `di/` excluded from Codecov metrics — these require instrumentation tests and were dragging overall coverage to 3%
- **`fuzzCoordinate` extracted for testability**: location fuzzing algorithm extracted from `AppViewModel` to an `internal` top-level function with injectable `Random` for deterministic testing
- **Version bump** — iOS 1.0.2 (build 17), Android 1.0.2 (versionCode 14)

---

## [1.0.1] — 2026-04-03

### Fixed
- **Chat timestamps** (iOS): message timestamps now display wall-clock time ("2:30 PM") instead of relative age ("5 minutes ago"), matching Android, Signal, and WhatsApp conventions
- **"Load earlier messages" button** (iOS): button was always visible but did nothing — `hasMore` was not `@Published` so SwiftUI never re-rendered when pagination state changed; now correctly hidden when all messages are loaded
- **Imprecise location grey pin** (iOS): when "Precise Location" is disabled in iOS Settings, the location payload timestamp is now stamped with the broadcast time rather than the OS acquisition time — prevents false stale-pin detection from cached location objects
- **Invalid location fix filtering** (iOS): locations with `horizontalAccuracy < 0` (CoreLocation's signal for no valid fix) are now dropped before entering the broadcast pipeline
- **Pin label truncation** (iOS): relative timestamp labels on map pins now scale down to fit rather than clipping to "2mins,..."

### Added
- **Location fuzzing** (iOS & Android): new "Location Privacy" section in Advanced Settings with Off / 10 m / 50 m / 200 m options; applies a random offset within the chosen radius before broadcasting — shared coordinates are approximate, not exact
- **Codecov integration**: coverage reports uploaded to Codecov on every CI run; separate flags for `ios` (WhistleTests) and `whistlecore` (WhistleCore SPM) for per-layer visibility; informational only, not a PR gate

### Changed
- **Version bump** — iOS 1.0.1 (build 16), Android 1.0.1 (versionCode 13)

---

## [1.0.0] — 2026-04-02

### Security
- **Secure Enclave-wrapped nsec** (iOS): the Nostr secret key is now AES-GCM encrypted with a symmetric key derived from a Secure Enclave-bound P-256 ECDH key agreement; hardware-bound, non-exportable; automatic one-time migration from plaintext Keychain on first launch
- **StrongBox-backed Keystore** (Android): `MasterKey` now requests StrongBox backing for hardware-bound key encryption on devices with dedicated secure elements; diagnostic log on startup
- **Plaintext nsec fallback removed** (iOS): the UserDefaults fallback that could store the nsec in plaintext (included in unencrypted backups) has been removed; Keychain-only storage with legacy migration
- **Privacy audit**: systematic review verified no metadata leakage — all group payloads MLS-encrypted (kind 445), member lists never on relays, NIP-59 gift-wrap hides sender via ephemeral key, no `p`/`e` tags leak group members

### Added
- **Relay management** (iOS & Android): add custom relays with URL validation, remove custom relays (swipe-to-delete on iOS, X button on Android), enable/disable toggle per relay; default relays cannot be removed
- **Live relay reconnect**: toggling, adding, or removing a relay immediately disconnects and reconnects with the updated relay set — connection status dots and labels update in real time
- **Per-relay connection dot**: green dot when connected and enabled, grey when disabled or disconnected (iOS & Android)
- **Dynamic connection status**: Connection section shows actual relay state (Disconnected / Connecting / Connected / Failed) and MLS crypto state (Starting / Ready / Failed) instead of hardcoded labels
- **Event dedup logging**: structured debug logs on both platforms confirm duplicate event skipping when subscribed to multiple relays (`processedEventIds` + MLS `PreviouslyFailed`)

### Improved
- **SwiftLint strict mode**: all 336 Swift files clean with 0 violations; `--strict` flag enabled in CI so any new warning fails the build
- **Android map filter parity**: pending-leave groups now hidden from the map filter picker on Android (matching iOS v0.9.4 behaviour)

### Changed
- **CI merge gate**: required status checks enabled on master — all CI jobs must pass before merge
- **Version bump** — iOS 1.0.0 (build 15), Android 1.0.0 (versionCode 12)

---

## [0.9.4] — 2026-04-02

### Security
- **Welcome consent**: unsolicited group additions now require user approval; only Welcomes matching a pending invite are auto-accepted. Prevents forced group membership via direct addMember-by-npub
- **Burn identity hardening**: old nsec is explicitly destroyed from Keychain / EncryptedSharedPreferences before the new key is written; MLS database files are overwritten with zeros before deletion; all residual UserDefaults / SharedPreferences data (chat timestamps, read timestamps, pending welcomes) is purged

### Added
- **Burn Identity**: new "Danger Zone" action in Advanced Settings generates a fresh Nostr keypair, tearing down all groups, messages, and cryptographic state (iOS & Android)
- **Admin action badge**: small orange dot on the group icon when the admin has pending actions (e.g. leave request approval); clears automatically after processing (iOS & Android)
- **Cancel stale invites**: users can now swipe-to-dismiss (iOS) or tap X (Android) on pending invites that were never accepted

### Improved
- **Create Group auto-focus**: keyboard opens automatically on the group name field when the Create Group sheet appears (iOS & Android)
- **Welcome invite UI**: compact circular checkmark / X icons replace bulky bordered buttons for accept/decline on unsolicited group invitations
- **Empty state polish**: restyled "No groups yet" screen with larger stacked buttons (iOS)

### Fixed
- **Pending-welcome groups hidden**: groups awaiting consent no longer appear as "Inactive" in the group list after pull-to-refresh (iOS & Android)
- **QR scanner auto-dismiss**: scanning an npub QR in Add Member now dismisses the camera immediately instead of lingering (iOS & Android)
- **Add Member tap targets** (iOS): fixed `.buttonStyle(.borderless)` and 44pt minimum touch targets so the QR and Add buttons don't steal each other's taps
- **Map group filter** (iOS): groups with a pending leave request are now hidden from the map filter picker; selection auto-clears when a leave is requested
- **Admin leave approval UX**: members requesting to leave now show a green "Approve" swipe action (iOS) or "Approve" button (Android) instead of the generic destructive remove gesture

### Changed
- **Version bump** — iOS 0.9.4 (build 14), Android 0.9.4 (versionCode 11)

---

## [0.9.3] — 2026-04-02

### Security
- **Commit/Welcome ordering** (MIP-02): commit events are now verified on the relay before the Welcome is sent, preventing state forks where a joiner processes a Welcome but other members can't fetch the corresponding commit
- **Post-join self-update** (MIP-02): new members immediately rotate key material after joining a group, limiting the KeyPackage exposure window
- **Gift-wrap retry expiry**: stale/unrecoverable gift-wrap event IDs are purged after one retry pass to prevent infinite retry spam

---

## [0.9.2] — 2026-04-01

### Added
- **Dark mode setting** — three-way Appearance picker (System / Light / Dark) in Settings on both iOS and Android; takes effect immediately without restart
- **Splash screen rebrand** — replaced SF Symbol logo with Whistle wordmark + zap icon (transparent PNG) on both platforms; simplified to a clean loader with progress indicator

### Changed
- **Version bump** — iOS 0.9.2 (build 12), Android 0.9.2 (versionCode 9)

---

## [0.9.1] — 2026-04-01

### Changed
- **Settings / Advanced split** — main Settings screen now shows Identity (Nostr key + display name), Location, and About; Import/Export Key, Security, Relays, and Connection moved to a new Advanced Settings screen (both platforms)
- **Android About section** — added missing Protocol ("Nostr & MLS & Marmot") and GitHub source link to match iOS
- **Version bump** — iOS 0.9.1 (build 11), Android 0.9.1 (versionCode 8)

---

## [0.9.0] — 2026-04-01

### Security
- **MLS database encryption at rest** — MDK SQLite database is now opened with SQLCipher via `newMdk(serviceId:dbKeyId:)` on both iOS and Android; previously used `newMdkUnencrypted`, leaving all MLS group keys, exporter secrets, and key packages in plaintext on-device storage
- **Key management via keyring-core** — the MDK handles 32-byte encryption key generation and storage internally through `keyring-core`, using the platform's native credential store (iOS Keychain / Android Keystore) — no app-level key management required
- **Stale DB resilience** — if an existing plaintext DB cannot be opened with the encryption key, it is deleted and recreated encrypted (force-reinstall policy; no migration)
- **iOS file sharing removed** — `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` removed from `Info.plist` now that the DB is encrypted
- **MDK binary updated** — pinned revision advanced to `c58a77f` (from `80eab77`)

### Notes
- Pre-0.9 installs must be fully uninstalled before installing 0.9 (alpha policy — no migration)
- Verify encryption: `sqlite3 /path/to/findmyfam-mdk.db "PRAGMA integrity_check;"` should return `Parse error: file is not a database`

---

## [0.8.6] — 2026-04-01

### Fixed
- **QR invite code** — iOS invite share sheet now encodes the raw base64 invite code in the QR, matching Android; previously encoded the full `whistle://invite/` deep link URL
- **Remove "Share my key with admin"** — dropped the post-join `ShareLink` from `JoinGroupView`; the admin can scan the invitee's npub QR directly via the Scan QR action in Group Details
- **Map group filter stale after leave/evict** — group filter now auto-clears on both platforms when the selected group is left or evicted (iOS `onChange`, Android `LaunchedEffect` + `clearFilterIfInvalid`)
- **Unread indicator reappears after pull-to-refresh** — MDK's `lastMessageAt` advances for every MLS event including location updates and nickname changes, not just chat messages; introduced a dedicated `lastChatTimestamps` store (iOS UserDefaults / Android SharedPreferences) updated only when a chat message arrives, so pull-to-refresh no longer re-triggers the unread dot for non-chat activity
- **Version string in Settings** — iOS and Android Settings screens now read the version dynamically from the build config (`CFBundleShortVersionString` / `PackageManager.versionName`) instead of a hardcoded string

### Changed
- **Xcode project rename** — project, app target, scheme, `PRODUCT_NAME`, and entitlements file renamed from `FindMyFam` → `Whistle` in `project.yml`
- **`FindMyFamCore` → `WhistleCore`** — Swift package directory, `Package.swift`, source/test dirs, and all imports renamed
- **`FindMyFamTests` → `WhistleTests`** — test source directory and `project.yml` path updated
- **Version bump** — iOS 0.8.6 (build 9), Android 0.8.6 (versionCode 6)

### Notes
- Bundle identifiers (`org.findmyfam`) and Android package name unchanged
- Run `xcodegen generate` after pulling to regenerate the `.xcodeproj` with the new target/scheme names

---

## [0.8.5] — 2026-03-31

### Changed
- **Branding refresh** — user-facing app name updated from Famstr to Whistle on iOS and Android (launcher label, splash title, lock prompts, and permission copy)
- **Deep-link migration** — moved invite/member approval links from `famstr://` to `whistle://` across iOS, Android, shared models, tests, and docs
- **URL scheme registration** — updated app URL handling configuration to register the `whistle` scheme on both platforms
- **Bonjour service rename** — updated local discovery services from `_famstr` to `_whistle` and regenerated iOS project outputs
- **App icons/logo** — updated launcher icon assets for both platforms to the new Whistle branding pack
- **Version bump** — iOS 0.8.5 (build 8), Android 0.8.5 (build 5)

### Notes
- Package and namespace identifiers remain unchanged (`org.findmyfam`)

---

## [0.8.4] — 2026-03-27

### Added
- **Shared core libraries** — extracted models, protocol constants, and shared logic into platform-specific internal libraries (`FindMyFamCore` Swift package on iOS, `:shared` Gradle module on Android) with full test suites (44 tests each)
- **Protocol spec** — `docs/wiki/PROTOCOL.md` documenting all Marmot event kinds, JSON payload schemas, app defaults, and deep-link URL schemes
- **`AppDefaults`** — centralised shared constants (default relays, intervals, preference keys) referenced by both platforms

### Changed
- Default relays aligned across platforms (`relay.primal.net` replaces `relay.nostr.band` on Android)
- Version bump — iOS 0.8.4 (build 7), Android 0.8.4 (build 4)

### Fixed
- **`testFetchMissedGiftWrapsRetriesPendingGiftWrapIds`** — test was silently no-oping due to nil `settings`; now injects `AppSettings.shared` before asserting

---

## [0.8.3.2] — 2026-03-27

### Fixed — Android
- **Indoor location sharing** — removed OS-level distance filter (`0f`) and time gate (`0L`) from `LocationManager` so updates fire when stationary indoors; rate limiting is now handled solely by the app-level `intervalSeconds` throttle, matching iOS behaviour
- **Map filter lost on navigation** — group filter selection on the family map is now preserved when switching tabs; `LocationViewModel` moved from composable `remember {}` scope into `AppViewModel` so it survives navigation

### Changed
- **Android version bump** — 0.8.3.2 (build 3)

---

## [0.8.3.1] — 2026-03-26

### Fixed — Android
- **QR invite join** — scanned `whistle://invite/` deep-link URLs now correctly stripped to raw base64 before decoding; previously the prefix caused silent decode failure
- **App lock bypass** — lock screen now has opaque background and consumes all touch events; previously the app was fully navigable behind the biometric prompt
- **Duplicate member crash** — LazyColumn keys use index suffix to prevent crash when MDK returns duplicate leaf nodes for the same identity
- **Keyboard dismiss on send** — chat input keyboard now dismisses after sending a message
- **Relay list in Settings** — added missing relay section with enable/disable toggles per relay
- **QR scan navigation** — scanned invite code now passed via shared Compose state instead of savedStateHandle which was silently failing across navigation entries
- **Member list dedup** — `getMembers()` results deduplicated with `.distinct()` in both GroupDetailViewModel and ChatViewModel

### Fixed — iOS
- **Add Member by npub** — admin GroupDetailView now has a manual npub/hex input field to add members directly (was missing from UI despite ViewModel support)

### Changed
- **Android version bump** — 0.8.3.1 (build 2)

## [0.8.3-android] — 2026-03-26

### Added — Android
- **Android app** — full native port using Kotlin, Jetpack Compose, and Hilt DI
- **Cross-platform messaging** — Android and iOS devices communicate via the same MLS-encrypted Nostr groups
- **OpenStreetMap** — family map using osmdroid (no Google Play Services dependency, works on GrapheneOS)
- **Location sharing** — Android LocationManager with configurable throttle, broadcasts to all groups
- **QR code flow** — ZXing generation on invite share, CameraX + ML Kit scanner on join
- **NIP-49 key import/export** — encrypted backup and cross-platform identity transfer
- **Biometric app lock** — BiometricPrompt with fingerprint/face/device credentials
- **Settings** — display name, relay config, location interval, key rotation, app lock
- **MDK Kotlin bindings** — built from mdk-uniffi crate for arm64-v8a and x86_64
- **NostrSDK Kotlin** — rust-nostr v0.44.2 via Maven Central

### Architecture
- Monorepo: iOS at root, Android in `android/` directory
- Shared CHANGELOG and ROADMAP across platforms
- Pre-built native `.so` libs checked in; rebuild instructions in `android/BUILD.md`

## [0.8.3] — 2026-03-25

### Added
- **Automatic key rotation** — MLS group encryption keys are rotated via self-update (epoch advance) on a configurable schedule (default 7 days); stale groups are rotated on launch and rechecked every 6 hours while the app is active
- **Key Rotation Interval setting** — picker in Security settings (1 / 3 / 7 / 14 / 30 days) to control rotation frequency
- **Forward secrecy audit logging** — structured logs track epoch transitions (old → new) on rotation and incoming commits; unprocessable events confirm old epoch keys are deleted per RFC 9420 §14.1
- **Epoch mismatch warning** — groups with persistent decryption failures show a "Decryption failed" badge in the group list and a red banner in the chat view advising re-invite

### Fixed
- **Map group filter** — left/inactive groups no longer appear in the group picker on the family map
- **Key package relay broadcast** — key packages now published to all enabled relays on invite accept, fixing race condition where admin couldn't fetch the invitee's key package

### Changed
- **Version bump** — app version updated to 0.8.3 (build 6)

## [0.8.2] — 2026-03-25

### Added
- **Identity export (NIP-49)** — encrypt your private key with a password and export as an ncryptsec string for secure backup or transfer
- **Identity import** — import an existing Nostr identity from a plaintext nsec or encrypted ncryptsec, replacing the current keypair
- **Import / Export Key settings page** — new sub-page under Identity in Settings with dedicated export and import flows
- **Full identity replacement** — importing a key tears down all key-bound state (MLS groups, caches, relay subscriptions) and restarts the app with the new identity

### Changed
- **IdentityCardView** — updated informational text to mention encrypted backup availability
- **Version bump** — app version updated to 0.8.2 (build 5)

### Fixed
- **Startup UI responsiveness** — relay connect and MLS init now run in parallel (`async let`), `Task.yield()` drains the main run loop between heavy steps, and `startSubscriptions()` no longer blocks `onAppear()` with its infinite notification loop
- **Deferred post-ready work** — nickname broadcast and key-package refresh now run after the splash dismisses so the UI becomes interactive sooner

## [0.8.1] — 2026-03-24

### Added
- **App Lock security layer** — optional lock screen shown at app launch to protect app access
- **Security settings controls** — new Settings toggles for App Lock and "Require Unlock on Reopen" session behavior
- **Explicit passcode path** — lock screen includes a dedicated "Use Passcode" action for reliable non-biometric unlock
- **Map mode selector** — toolbar menu on the family map to switch between Default and Satellite views

### Changed
- **Authentication flow hardening** — lock lifecycle no longer repeatedly re-triggers auth around scene phase changes
- **Version bump** — app version updated to 0.8.1 (build 4)

### Fixed
- **Face ID setup issue** — added `NSFaceIDUsageDescription` to app configuration and plist generation source
- **"Authentication cancelled" noise** — expected cancel/system-cancel cases no longer surface as persistent lock errors
- **Passcode fallback regression** — explicit passcode action now routes to passcode-only evaluation instead of re-triggering Face ID

## [0.7.3] — 2026-03-24

### Fixed
- **Group details compile regression** — fixed member removal swipe action scoping in `GroupDetailView` (`member` is now resolved correctly in row scope)
- **Settings compile regression** — corrected `SettingsView` structure/scope and switched app-settings navigation to SwiftUI `openURL`
- **Export compliance key** — restored `ITSAppUsesNonExemptEncryption=false` in `Info.plist`

### Changed
- **About projects links** — Settings now shows direct links to Nostr, OpenMLS, and Marmot Protocol project pages

---

## [0.7.2] — 2026-03-22

### Fixed
- **Delayed welcome handling** — gift-wrap events that fail with "No matching key package" are now queued for retry, and retries are run after key package refresh
- **Pending welcome retry** — `fetchMissedGiftWraps()` now re-checks pending failing gift-wrap IDs in addition to new relay events

### Changed
- **Key package refresh now triggers welcome fetch** — `AppViewModel` calls `marmot.fetchMissedGiftWraps()` after refreshing key packages for pending invitations

---

## [0.7.1] — 2026-03-22

### Fixed
- **Member count stale after removal** — member count in group list and chat header now updates immediately when a member leaves or is removed
- **Member list subtitle in chat** — fixed member names not displaying in group chat header subtitle; now loads on view appearance and updates when membership changes
- **Stale member names after removal** — ChatViewModel now subscribes to membership change events and refreshes member names when members join/leave
- **Cache cleared on failed remove** — `removeMember()` now only clears cached locations after successful group event publication, preventing cache corruption on MLS errors
- **Overzealous cache clearing** — changed group member removal to clear only the removed member's location instead of all members in the group
- **Missing state refresh on proposal events** — MarmotService now calls `refreshGroups()` and notifies subscribers on `proposal` and `pendingProposal` event processing, ensuring consistent UI updates across all event types

### Changed
- **Member removal fine-grained** — introduced per-member location cache removal (`LocationCache.removeLocation()`) instead of batch group clearing for better UX when admins manage members

---

## [0.7.0] — 2026-03-17

### Added
- **AirDrop / deep-link invites** — invites are now shared as `whistle://invite/<code>` URLs; accepting an AirDrop or tapping a link opens the app and pre-fills the Join Group sheet — no copy-paste required
- **QR code scanning** — "Scan QR Code" button in Join Group opens a live camera scanner; pointing at an inviter's QR code auto-populates and submits the join request
- **NFC read** — "Tap NFC Tag" button (iPhone 7+) reads an NDEF invite URL from any NFC tag and auto-joins
- **NFC write** — "Write to NFC Tag" button in the Invite sheet writes the `whistle://` invite URL to a blank NFC sticker; anyone can tap their phone to the sticker to join
- **One-tap member approval** — after joining, invitee can share a `whistle://addmember/` URL with the admin; admin tap approves without pubkey copy-paste
- `InviteCode.asURL()` — wraps the base64 code in a `whistle://invite/` deep-link URL
- `InviteCode.from(url:)` — decodes an invite from a `whistle://` URL or raw base64 (backwards compatible)
- `InviteCode.approvalURL(pubkeyHex:groupId:)` — builds a `whistle://addmember/` approval deep link for admin confirmation flow
- `NFCReadCoordinator` — `@StateObject` helper for NDEF tag reading
- `NFCWriteCoordinator` — `@StateObject` helper for writing NDEF URL records to NFC tags
- `QRScannerView` — AVCaptureSession-based QR scanner with scan-frame guide

### Changed
- **InviteShareView** — "Share" button now shares the `whistle://` URL (AirDrop auto-handles it); QR now encodes the URL; legacy raw code still shown for copy
- **JoinGroupView** — accepts `initialCode` param for deep-link/QR/NFC pre-fill; added QR scan and NFC read buttons

---

## [0.6.1] — 2026-03-17

### Added
- **Auto centre self on map** — map auto-centres on own pin when location first appears; "locate me" button (location arrow) in toolbar re-centres on self at any time
- **Next-update countdown** — own location pin shows "in X min" countdown to the next scheduled broadcast instead of "X ago"; other members' pins continue to show elapsed time

---

## [0.6.0] — 2026-03-17

### Added
- **Pending group join state** — after accepting an invite, a "Pending" row appears in the group list until the Welcome event arrives; state persists across app restarts (`PendingInviteStore`, UserDefaults-backed)
- **Offline catch-up** — subscriptions now use a `since` filter based on the last processed event timestamp, so missed events are replayed when reconnecting after an offline period
- **Subscription retry loop** — if the Nostr notification stream drops (relay disconnect, network change), automatically reconnects and resumes subscriptions with backoff
- **MLS crash resilience** — `GroupHealthTracker` monitors consecutive processing failures per group; groups exceeding the threshold (5) show an "Out of sync" warning badge in the group list
- **Startup epoch cleanup** — `clearPendingCommit()` called for all groups on launch to recover from mid-commit crashes
- **Background location audit logging** — foreground/background mode logged on every location callback for debugging wake intervals
- **File sharing enabled** — app container visible in Finder/Files for MLS database inspection (temporary, until SQLCipher encryption is restored in v0.7)
- `GroupHealthTracker` — tracks consecutive MLS failures per group, resets on success
- `PendingInvite` model — Codable struct for pending group invites
- `PendingInviteStore` — UserDefaults-backed store with auto-cleanup on Welcome receipt
- 15 new unit tests for `PendingInviteStore` (8) and `GroupHealthTracker` (7)

### Changed
- **SettingsView polish** — Display Name label no longer wraps on narrow screens (`.lineLimit(1)`), Update Interval picker has clock icon, Authorization row has shield icon
- `MarmotService.startSubscriptions()` — refactored into retry loop with `openSubscriptionsAndListen()` inner method
- `MarmotService.handleGroupEvent()` — records success/failure in health tracker
- `MarmotService.handleIncomingEvent()` — updates `lastEventTimestamp` high-water mark on success
- `GroupListViewModel` — receives `PendingInviteStore` and `GroupHealthTracker`, forwards their changes
- `GroupRowView` — shows "Out of sync" badge for unhealthy groups
- `AppViewModel` — owns `PendingInviteStore`, wires to MarmotService, cleans up resolved invites on startup
- Version bumped to 0.6.0

---

## [0.5.1] — 2026-03-16

### Added
- Display name auto-broadcast — nicknames sent to all groups on app launch, name change, group create, and group join
- `NicknameStore` seeded with own display name at startup
- `ChatViewModel` and `GroupDetailViewModel` reactively re-resolve display names when `NicknameStore` updates
- `MarmotService.lastJoinedGroupId` publisher for post-welcome nickname broadcast
- "Allow Always for Background Sharing" button in Settings when location is only "When In Use"
- 10-second location interval option for live debugging
- Own location now appears on the map immediately (self-cached before relay round-trip)

### Changed
- "Enable Location" button now requests "Always" authorization (needed for background location sharing)
- `AppViewModel` forwards `objectWillChange` from child ObservableObjects (`settings`, `locationService`, `relay`) so SettingsView re-renders when nested @Published properties change

### Fixed
- Display names not shown — only hex pubkey was visible because nicknames were never written to NicknameStore or broadcast to groups
- MDK "group not found" errors flooding console — demoted to debug (kind-445 subscription is relay-wide, so unknown group events are expected)
- **Groups lost on app relaunch** — rewrote `MLSService.initialise()` to never silently delete the database; removed the "last resort delete-and-recreate" path that was destroying group data
- **Groups empty on app relaunch** — moved `GroupListViewModel` ownership from inline SwiftUI construction (vulnerable to view identity resets) to `AppViewModel`; `refreshGroups()` now runs before `self.marmot` is published to the UI so groups are loaded before the chat tab renders
- **Zero location events** — `LocationService.startUpdating()` called CLLocationManager with `.notDetermined` authorization which silently does nothing on iOS 17+; now guards on authorization status and defers via `wantsUpdating` flag
- **Location callback nil (hasCallback=false)** — race condition where CLLocationManager delegate fires via Task after LocationService.init(), triggering `applyLocationPauseSetting()` before `onAppear()` wires the pipeline callback; now defers `startUpdating()` until pipeline is ready
- **Own location missing from map** — `broadcastLocation()` only sent to relay; relays don't echo back own events so own pin never appeared; now inserts into `LocationCache` immediately
- **SettingsView not reacting to changes** — nested ObservableObject problem: SwiftUI only observes AppViewModel's own @Published, not child objects; fixed by forwarding `objectWillChange` from settings, locationService, and relay
- **Location auth delegate auto-start** — `locationManagerDidChangeAuthorization` now checks `wantsUpdating` and `isUpdating` to auto-start deferred location updates when permission is granted
- **Location pipeline never wired** — `startSubscriptions()` calls NostrSDK `handleNotifications()` which runs an infinite event loop; everything after it in `onAppear()` was dead code (location wiring, nickname broadcast). Moved subscriptions to last step
- Chat messages displayed newest-first — reversed to natural chat order (oldest top, newest bottom) with `.defaultScrollAnchor(.bottom)`
- GroupDetailView stuck after adding a member — now auto-dismisses back to chat on success
- Update interval observer race — Combine subscriptions moved from async `onAppear()` to `init()`
- Throttle timer resets on interval change so shorter intervals take effect immediately
- Version bumped to 0.5.1

---

## [0.5.0] — 2026-03-16

### Added
- **Group chat** — end-to-end encrypted messaging via MLS
- `GroupListView` — Chat tab root showing group list with Create / Join actions
- `GroupChatView` — chat thread with message bubbles and send bar
- `ChatBubbleView` — right-aligned blue (me) / left-aligned grey (others) message bubbles
- `GroupRowView` — group list row with name, member count, last activity
- `CreateGroupView` — sheet for creating new groups
- `JoinGroupView` — sheet for joining groups via invite code
- `InviteShareView` — QR code + copy/share for invite codes
- `GroupDetailView` — member list, invite generation, admin member removal
- `ChatViewModel` — loads messages from MDK, observes incoming, sends via MarmotService
- `GroupListViewModel` — drives group list, create/join actions
- `GroupDetailViewModel` — member management, invite generation
- `ChatPayload` / `NicknamePayload` — Codable JSON schemas for chat and nickname messages
- `NicknameStore` — UserDefaults-backed pubkey → display name mapping
- Display Name field in Settings (broadcasts as nickname to groups)
- "Enable Location" button in Settings (fixes iOS permission prompt issue)
- Group picker in Map toolbar — filter pins by group
- `FMFLogger.chat` log category
- `NSCameraUsageDescription` for QR scanning
- 15 new unit tests for ChatPayload, NicknamePayload, NicknameStore, and MarmotService

### Changed
- `MarmotService` — routes chat/nickname sub-types, `lastChatMessageGroupId`, `activeRelayURLs`, `sendNicknameUpdate`
- `LocationViewModel` — `selectedGroupId` filter, NicknameStore integration for display names
- `AppViewModel` — wires NicknameStore, observes interval changes, `myPubkeyHex`
- `FamilyMapView` — group picker toolbar menu
- `RootView` — `GroupListView` replaces `ChatPlaceholderView`
- `SettingsView` — display name, location enable button, version 0.5.0
- Version bumped to 0.5.0

### Fixed
- Location authorisation prompt never appeared (was called too early in lifecycle)
- Update interval selector had no effect (interval changes now forwarded to LocationService)
- Update interval observer race — Combine subscriptions moved from async `onAppear()` to `init()` so they're active immediately
- Throttle timer resets on interval change so shorter intervals take effect without waiting
- Groups disappear on app restart — `refreshGroups()` now called on startup to reload from MDK database
- Chat tab stuck on "Connecting…" spinner — `marmot` property marked `@Published` for SwiftUI reactivity
- MLSService init failures on iOS 26 — 3-step recovery: keyring → local key → delete stale DB + fresh key
- Keychain unavailable on iOS 26 — UserDefaults fallback for identity persistence
- Noisy "MLSError.notInitialised" log spam — demoted to debug, subscriptions gated on MLS readiness
- Invite/join flow — admins can now add members by pasting npub/hex pubkey in Group Detail

---

## [0.4.0] — 2026-03-16

### Added
- **Live family map** — `FamilyMapView` with iOS 17 `Map { }` API replaces placeholder
- `LocationService` — CoreLocation wrapper with throttling and background-mode support
- `LocationCache` — in-memory cache of latest location per group member
- `LocationViewModel` — transforms cache entries into map annotations with stale detection
- `LocationPayload` — Codable model for location JSON payloads inside MLS messages
- `MemberLocation` — per-member location model with coordinate, stale check, display name
- `MemberPinView` — custom map annotation (blue = fresh, grey = stale)
- `MarmotService.sendLocationUpdate` — encode and send location as kind-1 application message
- `MarmotService.routeApplicationMessage` — decode incoming location messages to `LocationCache`
- Location section in Settings: pause toggle, interval picker (5m/15m/30m/1h), auth status
- 17 new unit tests for LocationPayload, LocationCache, and MarmotService location features

### Changed
- `MarmotService.sendMessage` now accepts explicit `kind` parameter (default: chat)
- `handleGroupEvent` routes application messages through `routeApplicationMessage`
- `AppViewModel` creates and wires `LocationService`, `LocationCache`, `LocationViewModel`
- `RootView` uses `FamilyMapView` instead of `MapPlaceholderView`
- Version bumped to 0.4.0

---

## [0.3.0] — 2026-03-16

### Added
- `MarmotService` orchestration layer bridging MLSService (MLS) ↔ RelayService (Nostr)
- Kind 443 — Key Package publishing and fetching
- Kind 10051 — Key Package Relay List publishing and fetching
- Kind 444 — Welcome delivery via NIP-59 gift-wrap
- Kind 445 — Group event publishing, message encryption/sending
- `RelayServiceProtocol` abstraction for testable relay I/O
- `MockRelayService` in-memory mock for unit tests
- `NotificationHandler` — relay subscription callback bridge
- `InviteCode` model — base64-encoded invite tokens for group sharing
- Subscription management — auto-subscribes to group events and gift-wraps
- Invite flow — `generateInviteCode` / `acceptInvite`
- 19 new unit tests for MarmotService, InviteCode, and integration
- `RelayService` extended with `sendEvent`, `fetchEvents`, `subscribe`, `handleNotifications`, `giftWrap`, `unwrapGiftWrap`
- `FMFLogger.marmot` logger category
- `MarmotKind.giftWrap` (1059) constant

### Changed
- `AppViewModel` now creates and wires up `MarmotService` on startup
- Version bumped to 0.3.0

---

## [0.2.0] — 2026-03-16

### Added
- `MLSService` actor wrapping mdk-swift (Marmot Dev Kit) for MLS group operations
- `MLSModels` — convenience types, Marmot event kind constants, sort order helpers
- `mdk-swift` SPM dependency pinned to commit `80eab77`
- 18 new unit tests covering key packages, group lifecycle, messaging, and self-update

### Changed
- `project.yml` — added `MDKBindings` package
- Renamed app to **Famstr** (display name, permissions, docs)
- Bundle ID changed from `com.findmyfam` to `org.findmyfam`
- Version bumped to 0.2.0

### Fixed
- Asset catalog not compiled into app bundle (moved `.xcassets` to `sources` in XcodeGen)
- Added explicit XcodeGen scheme with test action
- Set `DEVELOPMENT_TEAM` for device builds
- Added Famstr app icon (1024×1024)

---

## [0.1.0] — 2026-03-16

### Added
- XcodeGen project skeleton (`project.yml`), `scripts/build.sh`
- Nostr identity generation and Keychain persistence (`IdentityService`, `KeychainService`)
- `SecureStorage` protocol with `InMemorySecureStorage` for testability
- Relay connectivity with configurable relay list (`RelayService`, `RelayConfig`)
- `AppSettings` — UserDefaults-backed preferences (relays, location interval, pause toggle)
- UI shell: tab bar with Map, Chat, Settings placeholders
- Identity card with npub QR code display
- Settings view: identity, relays, connection status, about section
- `FMFLogger` — structured os.Logger categories
- `nostr-sdk-swift` 0.44.2 as SPM dependency
- 20 unit tests covering identity, relay config, and keychain abstraction
