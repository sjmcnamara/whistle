# Architecture

## Project Layout

```
Sources/                  ← iOS app target (Whistle)
├── Models/               ← Domain types (LocationPayload, InviteCode, etc.)
├── Services/             ← Core services (MLSService, RelayService, KeychainService, etc.)
├── ViewModels/           ← UI state (AppViewModel, GroupListViewModel, ChatViewModel, etc.)
└── Views/                ← SwiftUI views

WhistleCore/              ← Shared Swift package (imported by app + tests)
├── Sources/WhistleCore/  ← Protocol constants (MarmotKind), defaults (AppDefaults), shared models
└── Tests/WhistleCoreTests/

WhistleTests/             ← Unit tests for the app target

android/app/              ← Android app (Kotlin / Jetpack Compose)
├── services/             ← MLSService, IdentityService, RelayService, etc.
├── viewmodels/           ← AppViewModel, GroupListViewModel, etc.
├── ui/                   ← Compose screens (groups, settings, map, identity)
├── models/               ← AppSettings, shared types
└── shared/               ← MarmotKind, AppDefaults (mirrors WhistleCore)
```

## High-Level Components

- `AppViewModel`: App orchestration and startup wiring
- `MarmotService`: Protocol orchestration (Nostr + MLS event handling)
- `MLSService`: MLS group and crypto operations (wraps MDK via UniFFI)
- `RelayService`: Relay connectivity, subscriptions, and event publish/fetch
- `GroupListViewModel`, `GroupDetailViewModel`, `ChatViewModel`: UI-facing state and actions

## Shared Core (WhistleCore)

Cross-cutting protocol constants and models extracted into a Swift package so both the app target and test target can import them:

- `MarmotKind` — Nostr event kind constants (443, 444, 445, 1059, 10051) and inner message kinds (chat, location, leaveRequest)
- `AppDefaults` — default relays, intervals, preference keys
- Shared model types used across services and views

Android mirrors this via the `:shared` Gradle module (`org.findmyfam.shared`).

## Core Data and State Stores

- `AppSettings`: persisted app settings and event processing metadata
- `PendingInviteStore`: pending joins before Welcome is accepted
- `PendingLeaveStore`: pending leave requests awaiting admin confirmation
- `NicknameStore`: pubkey-to-display-name mapping
- `LocationCache`: latest location by group/member

## Event Kinds (Marmot)

- `443`: KeyPackage publish/fetch
- `444`: Welcome (gift-wrapped)
- `445`: Group events (commits, proposals, app messages)
- `10051`: KeyPackage relay list

## Key Flows

1. Invitee accepts invite, publishes key package.
2. Admin adds member by key package.
3. Welcome event is gift-wrapped and delivered.
4. Invitee accepts Welcome, group appears in list.
5. Chat/location messages flow as kind `445` app messages.

## Reliability Notes

- `fetchMissedGiftWraps()` is used as catch-up for missed Welcome events.
- Pending gift-wrap IDs are retried after key package refresh.
- Membership changes trigger group refresh and view-model updates.
