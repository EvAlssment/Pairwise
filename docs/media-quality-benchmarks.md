# Media quality benchmark status

Pairwise currently exposes viewer-side WebRTC resolution, frame rate, received packet loss, selected-path RTT, time from attaching a screen track to its first rendered frame, and sustained zero-FPS interruptions with recovery duration. An interruption is counted only after at least two seconds of valid zero-FPS samples; missing samples break the measurement interval. The support diagnostics export includes these values without screen/audio content or account identity. These are per-call observations, not a release-quality score.

## Current CI coverage

The macOS CI job runs native clients against an isolated local API and LiveKit server. It checks call admission, authenticated data delivery, synthetic camera publication/decoding, clipboard transfer, cursor/control messages, and the single-sharer rule. It runs the 1:1 and 4-participant synthetic screen profiles twice: an unconditioned local baseline and a constrained loopback profile. The constrained profile shapes client-to-LiveKit UDP egress to 20 Mbit/s, cycles outbound one-way delay through 20/60/30/50 ms once per second, and applies 1% outbound packet loss to LiveKit's UDP media port range with macOS PF/dummynet. The benchmark reports the profile configuration and selected ICE-pair RTT; validation rejects constrained reports that do not show at least 20 ms RTT. This exercises real packet shaping on the CI transport, but it is still a local synthetic path, not a distant-region, TURN, or user-network baseline. It does not exercise macOS screen capture or remote input injection.

The CI integration suite emits four metadata-only synthetic screen-track samples: baseline and constrained variants for two clients (1:1) and four clients. Each records rendered dimensions, callback-based observed frame rate, receiver-side RTP bitrate, time from test receiver setup to first frame, recovery time after the sender pauses and resumes, receiver loss, selected-path RTT, aggregate test-harness process CPU, and an allowlisted description of the applied network profile. The CPU value covers the single process hosting the synthetic clients; it is not a sender/receiver split. Each media and cursor report also records the runner's macOS version, CPU architecture, model identifier, and logical CPU count so CI samples can be compared against their execution environment. It excludes hostnames, serial numbers, usernames, and other per-machine identity. Files are validated together against one commit and workflow run, then archived under `media-quality-<commit>-<run-id>`. No media frames are written to disk. The constrained job changes the disposable macOS runner's PF ruleset temporarily and restores `/etc/pf.conf` during cleanup; it is deliberately prohibited outside CI.

The artifact also includes `network-conditioner.json`, containing aggregate packet, byte, and drop counts for the measured outbound dummynet pipe, plus the configured direction, UDP range, bandwidth, delay sequence, and loss probability. It excludes IP addresses and packet contents. Validation fails if the constrained run reports no classified outbound media packets or no packet drops. The same-host LiveKit replies bypass the runner's counted PF path, so CI does not claim or report shaped return traffic. Receiver RTP loss may still be zero when WebRTC recovers outbound drops; dummynet counters independently show drops at the test-network layer.

The report validator requires receiver-side packet loss, RTP bitrate, selected-path RTT, and harness-process CPU for both participant counts and both network profiles; CI fails if these WebRTC stats are unavailable, if measured bitrate is nonpositive, or if the constrained profile does not raise selected-path RTT. Separate cursor artifacts capture 30 sequential samples from the sender's publish call through the sharer's native cursor-overlay render pass for two- and three-participant calls under baseline and constrained loopback profiles. The cursor timing does not include display scanout or cross-device clock alignment. Sender/receiver CPU and readable-content quality remain explicitly unmeasured. CI archives the measurements but does not yet set release budgets or fail on a performance threshold.

Do not treat CI results as evidence of readable 4K text, production internet quality, separate sender/receiver CPU cost, physical pointer-to-visible latency, or a supported-hardware performance baseline. No performance budget should be set until a repeatable baseline is captured on supported Macs.

## Two-Mac reference run

For a physical reference run, record one row per call. Use synthetic test accounts and a neutral test pattern containing small text, scrolling text, and a moving marker. Do not record or retain the actual screen, camera, microphone, transcript, credentials, or tokens.

| Field | Capture method |
|---|---|
| Date, Pairwise build/commit, macOS version, Mac model/chip, display mode | Record from About This Mac and the app version; omit serial numbers and usernames |
| Participant count and role | 1:1 or 3–4 participants; identify sender/viewer only by role |
| Network path/profile | Country/region at city-level only, wired/Wi-Fi, direct/relay; record configured bandwidth/latency/jitter/loss when a conditioner is used |
| Time to first frame | Viewer toolbar or support diagnostics; elapsed from track attachment to first rendered frame |
| Resolution, FPS, packet loss, selected-path RTT | Viewer toolbar or support diagnostics after 60 seconds and again after 5 minutes |
| Share interruptions and recovery | Count interruptions and measure seconds until frames resume; do not include call setup |
| Pointer-to-visible-response | Use an on-screen synthetic marker with an external high-frame-rate camera or instrumented test; record p50/p95 across at least 30 actions |
| Sender/receiver CPU | Activity Monitor or Instruments; record process CPU over the same steady 60-second interval |
| Readability | At 100% viewer zoom, note the smallest readable test-pattern font and whether scrolling remains legible |

Run at the default 1440p30 preset and the 4K30 maximum. Repeat once with a constrained network profile and once in a 3–4 participant call. Keep physical results separate from automated synthetic CI runs. Compare only runs with matching Mac/display/network conditions. Establish regression budgets from repeated baselines before making a gate blocking.

## Still needed for issue #35

- A repeatable synthetic network conditioner now runs in CI for the 1:1 and four-client scenarios, with profile metadata and per-commit artifacts. This is a first transport benchmark slice, not a production quality baseline.
- Validate the outbound-only CI measurement against a remote or second-device path before using it as a network-quality budget. The same-host runner cannot establish bidirectional conditioning or remote-path recovery.
- Cross-device pointer response and actual display scanout under induced network outage on a constrained path. The synthetic cursor timing ends at a native view render pass; it does not measure physical display scanout. The current sender-pause recovery metric measures a synthetic source stop/start only; loopback packet loss and RTT are not internet-path baselines.
- Separate sender/receiver CPU and readability baselines on supported hardware, plus validated regression thresholds.
- A 3–4 participant real-device reference run and confirmation that exported diagnostics remain content-free.

Until those are available, issue #35 remains open and release notes must distinguish measurements from unmeasured dimensions.
