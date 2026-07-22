# ClusterFuzzLite

Continuous fuzzing for Whistle's untrusted-input parsers, run in GitHub Actions
via [ClusterFuzzLite](https://google.github.io/clusterfuzzlite/).

## What gets fuzzed and why

MLS gives us an encrypted, authenticated transport — but it says nothing about
the *contents* of an application message. Once a payload is decrypted, a
malicious-but-authenticated group member can hand our parsers arbitrary bytes.
That decode boundary is the real attack surface, and it lives in the shared
`WhistleCore` Swift package:

| Fuzz target             | Entry point                        | Threat |
|-------------------------|------------------------------------|--------|
| `Fuzz_InviteCode`       | `InviteCode.decode(from:)` / `.from(url:)` | Invite string via deep link / QR / paste |
| `Fuzz_LocationPayload`  | `LocationPayload.from(jsonString:)` | Inner kind-445 payload from any member |
| `Fuzz_ChatPayload`      | `ChatPayload.from(jsonString:)`     | Inner kind-445 payload from any member |
| `Fuzz_JoinRequest`      | `JoinRequest.from(jsonString:)`     | Gift-wrapped join-request rumor to an admin |

Each harness only asserts *no crash* — a `throw` on garbage is correct. A crash
(Swift trap, force-unwrap, overflow, ASan finding) is a bug.

## Layout

- `Dockerfile` / `build.sh` — build the `Fuzzing/` package on the OSS-Fuzz Swift
  toolchain and copy `Fuzz_*` binaries to `$OUT`.
- Harnesses live in `../Fuzzing/` (a standalone SwiftPM package, deliberately
  outside the app build and `swift test` CI so the libFuzzer link never leaks in).
- Workflows: `.github/workflows/cflite_pr.yml` (per-PR, changed code) and
  `cflite_batch.yml` (scheduled + manual full run).

## Reproducing a crash locally

libFuzzer for the Swift target triple is only offered on Linux in the current
toolchain, so reproduce on Linux (or a Linux container):

```bash
cd Fuzzing
swift build -c debug --sanitize=fuzzer --sanitize=address --static-swift-stdlib
.build/debug/Fuzz_LocationPayload path/to/crash-testcase
```

## When a bug is found

1. Add the crashing testcase as a regression test in
   `WhistleCore/Tests/WhistleCoreTests` (decode must `throw`, not crash).
2. Fix the parser.
3. Mirror the fix in the Android parser — these schemas are parity-critical.
