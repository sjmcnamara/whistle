# Security Policy

## Supported Versions

Only the latest release is actively supported with security fixes.

| Version | Supported |
|---------|-----------|
| Latest  | ✅ |
| Older   | ❌ |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report security issues by email to **getwhistle@proton.me**. Because Whistle
handles real-time location data and uses end-to-end encrypted group messaging,
we treat all credible reports seriously and aim to respond quickly.

### Encrypting your report

The report address is a Proton Mail address with a published OpenPGP key, so
you can — and for anything sensitive, should — encrypt your report end-to-end.

- **Fingerprint:** `C8C5 5288 CDEF 60C5 956D 3211 6CC9 6B66 6ECA 571A`
- **Key:** [`getwhistle-pubkey.asc`](getwhistle-pubkey.asc) in this repository, or fetch it from Proton's keyserver:
  ```
  curl "https://api.protonmail.ch/pks/lookup?op=get&search=getwhistle@proton.me"
  ```

Proton publishes this key to its keyserver (and via WKD), so most OpenPGP-capable
mail clients discover and use it automatically when you compose to the address.
**Verify the fingerprint above before trusting a fetched key.**

### What to include

- A clear description of the vulnerability and its potential impact
- Steps to reproduce, or a proof-of-concept if you have one
- The version(s) affected (iOS, Android, or WhistleCore)
- Any suggested mitigations you have in mind

### What to expect

| Timeframe | Action |
|-----------|--------|
| **48 hours** | Acknowledgement of your report |
| **7 days** | Initial assessment and severity triage |
| **30 days** | Target resolution for confirmed vulnerabilities |
| **90 days** | Maximum embargo before coordinated disclosure |

We will keep you informed throughout the process and credit you in the release
notes unless you prefer to remain anonymous.

## Scope

Areas of particular concern given the nature of this app:

- **Location data leakage** — any path where a user's precise location could
  be exposed to unintended parties (relay operators, passive observers, etc.)
- **MLS group membership** — vulnerabilities that allow an attacker to join or
  impersonate a member of an encrypted location-sharing group
- **Key material exposure** — issues that could leak Nostr identity keys or MLS
  private key material
- **Fuzzing bypass** — ways to recover a user's true location when location
  fuzzing is active

## Responsible Disclosure

We follow a coordinated disclosure model. Please give us a reasonable window
to investigate and patch before publishing details publicly. In return, we
commit to acting promptly and keeping you informed at every step.

Thank you for helping keep Whistle and its users safe.
