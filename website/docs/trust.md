---
title: Trust & security
---

# Trust &amp; security

Whistle's security model rests on the open primitives it's built on, not on
trusting us. Here's what that means in practice.

## What we promise

- **No servers store your data.** We don't run any. There's no Whistle account,
  no Whistle backend, no database with your trips in it.
- **No telemetry.** The app does not phone home. There are no analytics SDKs,
  no crash-reporter that ships your data to a third party, no A/B test framework.
- **Diagnostics stay on your terms.** The Share Diagnostics feature is always
  user-initiated and exported locally — never sent automatically. Reports are
  redacted: no messages, no locations, no names, and identifiers are truncated.
  It's a manual export you control, not telemetry.
- **Open source, forever.** Released under the [Unlicense](https://unlicense.org).
  Audit it, fork it, build it yourself.

!!! warning

    Whistle is currently in TestFlight beta. The protocol is based on proven
    cryptographic foundations (MLS and Nostr), but the application itself has
    not yet had a formal security audit. Treat current builds accordingly.

## What you must trust

- **Your phone.** The private key lives in the Secure Enclave (iOS) or the
  Android Keystore. If your device is compromised, your identity is too.
- **MLS and Nostr.** These are public, peer-reviewed protocols. We didn't
  invent the cryptography; we glued together two well-understood building
  blocks.
- **The relays you connect to.** Relays see ciphertext only, but they can see
  *that you're online* and *who you're talking to* (via routing metadata).
  Marmot mitigates this with metadata-protection techniques; we'll publish
  more detail as the spec matures.

## Reporting a vulnerability

See [SECURITY.md](https://github.com/sjmcnamara/whistle/blob/master/SECURITY.md)
in the source tree for the coordinated-disclosure process.
