# Windows acceptance record

Issue: [#127](https://github.com/EvAlssment/Pairwise/issues/127). Status: native client preview, release blocked.

Platform decision: prioritize Windows 11 x64, with Windows 10 x64 build 19041+
compatibility retained. Complete Windows 11 acceptance first, then repeat the
compatibility matrix on Windows 10. Neither has passed physical acceptance yet.

Do not mark physical checks as passed based on unit tests, synthetic media, or a successful package build.
Record Windows edition/build, GPU/driver, CPU, RAM, audio/video devices, display resolution/scaling,
peer app commit/version, API/LiveKit versions, network conditions and measured outcomes for each run.

| Area | Automated evidence / implementation | Required physical evidence |
| --- | --- | --- |
| Transport/UI spike | Compiles with official pinned C++ SDK and Qt; Windows CI build | Compare frame latency, CPU/GPU, memory, idle use, startup, and capture reliability before final stack selection |
| Accounts/API | Fake HTTP lifecycle/race tests plus disposable real Go API signup, direct-call acceptance, room admission/heartbeat, share permission, call history and session revocation with native LiveKit media | Real deployment sign-in, expiry, invalid credentials, HTTPS trust, disabled account and sign-out |
| Calls | Direct/group invitation and approval endpoints; historical approvals cannot autojoin | Win–Win and Win–Mac accept/decline/cancel, ring expiry, four-person limit, caller departure, missed-call alerts |
| Voice | Native LiveKit platform audio/device IDs; selected-device local meter through an unpublished track; queued-start cancellation, missing-device, shutdown and local PCM tests | Bidirectional voice, echo cancellation, mute, default-route changes, Bluetooth/USB hot-plug, physical selected-device tests |
| Camera | Native Qt camera source, preview and bounded frame pipeline | Both directions, permission denied/regranted, device unplug, selection, group gallery |
| Sharing | Native display/window selection and one-sharer API claim; own-child-window pixel, stop/restart and source-close tests | 1080p quality/latency, protected content, moving/resizing windows, concurrent claims, stop through all exit paths |
| Input | Explicit consent, bounded two-second lease, revoke shortcut, key mapping/replay tests; actual viewer Tab/Shift+Tab routing, held-key repeat and clipboard-repeat guards; own-window OS input/copy/paste | Win–Win and both Win–Mac directions, held-key cleanup, dragging, scrolling, US shortcuts, mixed DPI/negative origins |
| Clipboard | Shared Swift/C++ fixtures, UTF-8 chunk/reassembly/expiry/replay tests | Real external-app copy/paste both directions, empty/private/large text, paste timing and revocation mid-transfer |
| Recovery | Reconnect/admission-loss revoke paths, stale-approval tests | Network drop, TURN/TLS-only network, sleep/wake, laptop lid, server restart, media service restart |
| Notifications | Native tray alerts and in-app call prompts | Notifications disabled, Focus Assist, app minimized, pending prompt expiry and another participant resolving it |
| Credentials/diagnostics | Credential Manager storage, token-free local export | Reinstall/update/uninstall credential behavior, expired sessions and inspection of exported data |
| Distribution | Windows compile/tests/staging/MakeAppx; disposable Windows Server CI signing, timestamp, package activation, update and uninstall test using a temporary certificate | Trusted publisher signature, fresh Win10/Win11 install, signed update via HTTPS App Installer, uninstall |

All physical rows above are **not run** until a dated result is attached. No Windows VM or signing identity
was provided when this preview began. CI unsigned packages are test artifacts, not production releases.

Run input tests only while someone is present at each machine. Confirm there is no control before consent,
secure desktop/UAC never accepts input, and elevated apps are clearly unsupported. Hold a key and mouse button,
then test revoke, disconnect, share stop, focus loss, lock, call end and process exit; verify no stuck input.
Repeat on 100%/150%/200% displays with a monitor to the left of the primary display and after unplugging it.

For update acceptance, install version N, sign in, install N+1 from the signed App Installer feed, verify
preferences/session behavior, reject a changed-publisher or tampered package, and uninstall. Verify no capture
starts from launch, update, joining a call, or opening Settings without selecting a local test.
