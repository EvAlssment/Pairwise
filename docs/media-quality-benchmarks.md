# Media quality benchmark status

Pairwise currently exposes viewer-side WebRTC resolution, frame rate, received packet loss, selected-path RTT, time from attaching a screen track to its first rendered frame, and sustained zero-FPS interruptions with recovery duration. An interruption is counted only after at least two seconds of valid zero-FPS samples; missing samples break the measurement interval. The support diagnostics export includes these values without screen/audio content or account identity. These are per-call observations, not a release-quality score.

## Current CI coverage

The macOS CI job runs native clients against an isolated local API and LiveKit server. It checks call admission, authenticated data delivery, synthetic camera publication/decoding, clipboard transfer, cursor/control messages, and the single-sharer rule. This is a deterministic transport and behavior check; it does not currently inject bandwidth, latency, jitter, or packet loss, and it does not exercise macOS screen capture or remote input injection.

The CI integration suite emits two metadata-only synthetic screen-track samples: one with two native clients (1:1) and one with four. Each records rendered dimensions, callback-based observed frame rate, time from test receiver setup to first frame, and recovery time after the sender pauses and resumes. The files are named by participant count, validated together against a strict field allowlist, and archived under `media-quality-<commit>-<run-id>`. Both are loopback transport; they are not real screen captures or internet-quality baselines. No media frames are written to disk.

The reports explicitly mark packet loss, selected-path RTT, pointer-to-render latency, sender/receiver CPU, and readability as unmeasured. CI archives the measurements but does not set release budgets or fail on a performance threshold. The four-client profile represents the expected 3–4 participant call; CI currently has no deterministic network conditioning.

Do not treat CI results as evidence of readable 4K text, production internet quality, screen-share CPU cost, or pointer-to-render latency. No performance budget should be set until a repeatable baseline is captured on supported Macs.

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

- A reproducible network conditioner in CI and machine-readable per-commit results.
- A deterministic network conditioner for the 1:1 and 3–4 participant scenarios. The current reports are loopback samples, not network-conditioned media.
- Packet loss, selected-path RTT, pointer response, and actual share interruption/recovery under induced network outage. The current sender-pause recovery metric measures a synthetic source stop/start only.
- CPU and readability baselines on supported hardware, plus validated regression thresholds.
- A 3–4 participant real-device reference run and confirmation that exported diagnostics remain content-free.

Until those are available, issue #35 remains open and release notes must distinguish measurements from unmeasured dimensions.
