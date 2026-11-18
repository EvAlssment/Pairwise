# Third-party notices

Pairwise is MIT-licensed. Third-party components retain their own terms. This source repository vendors the LiveKit Swift client (Apache-2.0); its license and upstream NOTICE are preserved in `vendor/livekit-client-swift/`. The vendored source is modified as described in [UPSTREAM_PATCHES.md](UPSTREAM_PATCHES.md).

| Component | Version | License / notice |
| --- | --- | --- |
| LiveKit Swift client | 2.17.0, upstream commit `f07831a7f06bca9e2fc2e136db591b7b42f16d8d` | Apache-2.0; see `vendor/livekit-client-swift/LICENSE` and `NOTICE` |
| LiveKit WebRTC framework | 150.7871.2 | MIT; the build copies the upstream license into the app bundle |
| LiveKit Rust UniFFI framework | 0.1.9 | Apache-2.0; the build copies the upstream license into the app bundle |
| whisper.cpp | v1.7.6, commit `a8d002cfd879315632a579e73f0148d06959de36` | MIT; downloaded by `scripts/prepare-whisper.sh`, license copied into the app bundle |
| OpenAI Whisper Tiny multilingual model | SHA-1 `bd577a113a864445d4c299885e0cb97d4ba92b5f` | MIT as stated by the upstream Whisper project; license copied into the app bundle |

The model and whisper.cpp source are fetched during local preparation, not committed here. Binary redistributors must retain the notices placed in `Contents/Resources/ThirdPartyNotices/`. See [the Whisper license statement](https://github.com/openai/whisper/blob/main/README.md#license) and [Apple's third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/).

## Windows native preview

The Windows client uses Qt 6.8.3, Qt-supplied FFmpeg n7.1, and LiveKit C++ SDK 1.13.1 / FFI 0.13.4. The package preserves native license/notice texts and exact source hashes from [windows/third_party](windows/third_party/README.md), alongside the SDK's original build-info. That directory documents the remaining transitive binary/source audit required before production redistribution.
