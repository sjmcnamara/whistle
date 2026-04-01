# Testing and CI

## Local Test Commands

```bash
./scripts/build.sh test
```

Alternative direct command:

```bash
xcodebuild test -scheme Whistle -destination "platform=iOS Simulator,name=iPhone 16"
```

## Common Local Issues

- Simulator destination mismatch
- Interrupted test run (exit code 130)
- Stale derived data after major changes

## Recommended Recovery Steps

1. Clean and regenerate project.
2. Re-run with explicit simulator destination.
3. If needed, clear derived data for this project.

## Test Focus Areas

- `MarmotServiceTests`: gift-wrap retry, pending ID retry path, join reliability
- `GroupHealthTrackerTests`: failure tracking and unhealthy thresholds
- Payload and store tests for persistence/encoding correctness

## When to Add Tests

- Any change to join/leave/rejoin logic
- Any change to pending state stores
- Any change to event processing retries or error handling
