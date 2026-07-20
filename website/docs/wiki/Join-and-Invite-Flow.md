# Join and Invite Flow

Whistle has no central directory of users, so getting someone into a group is always an explicit, out-of-band handshake between the inviter (a group admin) and the invitee. The actual cryptography is the same regardless of which UI path was used; what differs is how the invite code travels from one phone to the other.

## The shared backbone

Every join is the same dance underneath the UI:

```
Inviter (admin)                                    Invitee
─────────────────                                  ─────────
1. Generate invite code  ──────[code travels]──→   2. Submit code
                                                   3. Publish KeyPackage (kind:30443)
                                                   4. Gift-wrap join-request (kind:1080) ↓
5. See pending joiner    ←──[join-request, kind:1080]
6. Batch-add invitee(s) to MLS (one commit)
7. Publish Commit + gift-wrapped Welcome
                         ─────[Welcome arrives]──→ 8. Process Welcome, join group
```

The invite code itself is just a base64-encoded JSON blob of `{relay, inviterNpub, groupId}` (see [PROTOCOL.md](PROTOCOL.md#invitecode-encoding)). Everything in the section below is just different ways of getting those few bytes from one phone to the other.

The join-request (`kind:1080`) is the key part of the current flow. Right after the invitee submits the code, their app gift-wraps a NIP-59 rumor to the inviter carrying their MLS **KeyPackage inline**. The admin sees the pending joiner and adds them (or several at once) in a single MLS commit — no manual npub exchange and no relay KeyPackage fetch. See [Invitee flow](#invitee-flow-detailed) and [Admin flow](#admin-flow-detailed) below.

## The four paths

How the invite code is transported is the user-facing choice. They all converge on the same `whistle://invite/<code>` URL that the Join Group sheet consumes.

| Path | Surface | Notes |
|------|---------|-------|
| **Manual paste** | Share sheet → copy → paste | The lowest common denominator. Works across any messenger. |
| **AirDrop / deep link** | Share sheet → AirDrop / Messages / Mail | Receiving device's OS opens Whistle and pre-fills the Join Group sheet. |
| **QR code** | Invite sheet shows a QR; Join sheet has a "Scan QR" button | Camera scanner auto-submits on a successful decode. |
| **NFC tag** | Invite sheet → "Write to NFC"; Join sheet → "Tap NFC tag" | Writes the `whistle://` URL as an NDEF record to any blank NFC sticker. Read on iPhone 7+ via Core NFC. |

## Invitee flow (detailed)

1. **Open Join Group** — either via deep link, QR scan, NFC read, or manually pasting the code into the sheet.
2. **Submit code (`acceptInvite`)** — the app decodes the invite to `{relay, inviterNpub, groupId}`, connects to the invite's relay (guaranteed common ground with the admin), persists a `PendingInvite{groupHint: groupId, inviterNpub, createdAt: now}`, and publishes the device's KeyPackage as a `kind:30443` event to all connected relays.
3. **Send join-request** — the app immediately gift-wraps a `kind:1080` join-request rumor to the inviter's pubkey, carrying its KeyPackage **inline** (as a `kind:30443` event JSON string) plus `groupId`, `pubkey`, and optional `name`. This is non-fatal on failure — if the gift-wrap fails, the admin can still add the invitee by npub via the manual fallback.
4. **Pending state** — the group appears in the group list with a "Pending" badge while the invite awaits approval.
5. **Background catch-up** — `fetchMissedGiftWraps()` polls the relays for any `kind:1059` gift wraps the device may have missed (e.g. arrived while the app was suspended).
6. **Welcome processing** — when the matching `kind:1059` arrives, the gift wrap is unwrapped (NIP-59 → NIP-44 → inner Welcome rumor), MDK processes the MLS Welcome, the device joins the group at the current MLS epoch, and the pending row clears.

If no Welcome arrives, the pending row stays put — the admin may not have approved yet, or may have approved on a different relay than the one the invitee is listening to.

## Admin flow (detailed)

The primary path is fully automatic — the admin never handles an npub by hand:

1. **Receive join-requests** — each gift-wrapped `kind:1080` rumor is unwrapped and stored in `JoinRequestStore`, keyed by group. The group's admin UI lists the pending joiners (by their `name` / pubkey).
2. **Batch-add (`addMembers`)** — the admin adds one or several pending joiners in a **single MLS commit**. Each request already carries the member's KeyPackage inline, so there is no relay fetch and no "key package not found" race. `mls.addMembers` produces one Welcome per member plus one Commit advancing the group's epoch just once for the whole batch. The operation is atomic: either the whole commit lands (published, verified, Welcomes routed) or the group is left unchanged.
3. **Publish the Commit** as a `kind:445` event to the group (with retry); wait for relay confirmation (per [MIP-02](https://github.com/marmot-protocol/marmot/blob/master/02.md)) before sending any Welcome, to avoid a fork.
4. **Route the Welcomes** — each Welcome rumor is gift-wrapped and published as a `kind:1059` event addressed to its member's pubkey (NIP-59 hides the sender's identity from the relay).

### Manual fallback (`whistle://addmember`)

If no join-request arrives (e.g. the invitee is on an older build, or the gift-wrap failed to land), the admin can still admit a member by hand: the invitee shares a `whistle://addmember/<pubkeyHex>/<groupId>` URL (or raw npub) back, and the admin fetches the invitee's KeyPackage from the relays (`kind:30443` query filtered by pubkey) and adds them. This is the legacy path the inline join-request replaced as primary; it remains available via deep link (`AppViewModel`) and the group's add-member QR scanner.

## Leave and rejoin

Leaving is symmetric to joining and similarly admin-mediated.

1. The leaver publishes a `kind:445` application message with inner kind `2` (`MarmotKind.leaveRequest`) to the group.
2. A `PendingLeaveRequest` is stored locally so the UI shows "Leaving..." while the request is in flight.
3. The admin sees the request, calls `mls.removeMembers([leaverLeafIndex])`, which produces an MLS Commit. The admin publishes the Commit as a `kind:445` event.
4. Every other member processes the Commit, advances the MLS epoch, and the leaver disappears from the group's roster.

Rejoining is a fresh join from scratch — there is no "rejoin" path; the leaver re-publishes a new KeyPackage (`kind:30443`, which supersedes the previous one since it's an addressable event) and goes through the invite flow again. Stale pending-leave markers are cleared on Welcome acceptance.

## Where this is implemented

- `Sources/Services/MarmotService.swift` — `acceptInvite` (invitee-side KeyPackage publish + join-request send), `addMembers` (admin-side batch add in one commit), join-request receive/store, gift-wrap unwrap loop
- `Sources/Services/JoinRequestStore.swift` — pending join-requests, keyed by group, awaiting the admin's batch-add
- `WhistleCore/Sources/WhistleCore/Models/JoinRequest.swift` — the `kind:1080` payload schema
- `Sources/Views/JoinGroupView.swift` — Join Group sheet (manual paste, QR scanner, NFC reader)
- `Sources/Views/InviteShareView.swift` — Invite sheet (QR display, NFC writer, AirDrop)
- `WhistleCore/Sources/WhistleCore/Models/InviteCode.swift` — encode / decode the invite and `whistle://addmember` URLs
- `Sources/Services/PendingInviteStore.swift` / `PendingLeaveStore.swift` / `PendingWelcomeStore.swift` — pending state machines
- Android counterparts under `android/app/src/main/java/org/findmyfam/` mirror the same flows
