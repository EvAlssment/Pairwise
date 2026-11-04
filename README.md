<p align="center">
  <img src="assets/pairwise-logo.svg" width="280" alt="Pairwise logo">
</p>

# Pairwise

Pairwise is an open-source macOS pairing app for small teams. It combines direct teammate calls, voice, optional camera video, full-display sharing, and optional remote mouse and keyboard control. Calls use LiveKit; the account and presence service is a small Go API. Optional transcripts run locally with Whisper Tiny. There is no cloud transcription. Self-service signup can be restricted by domain and configured for email verification.

Unanswered calls appear in Recent Calls for 30 days with a one-tap callback when the teammate is online. When APNs or FCM push is configured, the invited person's mobile devices also receive a missed-call alert.

The current client supports macOS 14 and later. It is an early-stage project; test it with non-sensitive accounts and machines before relying on it.

**Download the complete source:** [ZIP archive of the latest `main` branch](https://github.com/EvAlssment/Pairwise/archive/refs/heads/main.zip) · [browse the repository](https://github.com/EvAlssment/Pairwise)

**Download PairDesk:** [Open the PairDesk download page](https://evalssment.github.io/Pairwise/). It always points to the newest installable release, for either Apple silicon or Intel Macs.

**Current team UAT build:** [Pairwise 0.8.1, build 26](https://github.com/EvAlssment/Pairwise/releases/tag/pairwise-uat-0.8.1-build26). Download the single universal [PairDesk.dmg](https://github.com/EvAlssment/Pairwise/releases/download/pairwise-uat-0.8.1-build26/PairDesk.dmg) for either Apple silicon or Intel Macs running macOS 14 or later. The app is Developer ID signed and notarized. The release page also provides the app ZIP and SHA-256 checksums.

To install, open the DMG, drag PairDesk to Applications, and replace an older copy if macOS asks. Eject the DMG, then launch PairDesk from Applications. Existing app preferences and sign-in are normally retained when updating in place. Check **PairDesk → About PairDesk** for version 0.8.1; the build number is 26. The Finder Get Info panel shows the version but may not show the build number.

In-app updates are being introduced with the next stable updater-enabled release. Existing installations must first install that release once from the download page; after that, PairDesk checks for signed updates automatically and offers **Check for Updates…** from the menu-bar app’s contextual menu.

For this UAT deployment, sign-up requires an email verification code and is limited to the configured approved email addresses (currently the FuturePath domain plus an administrator-managed exception). If your email is not accepted, contact the team administrator. An older client may show “Email verification is required. Update PairDesk to create an account.” Install build 26 before trying to sign up again. At sign-in, confirm the team HTTPS server address; do not use a local `localhost` address for team UAT.

See the [tester quick start](docs/tester-quick-start.md) for installation, account setup, permissions, and first-call checks, plus [the release guide](docs/releasing.md) for build and signing details. The source on `main` can be newer than the latest published DMG; check the release page before installing.

The source ZIP contains tracked code and documentation; it is not an installable app. Whisper source and model files are downloaded separately by the preparation script and are not included in the repository.

## Screen sharing and macOS permissions

Pairwise uses Apple's native ScreenCaptureKit content-sharing picker. A person chooses a display in the macOS picker, and the app receives a capture filter for that selected display and session. Pairwise does not enumerate the desktop or ask for the broad Screen Recording permission. The picker still requires the person to choose what to share each time.

The menu-bar gear opens a dedicated Settings window with General, Audio, Screen Sharing, Camera, Privacy, and Permissions sections. Audio device choices, start-muted and call-sound preferences, adaptive screen quality, camera device and 360p/720p/1080p camera quality are available there. Camera and microphone capture remain off until enabled in a call.

**Settings → Screen Sharing** controls whether to review privacy choices before each display or region share. By default, saved hidden-app and notification preferences apply automatically; edit them under **Privacy**. Enable per-share review to hide individual windows for the current share. Window choices are temporary. Apple's source picker still opens for each new share, and saved exclusions are validated against current capture content before sharing starts. Closing or hiding Settings stops its microphone and camera tests.

On macOS 15.2 and later, Privacy settings can keep selected applications out of display or region shares. Configure hidden applications before sharing; Pairwise verifies those apps are available to ScreenCaptureKit and refuses the share if it cannot apply the exclusions. A hidden app that launches or exits during a share stops sharing. App exclusions hide every window of an app; macOS does not let Pairwise hide one browser tab independently. Sharing one window is available through the system picker, and Pairwise blocks sharing a window owned by a hidden app.

Remote mouse and keyboard input is optional. macOS requires the person at the shared Mac to grant Pairwise Accessibility access before input can be injected. Voice uses the microphone and camera video uses the camera only after the person enables each during a call. The app never starts capture, microphone, camera, or transcription just by launching.

The microphone menu lists **System default** separately from individual microphones and speakers, so the default-route alias does not repeat a hardware name. Devices are identified by their stable IDs. The screen-share menu offers **Entire display**, **Region**, and **Window**; each opens the matching macOS picker, and Region then opens the crop selector.

While sharing a display or region, named teammate cursors are also drawn on the sharing Mac’s desktop when PairDesk can exclude that overlay from capture. They use the same cursor colors as the viewer, let clicks and typing pass through, and clear when the viewer leaves the shared area, disconnects, or stops sending cursor presence. The overlay closes when sharing ends or changes source. On macOS 15.2+, the selected display’s capture filter explicitly excludes this local overlay. On older systems, or when the picker hides the display identity, PairDesk keeps the native share filter and disables the host-side overlay to prevent duplicate cursors in the transmitted video; viewers still see the cursor overlay in the shared-screen window. Window sharing remains view only.

While sharing, a click-through border in the app's accent color marks the selected display or cropped region. On macOS 15.2 and later it also follows a shared window as it moves or resizes. It stays visible across Spaces and full-screen apps, and disappears when capture stops or the call ends. On macOS 14–15.1 the custom border supports single-display setups; other sources retain the macOS sharing indicator because the native picker does not expose their identities on those versions.

During a call, each teammate’s microphone state is visible in the menu and shared-screen window: **Muted**, **Mic on**, or **Speaking**. It updates from microphone publications and mute events, including when someone starts muted or reconnects.

Incoming calls ring repeatedly until answered, declined, cancelled, or expired. When you place a call, a separate ringback tone repeats while you wait for an answer and stops on acceptance, decline, cancellation, expiry, or hang-up. Inviting someone into an already connected call stays silent. A short confirmation tune plays once a teammate is connected to the media room, and a distinct descending tune plays when the connected call ends, including when the other person hangs up. Unanswered, declined, and cancelled calls do not play the disconnect tune. All tones follow **Play call sounds** in settings; switching it off immediately silences playback.

Incoming calls also show a named popup with **Accept** and **Decline**. During a call, a teammate's join request shows **Add to call** and **Decline** in the same popup. It appears above other apps without taking keyboard focus and does not require notification permission. Additional requests wait in the popup's queue. Answering, declining, cancellation, expiry, leaving the call, or signing out clears the relevant prompt; another participant's response is reflected on the next poll. If a response fails, the popup displays the error and allows a retry.

Approvals for join requests made on this Mac connect when the current action finishes, even if approval arrives before the first pending poll. A failed connection offers **Retry joining** while admission remains valid. Leaving consumes the approval so old history cannot reconnect you. Group calls continue while at least two admitted participants remain, including after the original caller and recipient leave.

The current source adds automatic [bidirectional shared-screen copy/paste and optional call-wide text clipboard sharing](docs/clipboard-sharing.md), group-call join requests, separate named cursors, and adaptive screen quality up to 4K/30. Display sharing lets the sender keep the full display or select a region after the macOS picker. Receiver measurements (resolution, frame rate, packet loss, and RTT) feed back to the sharer; sustained congestion steps quality down, and stable recovery steps it back up. Cursor motion is coalesced and sent separately from reliable clicks and key transitions. Two-Mac testing is still required for crop alignment, real input, clipboard paste, join prompts, adaptive transitions, and perceived quality; automated tests do not prove those behaviors.

## Build and run locally

Prerequisites: macOS 14+, Xcode 16.3 or later with Swift 6.1+, Go, Docker with Compose, and CMake. The checked-in LiveKit client patch is under `vendor/livekit-client-swift`; its upstream base and changes are documented in [UPSTREAM_PATCHES.md](UPSTREAM_PATCHES.md).

```sh
git clone https://github.com/EvAlssment/Pairwise.git
cd Pairwise
sh infra/setup.sh
cd infra
docker compose -p pairwise-dev build api
docker compose -p pairwise-dev stop api
docker compose -p pairwise-dev run --rm --no-deps -it \
  --entrypoint /pairdesk-admin api create-user \
  --admin --name 'Your Name' --email you@example.com
docker compose -p pairwise-dev up -d
cd ../macos
swift run
```

The local service binds to loopback. Set the API address in Pairwise to `http://127.0.0.1:18080`. The first admin command prompts for a password. Admins create the rest of the team's accounts from the app. For a team on multiple networks, deploy the API and LiveKit with HTTPS/WSS and TURN/TLS; see [the self-hosting guide](docs/self-hosting.md).

To build the offline transcription helper and a standalone app bundle:

```sh
cd ..
sh scripts/prepare-whisper.sh
sh scripts/build-app.sh
```

The whisper.cpp source and Tiny model download into ignored `.cache/` and are checked against pinned revisions/checksums. They are not committed. Run `sh scripts/create-signing-identity.sh` once on the Mac that builds PairDesk, and `build-app.sh` signs every build with that same self-signed identity. Without it, `build-app.sh` stops because an ad-hoc build is a new app to macOS each time: the saved sign-in asks for the Mac password (twice) after every install, and permissions may need approval again. Set `PAIRDESK_ALLOW_ADHOC=1` to build ad-hoc deliberately. Distributing outside your team's Macs still requires a Developer ID signature and Apple notarization. See [Apple's notarization guide](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

## Tests

```sh
(cd server && go test -race ./... && go vet ./...)
(cd macos && swift test -j 4)
```

To review UI changes without a server or a call, `sh scripts/ui-snapshots.sh` renders the main screens with fixture data to PNG files in `.cache/ui-snapshots/` using a debug build.

The LiveKit integration test needs a running local stack and is exercised separately by `scripts/test-call.sh`. It includes app-level incoming ring, outgoing ringback, accept, connection confirmation, local and remote hang-up tunes, decline, and cancellation checks using real API and media connections with recorded sound playback. Remote microphone state is also checked through publication, mute/unmute, unpublish, and rejoin with audio devices disabled. Authenticated cursor-packet tests exercise the host’s real desktop overlay, names, movement, timeout, source changes, and disconnect cleanup using synthetic share geometry without recording a desktop. The Tests workflow runs the server checks, native suite, and integration tests on macOS with LiveKit v1.8.4. Hardware checks that require two Macs, OS permission prompts, sleep/wake, cross-network TURN, and audible output-device routing remain manual; automated tests cannot prove those behaviors. For the sharing indicator and host cursors, verify native-picker capture consent, cursor alignment and duplicate-free output on both Macs (including older macOS picker-only sessions), a full display, crop, and moving/resizing window on physical Macs; switch sources, stop via macOS, and end the call, checking that the border matches the transmitted area and clears correctly.

## Project map

- `macos/` — menu-bar app, call UI, LiveKit media, selected-display capture, control input, local transcription, and tests.
- `server/` — Go API for accounts, presence, direct call invitations, room admission, and LiveKit tokens.
- `infra/` — local Compose stack and generic production Compose/Nginx configuration.
- `scripts/` — local build, packaging, speech-runtime preparation, and integration checks.
- `vendor/livekit-client-swift/` — source vendor of LiveKit Swift SDK 2.17.0 with the native-picker filter track overload.

Read [the architecture notes](docs/architecture.md), [feature parity roadmap](docs/feature-parity.md), [release guide](docs/releasing.md), [self-hosting guide](docs/self-hosting.md), [GCP production deployment](docs/gcp-github-deploy.md), and [third-party notices](THIRD_PARTY_NOTICES.md) before operating a public server or redistributing a binary.

PairDesk's opt-in, read-only local coding-agent bridge is documented in [docs/local-agent-bridge.md](docs/local-agent-bridge.md). During a call, it can expose separately granted participant names, local transcript text, and on-demand still screenshots from a window the user selects in Apple's native picker. Screenshots are returned only to the local MCP client and are not stored by PairDesk.

See [docs/media-quality-benchmarks.md](docs/media-quality-benchmarks.md) for the CI synthetic benchmark scope and the separate physical Mac reference procedure.

If you are preparing a two-Mac test, start with the [tester quick start](docs/tester-quick-start.md) and use the full [physical Mac acceptance record](docs/physical-mac-acceptance.md) for results.

## License

Pairwise source code is MIT-licensed; see [LICENSE](LICENSE). Vendored and bundled third-party components keep their upstream licenses and notices. Open-source licensing does not grant rights to Apple's signing identities, service credentials, Whisper model downloads, or a team's user data.
