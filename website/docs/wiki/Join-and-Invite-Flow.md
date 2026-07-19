# Join and Invite Flow

Whistle has no central directory of users, so getting someone into a group is always an explicit, out-of-band handshake between the inviter (a group admin) and the invitee. The actual cryptography is the same regardless of which UI path was used; what differs is how the invite code travels from one phone to the other.

## The shared backbone

Every join is the same three-step dance underneath the UI:

```
Inviter (admin)                                    Invitee
─────────────────                                  ─────────
1. Generate invite code  ──────[code travels]──→   2. Submit code
                                                   3. Publish KeyPackage (kind:30443)
                                                   4. Send approval URL back ↓
6. Add invitee to MLS    ←─────[approval URL]─────
7. Publish Commit + Welcome
                         ─────[Welcome arrives]──→ 8. Process Welcome, join group
```

The invite code itself is just a base64-encoded JSON blob of `{relay, inviterNpub, groupId}` (see [PROTOCOL.md](PROTOCOL.md#invitecode-encoding)). Everything in the section below is just different ways of getting those few bytes from one phone to the other.

## The five paths

How the invite code is transported is the user-facing choice. They all converge on the same `whistle://invite/<code>` URL that the Join Group sheet consumes.

| Path | Surface | Notes |
|------|---------|-------|
| **Manual paste** | Share sheet → copy → paste | The lowest common denominator. Works across any messenger. |
| **AirDrop / deep link** | Share sheet → AirDrop / Messages / Mail | Receiving device's OS opens Whistle and pre-fills the Join Group sheet. |
| **QR code** | Invite sheet shows a QR; Join sheet has a "Scan QR" button | Camera scanner auto-submits on a successful decode. |
| **NFC tag** | Invite sheet → "Write to NFC"; Join sheet → "Tap NFC tag" | Writes the `whistle://` URL as an NDEF record to any blank NFC sticker. Read on iPhone 7+ via Core NFC. |
| **Nearby share** (iOS) | Invite sheet → "Share Nearby" | Phone-to-phone over Bluetooth + Wi-Fi peer-to-peer via MultipeerConnectivity. No internet required for handoff. |

## Invitee flow (detailed)

1. **Open Join Group** — either via deep link, QR scan, NFC read, Nearby callback, or manually pasting the code into the sheet.
2. **Submit code** — the app decodes the invite to `{relay, inviterNpub, groupId}`, persists a `PendingInvite{groupHint: groupId, inviterNpub, createdAt: now}`, and publishes the device's KeyPackage as a `kind:30443` event.
3. **Pending state** — the group appears in the group list with a "Pending" badge while the invite awaits approval.
4. **Background catch-up** — `fetchMissedGiftWraps()` polls the relays for any `kind:1059` gift wraps the device may have missed (e.g. arrived while the app was suspended).
5. **Welcome processing** — when the matching `kind:1059` arrives, the gift wrap is unwrapped (NIP-59 → NIP-44 → inner Welcome rumor), MDK processes the MLS Welcome, the device joins the group at the current MLS epoch, and the pending row clears.

If no Welcome arrives, the pending row stays put — the admin may not have approved yet, or may have approved on a different relay than the one the invitee is listening to.

## Admin flow (detailed)

1. **Receive the approval URL** — either via NFC, Nearby callback, AirDrop, or a manually-shared `whistle://addmember/<pubkeyHex>/<groupId>` URL.
2. **Fetch the invitee's KeyPackage** from the configured relays (`kind:30443` query filtered by pubkey).
3. **MLS Add** — call `mls.addMembers(keyPackage)` which produces an MLS Welcome and a Commit advancing the group's epoch.
4. **Publish the Commit** as a `kind:445` event to the group; wait for relay confirmation (per [MIP-02](https://github.com/marmot-protocol/marmot/blob/master/02.md)).
5. **Gift wrap the Welcome** and publish as a `kind:1059` event addressed to the invitee's pubkey (NIP-59 hides the sender's identity from the relay).

## Leave and rejoin

Leaving is symmetric to joining and similarly admin-mediated.

1. The leaver publishes a `kind:445` application message with inner kind `2` (`MarmotKind.leaveRequest`) to the group.
2. A `PendingLeaveRequest` is stored locally so the UI shows "Leaving..." while the request is in flight.
3. The admin sees the request, calls `mls.removeMembers([leaverLeafIndex])`, which produces an MLS Commit. The admin publishes the Commit as a `kind:445` event.
4. Every other member processes the Commit, advances the MLS epoch, and the leaver disappears from the group's roster.

Rejoining is a fresh join from scratch — there is no "rejoin" path; the leaver re-publishes a new KeyPackage (`kind:30443`, which supersedes the previous one since it's an addressable event) and goes through the invite flow again. Stale pending-leave markers are cleared on Welcome acceptance.

## Nearby share notes (iOS-specific)

- The browser side shows the admin's device name and configured display name.
- Successful completion requires the round-trip: the invitee must publish their KeyPackage and pass the approval URL back to the admin *over the Multipeer session*. The sheet should only return success after the round-trip completes.
- If the round-trip fails, the user can fall back to manual paste or QR — the invite code is identical regardless of transport.

## Where this is implemented

- `Sources/Services/MarmotService.swift` — admin-side add-member flow, invitee-side join handling, gift-wrap unwrap loop
- `Sources/Views/JoinGroupView.swift` — Join Group sheet (manual paste, QR scanner, NFC reader)
- `Sources/Views/InviteShareView.swift` — Invite sheet (QR display, NFC writer, AirDrop, Nearby)
- `Sources/Services/NearbyShareCoordinator.swift` — MultipeerConnectivity coordinator
- `WhistleCore/Sources/WhistleCore/InviteCode.swift` — encode / decode the invite URL
- `Sources/Services/PendingInviteStore.swift` / `PendingLeaveStore.swift` / `PendingWelcomeStore.swift` — pending state machines
- Android counterparts under `android/app/src/main/java/org/findmyfam/` mirror the same flows; Nearby is iOS-only at present
