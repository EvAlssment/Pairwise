# PairDesk physical Mac acceptance record

Status: **pending**. This document is a test record, not evidence that a
physical-device run has passed. Complete it during an actual call between
physical Macs; simulator, fixture, unit, and local-server tests do not satisfy
this acceptance.

## Safety and test setup

- Use team test accounts and a blank local text editor containing synthetic
  text. Do not use customer data, credentials, real transcripts, or personal
  messages.
- Do not save or retain screen, camera, microphone, transcript, or call media.
  Use synthetic content only. Keep only pass/fail results, timing measurements,
  app/OS/hardware/network metadata, and redacted error categories. Measurement
  tools must not persist source footage; if they cannot avoid that, mark the
  affected measurement Not run.
- Install the same PairDesk build from Applications on every Mac. Record the
  source commit, app version/build, API host label, macOS version, Mac model and
  chip, display scaling, and whether the selected ICE route is direct or relay.
  Do not record serial numbers, account names, email addresses, public IPs, or
  access tokens.
- On the sharing Mac, grant Accessibility to the exact installed app copy.
  Confirm screen capture is selected in Apple's picker. Run each call once
  with the host's mouse idle and once with the host actively taking control.
- Test both Mac A sharing to Mac B and Mac B sharing to Mac A. Repeat on a
  direct path and a second network path where available.

## Run metadata

Fill this section for each run. Duplicate it for additional builds or network
conditions.

| Field | Value |
|---|---|
| Run date/time (UTC) | Pending |
| PairDesk version/build and commit | Pending |
| macOS version on Mac A / Mac B | Pending |
| Mac model/chip on Mac A / Mac B | Pending |
| Display resolution/scaling on each Mac | Pending |
| Network type and city-level region on each Mac | Pending |
| Selected ICE route (direct/relay/unavailable) | Pending |
| Participants and role count (1:1 or 3–4) | Pending |
| Tester initials or role labels (no account identifiers) | Pending |
| Result owner | Pending |

## Acceptance matrix

Mark each row **Pass**, **Fail**, or **Not run** and include a short, content-free
note. A failure must be fixed and the entire affected scenario repeated.

| Scenario | Expected result | Result / evidence |
|---|---|---|
| Start a 1:1 call and share a display | The viewer opens automatically and receives the selected display without a separate join/configuration step. | Not run |
| First remote interaction after consent | First click or keystroke acquires control automatically; no repeated request/accept loop. | Not run |
| Pointer hover and independent cursors | Each viewer sees their own named/color cursor; hover does not move the host's native pointer or take the control lease. | Not run |
| Mouse move, click, double-click, drag and scroll | Actions target the displayed content correctly at Retina and scaled resolutions. | Not run |
| Text entry and modifiers | Type in a blank editor; verify Shift, Option, Command, Control, and common shortcuts. Text appears once in the focused field. | Not run |
| First input after idle | First input after at least 60 seconds works without a second click or manual lease request. | Not run |
| Viewer focus and app switching | Switching viewer focus, changing the host app, and returning does not leave held keys/buttons or stale control state. | Not run |
| Entire-display share across apps and Spaces | With Entire display selected, switch between ordinary apps, enter/leave a full-screen app, and switch Spaces on the same display. The viewer keeps receiving that display, including newly opened apps, without restarting sharing. Repeat with a region share; a window share stays limited to its selected window. | Not run |
| Remote viewer start/stop | Starting a remote share opens the viewer. Stopping it closes the viewer while the call stays connected; restarting opens it again. Repeat with the viewer minimized and full-screen. Manually closing the viewer keeps it dismissed until a new share starts or Show shared screen is selected. | Not run |
| Host local input takeover | Host movement, click, or key input immediately takes priority; remote input stops safely and can recover according to the visible state. | Not run |
| Host Stop and Resume | Stop revokes the lease and clears held input immediately. Resume restores the advertised availability only when permitted. | Not run |
| Emergency stop | Control–Option–Escape stops remote input and gives visible recovery feedback. | Not run |
| Display/source changes | Connecting/disconnecting an external display or changing the shared source does not mis-map input, freeze the viewer, or preserve a stale lease. | Not run |
| Accessibility revoked during sharing | Input stops, held keys/buttons are released, the call/view remains usable, and the UI identifies remote control as unavailable. | Not run |
| Network loss and recovery | Reconnection releases input safely, clears stale cursors, and restores call/control state without duplicate calls. | Not run |
| Sleep/wake and app termination | Sleep/wake, force quit, and relaunch leave no stuck input, busy roster state, duplicate session, or stale cursor. | Not run |
| Launch another PairDesk copy | Launching a copy from Applications while the installed app is running does not create another process, menu-bar item, API session, or presence heartbeat. The existing instance remains usable. Repeat from a mounted test DMG. | Not run |
| Hang up either side of a 1:1 call | Both clients become available; either person can immediately start another call. Repeat with each side ending. | Not run |
| Three- and four-person call | Join/leave requests work; one participant leaving does not strand the remaining pair; presence and cursors clear for the leaver. | Not run |
| Two networks | Repeat the four-person scenario with participants on at least two networks and record direct/relay route and measured RTT. | Not run |

## Measurements

Use test diagnostics only. Keep transport metrics separate from subjective
readability and hardware observations.

| Measurement | Method | Result |
|---|---|---|
| Share time-to-first-frame | From selecting a source to first rendered frame, milliseconds | Pending |
| Viewer resolution and FPS | At 60 seconds and 5 minutes | Pending |
| Selected-path RTT and packet loss | Viewer quality panel/diagnostics; note unavailable separately from zero | Pending |
| Share interruption and recovery | Count interruptions and seconds until frames resume | Pending |
| Pointer-to-visible response | At least 30 synthetic pointer actions; report p50/p95 and how measured. Any optical tool must not save source footage. | Pending |
| Sender and receiver CPU | Separate process measurements over the same steady 60-second interval | Pending |
| Readability | Smallest readable synthetic test-pattern text at 100% zoom; note scrolling result | Pending |
| Held-input safety | Confirm all keys/buttons released after every lifecycle row above | Pending |

## Additional device and operations coverage

Record these rows when the tested release claims the corresponding support.
These do not replace the issue #3 call and control matrix above.

| Scenario | Expected result | Result / evidence |
|---|---|---|
| Clean install and first launch | Document Gatekeeper outcome and first-run permissions for the tested distribution type; do not change macOS security settings. | Not run |
| Two-way voice, mute, and audio route | Both sides hear clearly; mute state is correct; verify selected input/output and recovery after route change. | Not run |
| Participant limit | Four participants can join; the next participant receives a clear capacity response; removal restores availability. | Not run |
| Window and multi-display sharing | Selected source remains aspect-correct; source changes do not strand the call or mis-target control. | Not run |
| Local transcript (if enabled) | Transcription starts only after consent, is labeled local, and cancels/cleans temporary audio on stop or call end. | Not run |
| Relay-only network | Verify configured TURN/TLS route and selected candidate type when direct UDP is unavailable; keep IPs and credentials out of the record. | Not run |
| Sustained call | Complete a 30-minute call, recording only quality metrics and interruption counts at fixed intervals. | Not run |
| Older supported hardware/OS | Record results only for hardware and macOS versions that the release claims to support. | Not run |

## Open-issue acceptance gates

These rows make the remaining issue-specific checks executable. Keep each result
**Not run** until its actual device or production path has been exercised. A
unit test, simulator, local LiveKit run, or green CI job is useful evidence but
does not replace a row that explicitly requires a physical device, signed
release, external client, or production delivery.

| Issue | Scenario | Pass evidence | Result / evidence |
|---|---|---|---|
| #1, #34 | Signed release and in-place update | Install a Developer ID-signed, notarized build from a clean download; pass Gatekeeper; update in place; confirm the app launches and previously granted permissions still work. Record both build versions and signatures. | Not run |
| #2 | Permission lifecycle | On macOS 14 and the current supported macOS, exercise fresh install, allow, deny, revoke, relaunch, update, and a second app copy. Verify the running copy's actual capability and retry behavior. Use a dedicated test Mac; do not reset TCC on a daily-use machine. | Not run |
| #5, #35 | Screen source, crop, adaptive quality, and readability | At 1440p30 and the 4K30 maximum, switch display/window/crop while sharing. Record viewer resolution/FPS, RTT/loss, first-frame and recovery time, and the smallest readable synthetic text at 100% zoom. Repeat on a second network and a 3–4 person call. Follow the detailed [media benchmark procedure](media-quality-benchmarks.md). | Not run |
| #6 | Audio device recovery | Test the built-in input/output and an external USB or Bluetooth device. Switch routes during a call, unplug/reconnect the active device, and verify mute, meter, selected-device display, fallback, and recovery. Confirm no microphone starts before explicit user action. | Not run |
| #27 | Camera opt-in and recovery | Confirm camera starts off. Enable it explicitly, inspect capture/receive dimensions and FPS, switch cameras, disconnect/reconnect the active device, and deny/revoke camera permission. Verify voice and screen sharing remain usable and no frames are recorded. | Not run |
| #29 | Mobile call and push lifecycle | On signed physical iOS and Android installs, test direct-call and join-request actions while foregrounded, backgrounded, and force-quit; cover accept, decline, expiry, token refresh, logout, audio routing, and camera opt-in. Record provider/build versions without APNs/FCM tokens. If managed credentials or devices are unavailable, leave this row Not run. | Not run |
| #30 | Native picker and external MCP client | During a real call, grant transcript and screenshot separately, invoke the bundled MCP bridge from a real external MCP client, approve Apple's on-demand picker, verify the returned image renders, then revoke and end the call. Confirm the helper cannot access content afterward and no content lands in the local audit log. | Not run |
| #31 | Privacy veil | Before sharing, configure a protected app/window and notification exclusion. Verify from the viewer that the first transmitted frame omits protected content; change apps/windows and switch sources; verify fail-closed behavior and local usability; confirm remote control stays disabled while protected content is hidden. Do not save the viewer image or source footage. | Not run |
| #32 | Annotations | On Retina/scaled displays and with crop/window changes, draw, laser-point, and clear from multiple participants. Confirm alignment, expiry on disconnect/share change, and that annotation gestures never click or type into the host Mac. | Not run |
| #7 | Recovery and alert delivery | Run an isolated restore from a real production backup, verify an existing account can authenticate after restore, and record recovery time. Separately verify the configured monitoring alert arrives in its destination inbox; an enabled policy or open alert alone is not delivery evidence. | Not run |

## Sign-off

Do not mark the issue accepted until every required matrix row has a result, the
two sharing directions and two network paths are covered, a 3–4 participant
call has completed, and failures have been fixed and rerun. Attach only
redacted diagnostic summaries and metadata. Keep screenshots, recordings, and
call content out of this repository.

| Reviewer role | Decision | Date (UTC) | Redacted notes |
|---|---|---|---|
| Mac A tester | Pending | Pending | Pending |
| Mac B tester | Pending | Pending | Pending |
| Call/operations reviewer | Pending | Pending | Pending |

## Shared-screen clipboard acceptance

Run the [two-Mac clipboard procedure](clipboard-sharing.md#two-mac-acceptance) for each release candidate. Automated tests replace OS shortcuts with a synthetic destination; they do not establish these physical outcomes.

| Scenario | Required result | Status |
| --- | --- | --- |
| Local copy → shared-display paste | The selected remote app receives the latest plain text exactly once, including text copied before the call. | Not run |
| Remote selection → local copy | `⌘C` returns the current remote selection; local `⌘V` pastes it correctly. | Not run |
| First interaction, Unicode, multiline and near-limit text | A new control grant preserves the clipboard operation and text remains intact. | Not run |
| Consent, control, Accessibility and lifecycle changes | Ending the share, pausing control, permission revocation, source change and disconnect prevent delayed clipboard writes or pastes. No extra clipboard approval is requested during sharing. | Not run |
| Focus, unsupported clipboard and timeout | Local fields keep their shortcuts; images/files, oversized or unchanged remote copies never paste unrelated stale text. | Not run |
