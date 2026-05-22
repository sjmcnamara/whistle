# Whistle Protocol Specification

This is the wire-level reference for Whistle: the Nostr event kinds we use, the JSON payloads carried inside them, the defaults baked into the app, and the URL schemes that bootstrap a join.

Whistle sits on top of the [Marmot Protocol](https://github.com/marmot-protocol/marmot) (MIP-00 → 03) for MLS-over-Nostr. If you're reading this to build an interoperating client, you want to read the MIPs alongside this document — they define the cryptographic guarantees; this page tells you what bytes Whistle puts on the wire.

---

## MarmotKind — Nostr Event Kinds

All event kinds are defined in `MarmotKind` (iOS: `WhistleCore`, Android: `org.findmyfam.shared`).

| Constant             | Value | Description                                              |
|----------------------|-------|----------------------------------------------------------|
| `keyPackage`         | 30443 | MLS KeyPackage — addressable event published per device to advertise MLS credentials (MDK 0.8.0+). Previously `443`; see migration note below. |
| `welcome`            | 444   | Welcome — NIP-59 gift-wrapped invitation to join an MLS group |
| `groupEvent`         | 445   | Group event — all in-group traffic: Commits, Proposals, application messages |
| `keyPackageRelayList`| 10051 | KeyPackage relay list — advertises which relays hold key packages |
| `giftWrap`           | 1059  | NIP-59 Gift Wrap outer event kind                        |

!!! note "KeyPackage migration (v1.1.3 / MDK 0.8.0)"
    Earlier versions of Whistle used `kind:443` for KeyPackages. MDK 0.8.0 moved KeyPackages to `kind:30443` — an [addressable event](https://github.com/nostr-protocol/nips/blob/master/01.md#kinds) — so each device's latest package supersedes the previous one rather than accumulating. Current Whistle builds publish and subscribe to `30443` exclusively.

### Inner Message Kinds (inside kind-445 payloads)

A kind-445 event's `content` is an opaque MLS ciphertext. Once decrypted, it yields an unsigned inner event whose `kind` field tells the receiver how to route it.

| Constant        | Value | Description              |
|-----------------|-------|--------------------------|
| `chat`          | 9     | Chat message             |
| `location`      | 1     | Location update          |
| `leaveRequest`  | 2     | Member leave request     |

---

## Payload Schemas

All payloads are JSON-encoded strings stored in the `content` field of the inner unsigned event. The schema `v` field is the canonical version marker — bump it for any breaking change; add new optional fields without bumping it.

### LocationPayload

Inner kind: `1` (`MarmotKind.location`)

```json
{
  "type": "location",
  "lat": 51.5074,
  "lon": -0.1278,
  "alt": 10.0,
  "acc": 5.0,
  "ts": 1700000000,
  "batt": 87,
  "v": 1
}
```

| Field  | Type     | Required | Description                                          |
|--------|----------|----------|------------------------------------------------------|
| `type` | String   | yes      | Always `"location"`                                  |
| `lat`  | Double   | yes      | Latitude in decimal degrees                          |
| `lon`  | Double   | yes      | Longitude in decimal degrees                         |
| `alt`  | Double   | yes      | Altitude in metres (`0` if unavailable)              |
| `acc`  | Double   | yes      | Horizontal accuracy in metres                        |
| `ts`   | Int/Long | yes      | Unix timestamp (seconds since epoch)                 |
| `batt` | Int      | no       | Device battery level `0`–`100`; omitted if unknown. Added in v1.1.5 (Android) / v1.2.0 (iOS & Android parity). Drives Low Battery Alerts. |
| `v`    | Int      | yes      | Schema version — always `1`                          |

### ChatPayload

Inner kind: `9` (`MarmotKind.chat`)

```json
{
  "type": "chat",
  "text": "Hello!",
  "ts": 1700000000,
  "v": 1
}
```

| Field  | Type   | Description                           |
|--------|--------|---------------------------------------|
| `type` | String | Always `"chat"`                       |
| `text` | String | Message text                          |
| `ts`   | Int/Long | Unix timestamp (seconds since epoch)|
| `v`    | Int    | Schema version — always `1`          |

### NicknamePayload

Inner kind: `9` (`MarmotKind.chat`), distinguished from a chat message by the `type` field.

```json
{
  "type": "nickname",
  "name": "Dad",
  "ts": 1700000000,
  "v": 1
}
```

| Field  | Type   | Description                           |
|--------|--------|---------------------------------------|
| `type` | String | Always `"nickname"`                   |
| `name` | String | Display name the sender wants to use  |
| `ts`   | Int/Long | Unix timestamp (seconds since epoch)|
| `v`    | Int    | Schema version — always `1`          |

---

## AppDefaults

Defined in `AppDefaults` (iOS: `WhistleCore`, Android: `org.findmyfam.shared.models`). These are the values the app ships with — users can override most of them in Settings.

### Default Relays

Shipped at first launch; the user can add, disable, or remove them from Settings.

```
wss://relay.damus.io
wss://nos.lol
wss://relay.primal.net
```

### Default Intervals

| Constant                        | Value | Description                              |
|---------------------------------|-------|------------------------------------------|
| `defaultLocationIntervalSeconds`| 3600  | Default location sharing interval (1 hr) |
| `defaultKeyRotationIntervalDays`| 7     | Default MLS key rotation interval (1 wk) |

Movement Aware (v1.1.4+) multiplies the effective interval by 4× when the device is stationary, then resumes the configured rate once confirmed movement is detected.

### Preference Keys

All keys use the `fmf.` prefix for namespacing (legacy from the project's original "FindMyFam" name; the on-disk bundle ID remains `org.findmyfam` for continuity, though the product is now Whistle). Used in `UserDefaults` on iOS and `SharedPreferences` on Android.

| Key                             | Value                              |
|---------------------------------|------------------------------------|
| `Keys.relays`                   | `fmf.relays`                       |
| `Keys.displayName`              | `fmf.displayName`                  |
| `Keys.locationInterval`         | `fmf.locationInterval`             |
| `Keys.locationPaused`           | `fmf.locationPaused`               |
| `Keys.appLockEnabled`           | `fmf.appLockEnabled`               |
| `Keys.appLockReauthOnForeground`| `fmf.appLockReauthOnForeground`    |
| `Keys.lastEventTimestamp`       | `fmf.lastEventTimestamp`           |
| `Keys.processedEventIds`        | `fmf.processedEventIds`            |
| `Keys.pendingLeaveRequests`     | `fmf.pendingLeaveRequests`         |
| `Keys.pendingGiftWrapEventIds`  | `fmf.pendingGiftWrapEventIds`      |
| `Keys.keyRotationIntervalDays`  | `fmf.keyRotationIntervalDays`      |

---

## Location Cache Key Format

Locations are keyed in the in-memory cache by:

```
"<groupId>:<memberPubkeyHex>"
```

Example: `"abc123:deadbeef1234"`

A new payload for an existing key replaces the previous one; we never retain history.

---

## Staleness Detection

A `MemberLocation` is considered stale when:

```
now - payload.ts > intervalSeconds * 2
```

Where `intervalSeconds` is the configured location update interval (default: 3600 seconds). Stale pins render greyed-out on the map.

When Movement Aware is active, the effective interval is `intervalSeconds * 4` for stationary devices — pin timers and staleness checks both account for this.

---

## Display Name Truncation

When no nickname has been set for a member, `MemberLocation.displayName` falls back to the first 8 hex characters of `memberPubkeyHex` followed by a horizontal ellipsis (U+2026):

```
"abcdefgh…"
```

`NostrIdentity.shortNpub` returns an abbreviated npub for UI display:

- If `npub.count > 16`: `"<first 10 chars>...<last 6 chars>"`
- Otherwise: the full npub string

Example: `"npub1abc12...90xyz"`

---

## Deep Link URL Schemes

The app registers the `whistle://` URL scheme so other apps (Messages, Mail, AirDrop, QR scanners, NFC readers) can hand the user off into a join flow.

### Invite URL

Encodes a group invite as a base64-encoded JSON blob:

```
whistle://invite/<base64-encoded-invite-json>
```

The base64 payload encodes the following JSON:

```json
{
  "relay": "wss://relay.damus.io",
  "inviterNpub": "npub1...",
  "groupId": "<MLS group ID>"
}
```

### Approval URL

After the invitee publishes their KeyPackage, they share this URL back with the inviter to request admission:

```
whistle://addmember/<pubkeyHex>/<groupId>
```

Example: `whistle://addmember/abcdef1234/mygroup456`

---

## InviteCode Encoding

1. Serialise `{relay, inviterNpub, groupId}` as JSON
2. Base64-encode the UTF-8 bytes (standard base64, no wrapping)
3. Prepend `whistle://invite/` to produce the deep-link URL

Decoding accepts both `whistle://invite/<code>` URLs and raw base64 strings (for backward compatibility with text-pasted codes).

---

## PendingInvite

Tracks a published KeyPackage that has not yet received a Welcome event — the gap between "I asked to join" and "I'm in".

| Field         | Type   | Description                                        |
|---------------|--------|----------------------------------------------------|
| `groupHint`   | String | Group ID from the invite (used to match Welcomes)  |
| `inviterNpub` | String | Bech32 npub of the invite creator                  |
| `createdAt`   | Date/Long | When the key package was published              |

`id` = `groupHint`

---

## RelayConfig

| Field       | Type    | Description                              |
|-------------|---------|------------------------------------------|
| `id`        | UUID    | Unique identifier (generated locally)    |
| `url`       | String  | WebSocket relay URL (`wss://...`)        |
| `isEnabled` | Boolean | Whether the relay is active (default: `true`) |
