# Join and Invite Flow

## User Paths

- Share invite via AirDrop/messages (`whistle://invite/<code>`)
- Scan QR from Join Group
- Nearby share (MultipeerConnectivity)
- NFC read/write path

## Invitee Flow

1. Open Join Group and submit invite code.
2. App publishes key package.
3. Invite is shown as pending until Welcome arrives.
4. `fetchMissedGiftWraps()` polls for missed Welcome events.
5. After Welcome acceptance, group appears in list.

## Admin Flow

1. Receive approval URL from invitee (`whistle://addmember/...`) or Nearby callback.
2. Add member to MLS group.
3. Publish commit and Welcome.

## Leave and Rejoin

- Leave request is sent as app message and marked pending.
- Admin confirms leave by removing member (MLS remove + commit publish).
- Rejoin path clears stale pending leave markers on join/Welcome acceptance.

## Nearby Notes

- Nearby browser shows admin device/display name.
- End state should return success only after invitee sends approval URL back.
