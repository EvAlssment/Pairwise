# Pairwise two-Mac tester quick start

Use this checklist to get into a real call quickly. It complements the detailed
[physical Mac acceptance record](physical-mac-acceptance.md); it does not replace
that record or make a feature accepted by itself.

## Before the call

1. Install the **same PairDesk build** on both Macs in `/Applications`. Check
   **PairDesk → About PairDesk** and note the version and build number. Do not
   compare results from different versions.
2. At sign-in, expand **Server address** and confirm both Macs use the exact
   team API address supplied by the administrator. Do not leave a local
   `localhost`/`127.0.0.1` address on a tester's Mac.
3. Sign in with the separate team accounts provided to each tester. Exchange
   passwords through a private channel; never put them in this repository,
   screenshots, or test notes.
4. On each Mac, record only the macOS version, Mac model/chip, display scaling,
   and network type/region. Do not record account identifiers, serial numbers,
   public IP addresses, or tokens.
5. For screen control, the person sharing must grant Accessibility to the
   installed PairDesk copy in `/Applications`. Choose the display in Apple's
   screen-sharing picker. Camera and microphone remain off until enabled.

## First 15-minute pass

- Confirm each tester can see the other's presence and start a direct call.
- Check mute/unmute, selected microphone/speaker, and call hang-up from either
  side. Both people should return to an available state after hang-up.
- Share a display. Check first-frame time, received resolution/FPS, and whether
  text is readable at normal viewing size.
- Exercise remote input on a blank text editor: hover each independent cursor,
  click, double-click, type synthetic text, drag, and scroll. Verify the host
  can immediately take over and that control stops when the host pauses it.
- Leave call-wide clipboard toggles off. While sharing, copy harmless synthetic
  text in both directions and paste into the remote editor directly. Verify no
  extra clipboard approval appears and automatic sync stops when sharing ends.
- Ask a third teammate to request joining the active call. Verify the call
  participants see the request and that approval admits the requester.
- End the call from one side and confirm the other side can start a new call
  without quitting or reopening PairDesk.

If time permits, repeat screen sharing in the other direction, test a second
network, and exercise camera opt-in and the screen-source/privacy settings.
Use the full acceptance matrix for remote-control recovery, source switching,
crop alignment, device hot-plug, group calls, and other issue-specific checks.

## Send back useful results

For each failed or surprising step, include the PairDesk version/build, macOS
version, Mac model/chip, scenario, approximate time, and a short description of
what happened. Include redacted diagnostics only when requested. Do not send
screen recordings, screenshots of private content, transcripts, audio/video,
passwords, access tokens, or personal call details. Mark untested scenarios
**Not run** rather than inferring a pass from local or CI tests.
