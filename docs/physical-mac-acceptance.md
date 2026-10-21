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
| Host local input takeover | Host movement, click, or key input immediately takes priority; remote input stops safely and can recover according to the visible state. | Not run |
| Host Stop and Resume | Stop revokes the lease and clears held input immediately. Resume restores the advertised availability only when permitted. | Not run |
| Emergency stop | Control–Option–Escape stops remote input and gives visible recovery feedback. | Not run |
| Display/source changes | Connecting/disconnecting an external display or changing the shared source does not mis-map input, freeze the viewer, or preserve a stale lease. | Not run |
| Accessibility revoked during sharing | Input stops, held keys/buttons are released, the call/view remains usable, and the UI identifies remote control as unavailable. | Not run |
| Network loss and recovery | Reconnection releases input safely, clears stale cursors, and restores call/control state without duplicate calls. | Not run |
| Sleep/wake and app termination | Sleep/wake, force quit, and relaunch leave no stuck input, busy roster state, duplicate session, or stale cursor. | Not run |
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
