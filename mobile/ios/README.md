# PairDesk iOS companion

Native SwiftUI companion for teammates who need to see presence, answer or place a call, and handle group-call join prompts away from their Mac. It uses the existing PairDesk email/password account and API host; the server can be overridden at sign-in. Calls use the repository's LiveKit Swift package.

## Scope

- Team roster and foreground availability toggle.
- Direct calls, accept/decline, active group call listing, join requests, and accept/decline prompts.
- LiveKit voice, mute, speaker routing, and optional camera video. Microphone turns on after joining; camera remains off until explicitly enabled and then uses the iOS camera permission prompt.
- Locally requested join approvals connect once, defer while another action is busy, and offer an explicit retry on a failed connection. Leaving does not replay accepted history. Remote media disconnects, the final peer leaving, and terminal room-heartbeat responses clear the active call.
- Saved sign-in survives offline or server errors, with **Retry saved sign-in** on the login screen. Only an authentication rejection (HTTP 401) discards the saved token.
- No mobile screen capture, screen sharing, remote control, account creation, SSO, or recording.

## Build

Open `PairDesk.xcodeproj` in Xcode 27+ and select an iOS simulator or device. The project uses the checked-in `../../vendor/livekit-client-swift` package. CLI build:

```sh
xcodebuild -project mobile/ios/PairDesk.xcodeproj -scheme PairDesk -sdk iphonesimulator -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Install on a device through Xcode with a locally selected development team. App Store/TestFlight or broad device distribution requires an Apple Developer Program account and signing setup.

Run `sh scripts/test-ios-model.sh` from the repository root to exercise the production app model and API with fixture media/notification adapters and HTTP responses. This checks approval, hang-up, and session recovery state without activating Keychain or device capture. CI also builds the actual iOS simulator app; audio, CallKit, and permission behavior still require physical-device verification.

## Existing server contract

- `POST /v1/login`, `GET /v1/me`, `POST /v1/logout` use the current opaque bearer session. The token is stored in Keychain.
- `GET /v1/users` returns online/busy teammate state. `POST /v1/heartbeat` extends the current user's presence for 30 seconds. The mobile availability toggle stops/starts those foreground heartbeats; switching off can take up to 30 seconds to disappear from the roster.
- `POST /v1/calls` creates a direct call (or invitation into the current room); `GET /v1/calls` polls invitations; `/accept`, `/decline` answer them.
- `GET /v1/active-calls`, `POST /v1/rooms/{id}/join-requests`, `GET /v1/join-requests`, and `/accept|decline` provide group-call discovery and consent.
- `POST /v1/rooms/{id}/join` returns the LiveKit URL, room token and participant identity. The app refreshes the room reservation heartbeat while connected and calls `/leave` on hang-up.

## Background notifications and presence limits

Foreground roster and call state poll the PairDesk API. Notification permission is requested only after a successful sign-in or restored session, not on the login screen. Once authorized, the app registers for standard APNs alerts and PushKit VoIP calls, then sends both token types with a stable installation ID to `POST /v1/devices`; logout removes the device with `DELETE /v1/devices/{deviceId}`. Standard APNs join-request alerts open the app and refresh the authenticated join-request list. PushKit direct-call payloads are reported promptly to CallKit; answering looks up the matching pending invitation through authenticated `GET /v1/calls`, accepts it, joins its LiveKit room, and enables the microphone when CallKit activates the audio session. Camera remains opt-in.

Background push requires a signed app with the Push Notifications capability, an `aps-environment` matching the provisioning profile, and server APNs credentials for the matching bundle ID. Debug uses `PairDesk/PairDesk.entitlements` with the development environment; Release uses `PairDesk/PairDeskRelease.entitlements` with the production environment. Until server push credentials and physical-device delivery are configured and verified, background ringing is not validated. The availability switch remains an account-level foreground heartbeat preference, not a promise of reachability on every device.

The current server contract has no separate per-device presence, and the desktop app may continue heartbeating the same account while the mobile toggle is off. Before presenting cross-device “online” as authoritative, the backend should distinguish device sessions and aggregate them into account presence. This iOS UI reports the server's existing account-level presence as-is.
