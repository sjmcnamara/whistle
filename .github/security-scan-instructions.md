# Whistle — security review focus areas

Supplementary instructions for the automated security review. CodeQL, ClusterFuzzLite,
and Dependabot already cover injection classes, memory safety in the fuzzed parsers, and
dependency CVEs. Do not duplicate them. Concentrate on what static analysis cannot see:
the correctness of this app's cryptographic and trust-boundary assumptions.

## Threat model in one paragraph

Whistle shares live location among a small group with no servers and no accounts. Group
membership is cryptographic (MLS / RFC 9420 via the Marmot Protocol over Nostr), never
relay-enforced. Relays are untrusted infrastructure: they see ciphertext and metadata, and
a malicious relay may drop, reorder, delay, or replay events, or serve attacker-chosen
ones. Other group members are semi-trusted — they can read group traffic by design, but
must not be able to escalate to admin actions or forge another member's identity. The
device itself is trusted while unlocked.

## Priority findings

**MLS and group state.** Anything that processes a Commit, Proposal, or Welcome without
verifying its sender is a current group member at the expected epoch. Epoch regressions or
accepted out-of-order commits. State mutated before a membership or admin check rather
than after it. Errors from the MDK swallowed in a way that leaves group state diverged
from what the user is shown. Any path that could add a member without a corresponding
commit reaching the rest of the group.

**Key material.** Private keys (nsec, MLS signing keys, the SQLCipher database key) read
into a type that outlives its use, logged, included in diagnostics, or written anywhere
other than Keychain / Android Keystore. Keychain accessibility classes weaker than
`WhenUnlockedThisDeviceOnly` for anything long-lived. Keystore entries that do not require
user authentication where the threat model implies they should. Key material crossing the
UniFFI boundary in a form that is not zeroised.

**Payload trust.** The app defines its own JSON payload schemas (location, chat, avatar,
nickname, battery, leave) carried inside MLS application messages. Decoding is a trust
boundary even though the transport is authenticated: treat a malformed or hostile payload
from a legitimate group member as in-scope. Unbounded allocations from a length field,
avatar images decoded without size limits, and timestamps trusted for ordering or
freshness without sanity bounds.

**Relay boundary.** Any code that trusts relay-supplied data it has not cryptographically
verified — event ordering, `created_at`, which relay an event arrived from, or the relay
hint in an invite code. Invite codes are attacker-supplied input: they arrive by QR, NFC,
AirDrop, and `whistle://` deep links. Check that a crafted invite cannot redirect traffic
to an attacker-chosen relay in a way that leaks group membership, nor cause a join to a
group the user did not intend.

**Location privacy.** The location fuzzing feature is a privacy control, not cosmetic. Any
path that publishes an unfuzzed coordinate when fuzzing is enabled, that leaks precise
location through a side channel (logs, diagnostics, caches, notification text), or that
retains history longer than the user's settings imply.

## Deliberately out of scope

- Denial of service, rate limiting, and resource exhaustion against relays.
- A malicious group member reading group content — that is the design.
- The absence of Tor / `.onion` support. Known and tracked, not a defect.
- Generic input validation with no demonstrated impact on the above.

## Reporting

Prefer few high-confidence findings over breadth. For each, state the concrete attack: who
the attacker is (relay, group member, someone handing over a crafted invite, someone
holding the unlocked device), what they control, and what they gain. If the impact stops
at "a member sees bad data they were entitled to see anyway", it is not a finding.
