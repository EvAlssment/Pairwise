# Windows native client preview

This is the implementation/spike for [issue #127](https://github.com/EvAlssment/Pairwise/issues/127).
It is **not a production Windows release**. Windows CI produces an unsigned MSIX for packaging validation;
signed distribution and physical Windows-to-Windows / Windows-to-macOS acceptance remain required.

Primary target: Windows 11 x64. Retain compatibility with Windows 10 x64 version 2004
(build 19041) or later; validate both before release. Windows 11 is the first physical
acceptance platform, followed by the Windows 10 compatibility matrix.
ARM64, 32-bit Windows, Windows Server, elevated application control, secure desktop/UAC,
unattended access, and background recording are unsupported. OS versions listed here are build targets,
not a claim that the physical acceptance matrix has passed.

## Architecture and spike decision

The preview uses C++20, Qt 6.8.3 Widgets/Multimedia, and official LiveKit C++ SDK 1.13.1.
Qt supplies native desktop widgets, notifications/tray, camera and FFmpeg-backed screen/window capture.
LiveKit supplies signaling, WebRTC, device selection and voice processing. Win32 Credential Manager stores
API sessions; SendInput injects consented input on the default desktop. No embedded browser is used.

The existing Go API needs no changes. Native capture frames feed ordinary LiveKit camera/screen tracks;
room admission, heartbeat, share ownership, call actions and join requests use the same endpoints as macOS.
The SDK is pinned by release version and SHA-256. It does not provide native camera/screen device capture,
so those are explicit Qt integrations rather than assumed SDK features.

This stack is provisional until physical latency, CPU/GPU use, mixed-DPI capture, hardware device changes
and clean-machine deployment have been measured. The frame conversion currently copies through CPU memory;
this should be profiled before promising macOS quality/latency parity. Sending is capped at 1080p/30 for
screens and 720p/30 for cameras. Latest-frame mailboxes bound memory when capture outruns transport/rendering.

## Build and run

Install Visual Studio 2022 with Desktop development with C++, a Windows 10/11 SDK, CMake 3.25+,
Python 3.12+, and Qt 6.8.3 MSVC 2022 x64 with Qt Multimedia. For example, install Qt with aqtinstall
or the official Qt installer. Use a Visual Studio x64 developer shell:

```powershell
python windows/cmake/fetch-livekit.py windows-x64 .cache/livekit
cmake -S windows -B build/windows -A x64 `
  -DCMAKE_PREFIX_PATH="C:/Qt/6.8.3/msvc2022_64;$pwd/.cache/livekit/livekit-sdk-windows-x64-1.13.1"
cmake --build build/windows --config Release --parallel 4
ctest --test-dir build/windows -C Release --output-on-failure
cmake --install build/windows --config Release --prefix build/stage
windeployqt --release --compiler-runtime --no-translations build/stage/Pairwise.exe
./windows/packaging/stage-runtime.ps1 -Stage build/stage
build/stage/Pairwise.exe
```

Sign in against an existing team HTTPS server. HTTP/WS are accepted only for loopback development.
Microphone and camera start off; enable them explicitly during a call. Settings includes local microphone
level and camera preview tests; closing Settings or starting a call stops them. The microphone test
uses the selected LiveKit device and an unpublished local track. Its bounded PCM stream stays local;
no room, server connection or audio publication is created for the test.

Select teammates to call/invite, or request to join an active call. Incoming calls provide Accept/Decline;
join approvals are under Join requests. A failed media join can be retried explicitly from an accepted call
or approved request. Historical approvals never reconnect automatically.

## Collaboration contract and limits

- `pairdesk.control.v1` retains version 1 and macOS virtual key codes, regardless of sender OS. `Protocol.cpp`
  converts Qt keys to that wire namespace; `Platform.cpp` converts it to Win32 input. Windows Ctrl maps to
  macOS Command; macOS Command/Control map to Windows Ctrl. Shift/Alt and navigation keys are translated.
  The preview keyboard mapping targets US layouts; IME, dead keys and non-US layout parity require further work.
- Windows hosts require a per-request, explicit consent dialog before issuing a random epoch and a two-second
  lease. The active controller is visible in the call. Stop all remote control, Ctrl+Alt+Escape, lease expiry,
  participant departure, share stop, reconnect, admission loss, window close and logout revoke input and release
  held keys/buttons. Escape or loss of focus releases viewer control. Window sharing remains view only.
  If Windows cannot reserve the global stop shortcut, hosting remote input is disabled and the call shows why.
- Input is authenticated by LiveKit participant identity; identities in JSON are never trusted for injection.
  Epochs, separate reliable/pointer sequence high-water marks, bounded coordinates and message sizes reject stale
  or malformed events. Cursor hover is lossy presence and does not move the owner's system pointer.
- Active screen control authorizes plain-text copy/paste without an additional clipboard toggle. Ctrl+C/V sends
  bounded, chunked UTF-8 text, preserving Swift's reference-date wire encoding. Remote copy waits for a new clipboard
  write; it never returns unrelated old clipboard content. Transfers expire, are recipient-bound and reject replay.
- Display selection uses physical Win32 monitor bounds for input and Qt device-independent bounds for the indicator.
  Layout changes stop sharing. The indicator must be excluded from capture. Display sharing can include Windows
  notifications; privacy-veil exclusions and region sharing are not implemented in this preview.
- `SendInput` cannot control applications at higher integrity or the secure desktop. No elevation is requested.
  Real AltGr, multiple keyboard layouts, sleep/wake, device hot-plug and multi-monitor behavior need acceptance tests.

## Installer, updates, and release gates

`packaging/package.ps1` uses Windows SDK MakeAppx validation and builds an x64 MSIX. The minimum OS is embedded
in the package manifest. `stage-runtime.ps1` copies the Visual Studio 2022 x64 redistributable CRT DLLs
into the app directory; packaging refuses missing CRT, Qt, capture-plugin or LiveKit runtime files.
Before packaging, copy `windows/third_party` to `build/stage/third-party-notices` along with the root
`LICENSE` and `THIRD_PARTY_NOTICES.md`; CI stages these automatically.
For release, pass the subject of the actual publisher certificate as `-Publisher`
and an installed certificate thumbprint as `-CertificateThumbprint`. Signing and timestamping must succeed,
and SignTool verifies the result. The script accepts no private key/password arguments.

An optional `-UpdateBaseUrl https://downloads.example/pairwise` generates an App Installer feed **only after
successful signing**. Windows checks for a newer package on launch every four hours, prompts for updates,
and does not force a downgrade or update during activation. Publisher and package identity must remain stable.
The script prepares artifacts only; it never publishes an update feed or uploads diagnostics.

CI packages are unsigned and must not be advertised as signed or installable on ordinary machines. Release
owners must complete third-party binary license notices/source availability (Qt/FFmpeg/WebRTC), verify trusted
signatures, and record clean-machine install/update/uninstall before publication. Credentials use Windows
Credential Manager rather than MSIX files; explicit sign-out deletes them. Windows may retain OS credentials
after uninstall, so verify and document that behavior in clean-machine acceptance.

The MSIX declares microphone and webcam capabilities so Windows privacy settings can show its device
intent at installation, following [Microsoft's guidance for packaged desktop apps](https://learn.microsoft.com/windows/apps/package-and-deploy/app-capability-declarations#privacy-sensitive-capabilities).
Device denial still stops capture and displays an error; declaring a capability does not start recording.

`packaging/test-deployment.ps1` is restricted to disposable GitHub-hosted Windows runners. It creates a
one-day, non-exportable test signing key, temporarily trusts its public certificate, and tests installation,
package-identity activation, a version update, and uninstall. Cleanup removes the package and temporary
trust even on failure. Test-signed packages are kept separate from the unsigned preview artifact and are
never published. This exercises the installer implementation; Windows Server CI and a temporary test
certificate do not establish Windows 10/11 clean-machine or production publisher acceptance.

Diagnostics are an explicit local JSON export containing app/Qt/OS versions and media booleans. They contain
no session tokens, server addresses, names, clipboard text, screenshots or transcripts. No upload is implemented.

See [the acceptance record](../docs/windows-acceptance.md) for release-blocking checks and current evidence.

## Isolated integration test

Windows CI builds the Go API and runs `tests/run-media-test.py` with `--api` pointing to that executable.
The runner starts disposable loopback Pairwise and LiveKit servers, creates synthetic accounts, accepts a
direct call and supplies API-issued room credentials to two real native SDK clients. The clients decode
synthetic audio/camera/screen tracks and authenticated control data; screen publishing obtains the real
API share permission first. The runner then checks call completion/history and logout revocation.
Room admission is kept alive during the test and all services are stopped afterward.

This test uses no physical microphone, camera, display capture, OS clipboard or external application input.
Those behaviors, mixed-platform interoperability and signed installation require the physical acceptance
matrix. The separate platform test uses only its own foreground window for input and can skip on a
non-interactive CI desktop.
