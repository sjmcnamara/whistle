# Whistle Protocol Specification

This document describes the wire protocol used by Whistle. It covers Nostr event kinds, JSON payload schemas, application defaults, and URL schemes. The protocol is built on top of the [Marmot Protocol](https://github.com/marmot-protocol/marmot) (MIP-00→03) for MLS-over-Nostr.

---

## MarmotKind — Nostr Event Kinds

All event kinds are defined in `MarmotKind` (iOS: `WhistleCore`, Android: `org.findmyfam.shared`).

| Constant             | Value | Description                                              |
|----------------------|-------|----------------------------------------------------------|
| `keyPackage`         | 443   | MLS KeyPackage — published by each device to advertise MLS credentials |
| `welcome`            | 444   | Welcome — NIP-59 gift-wrapped invitation to join an MLS group |
| `groupEvent`         | 445   | Group event — all in-group traffic: Commits, Proposals, application messages |
| `keyPackageRelayList`| 10051 | KeyPackage relay list — advertises which relays hold key packages |
| `giftWrap`           | 1059  | NIP-59 Gift Wrap outer event kind                        |

### Inner Message Kinds (inside kind-445 payloads)

These are carried in the `kind` field of the inner unsigned event within a kind-445 MLS application message.

| Constant        | Value | Description              |
|-----------------|-------|--------------------------|
| `chat`          | 9     | Chat message             |
| `location`      | 1     | Location update          |
| `leaveRequest`  | 2     | Member leave request     |

---

## Payload Schemas

All payloads are JSON-encoded strings stored in the `content` field of the inner unsigned event.

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
  "v": 1
}
```

| Field  | Type   | Description                                |
|--------|--------|--------------------------------------------|
| `type` | String | Always `"location"`                        |
| `lat`  | Double | Latitude in decimal degrees                |
| `lon`  | Double | Longitude in decimal degrees               |
| `alt`  | Double | Altitude in metres (0 if unavailable)      |
| `acc`  | Double | Horizontal accuracy in metres              |
| `ts`   | Int/Long | Unix timestamp (seconds since epoch)     |
| `v`    | Int    | Schema version — always `1`               |

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

Inner kind: `9` (`MarmotKind.chat`), distinguished by `type` field value.

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

Defined in `AppDefaults` (iOS: `WhistleCore`, Android: `org.findmyfam.shared.models`).

### Default Relays

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

### Preference Keys

All keys use the `fmf.` prefix for namespacing. These are used in UserDefaults (iOS) and SharedPreferences (Android).

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

---

## Staleness Detection

A `MemberLocation` is considered stale when:

```
now - payload.ts > intervalSeconds * 2
```

Where `intervalSeconds` is the configured location update interval (default: 3600 seconds).

---

## Nickname Truncation Format

`MemberLocation.displayName` returns the first 8 hex characters of `memberPubkeyHex` followed by an ellipsis character (U+2026):

```
"abcdefgh…"
```

`NostrIdentity.shortNpub` returns an abbreviated npub for UI display:
- If `npub.count > 16`: `"<first 10 chars>...<last 6 chars>"`
- Otherwise: the full npub string

Example: `"npub1abc12...90xyz"`

---

## Deep Link URL Schemes

The app registers the `whistle://` URL scheme.

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

The invitee shares this URL back with the inviter to request group admission:

```
whistle://addmember/<pubkeyHex>/<groupId>
```

Example: `whistle://addmember/abcdef1234/mygroup456`

---

## InviteCode Encoding

1. Serialise `{relay, inviterNpub, groupId}` as JSON
2. Base64-encode the UTF-8 bytes (standard base64, no wrapping)
3. Prepend `whistle://invite/` to produce the deep-link URL

Decoding accepts both `whistle://invite/<code>` URLs and raw base64 strings (for backward compatibility).

---

## PendingInvite

Tracks a published key package that has not yet received a Welcome event.

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
