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

- `harnesses/Fuzz_*.swift` — one libFuzzer entry (`@_cdecl("LLVMFuzzerTestOneInput")`)
  per target. They reference WhistleCore's public types with **no** `import`,
  because `build.sh` compiles each harness together with the WhistleCore sources
  as a single module (see below).
- `Dockerfile` / `build.sh` — compile each fuzzer with `swiftc` on the OSS-Fuzz
  Swift toolchain and drop the `Fuzz_*` binaries in `$OUT`.
- Workflows: `.github/workflows/cflite_pr.yml` (per-PR, changed code) and
  `cflite_batch.yml` (scheduled + manual full run).

`build.sh` uses a direct `swiftc` invocation rather than SwiftPM because a Swift
fuzzer is awkward for SwiftPM on this toolchain: an executable target emits a
`<target>_main` shim that `-parse-as-library` (in the OSS-Fuzz `$SWIFTFLAGS`)
suppresses; a library target won't link a binary; and a `main.swift` file
auto-promotes back to an executable target. Compiling the small, Foundation-only
WhistleCore package straight into each fuzzer sidesteps all of that.

## Reproducing a crash

CFLite attaches the crashing testcase to the failed workflow run. The simplest
reproduction uses ClusterFuzzLite's own tooling against the same OSS-Fuzz Swift
image the CI build uses (the local macOS toolchain doesn't offer libFuzzer for
the Apple target triple):

```bash
# Build the image and run the affected fuzzer against the downloaded testcase.
docker build -t whistle-cflite -f .clusterfuzzlite/Dockerfile .
# then run the built Fuzz_<Target> binary from $OUT against crash-testcase
```

Locally on Linux you can also run `.clusterfuzzlite/build.sh` inside the base
image (it writes `Fuzz_<Target>` binaries to `$OUT`), then run
`$OUT/Fuzz_<Target> path/to/crash-testcase`.

## Findings

- **2026-07-22 — deeply-nested JSON crash (fixed).** `Fuzz_LocationPayload`
  crashed on 513 nested `[` in ~2s: Foundation's JSON scanner recurses per
  bracket with no depth cap and overflows the stack (reproduced on Apple
  Foundation too, so it hit the shipping iOS app). Since the decoders run on
  post-decrypt payloads, a hostile group member could remotely crash every
  recipient. Fixed by `JSONNestingGuard` (WhistleCore) + Android parity, with
  regression tests and this input seeded into the corpus.

## When a bug is found

1. Add the crashing testcase as a regression test in
   `WhistleCore/Tests/WhistleCoreTests` (decode must `throw`, not crash).
2. Fix the parser.
3. Mirror the fix in the Android parser — these schemas are parity-critical.
