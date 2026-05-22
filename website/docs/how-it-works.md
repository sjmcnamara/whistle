---
title: How it works
---

# How it works

Three open primitives bind together to do something that, until recently, wasn't
possible: real-time location sharing with no servers in the middle.

## Identity is a keypair

When you first launch Whistle, your phone generates a [Nostr](https://github.com/nostr-protocol/nostr)
keypair in the secure enclave. There is no signup, no email, no phone number.
The private key never leaves the device.

!!! note

    If you lose your phone without exporting your key, your groups will treat
    you as a new identity. This is by design — there is no recovery server
    that could be coerced into impersonating you.

## Groups use MLS

Each group is a forward-secure [MLS](https://www.rfc-editor.org/rfc/rfc9420.html)
session (RFC 9420). When a member joins or leaves, the group rekeys so past
traffic stays unreadable to them.

```swift
let identity = try IdentityService.generate()
let group = try await MLSService.createGroup(
    name: "Family",
    creator: identity
)
try await group.invite(member: alice)
```

## Relays carry only noise

Whistle uses [Marmot](https://github.com/marmot-protocol/marmot) to bind
Nostr identity to MLS group messages. Relays — the public servers that ferry
ciphertext between phones — see encrypted blobs and routing metadata, nothing
more.

| Layer | Sees |
| --- | --- |
| Your phone | Plaintext locations & messages |
| Group members' phones | Same |
| Relay | Encrypted blobs + pubkey routing only |
| Whistle (us) | Nothing. We run no servers. |

## Movement-aware battery

Location updates use Core Location's significant-change service when you're
stationary, and switch to higher-frequency tracking on detected movement. The
group also gets a low-battery heads-up before your phone dies.
