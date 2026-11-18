# Windows native component notices

Pairwise source is MIT licensed. Components retain their own licenses; the text files in this directory are preserved from upstream and do not change Pairwise's license. `sources.json` records each file's exact source revision and SHA-256.

| Component | Shipped version/provenance | Preserved texts and source |
| --- | --- | --- |
| LiveKit C++ SDK | 1.13.1; SDK build-info commit `5cd2af1` | `LiveKit-Cpp-LICENSE.txt`, `LiveKit-Cpp-NOTICE.txt`; https://github.com/livekit/client-sdk-cpp/tree/5cd2af1 |
| LiveKit Rust / FFI | FFI 0.13.4; SDK build-info submodule `88705b15` | `LiveKit-Rust-LICENSE.txt`, `LiveKit-Rust-NOTICE.txt`; https://github.com/livekit/rust-sdks/tree/88705b15 |
| Qt Core, GUI, Widgets, Network, Multimedia, SVG | 6.8.3; dynamically linked official Qt MSVC binaries | `Qt-LGPL-3.0.txt`, `Qt-GPL-3.0.txt`; https://github.com/qt/qtbase/tree/v6.8.3, https://github.com/qt/qtmultimedia/tree/v6.8.3, https://github.com/qt/qtsvg/tree/v6.8.3 |
| FFmpeg | n7.1, supplied by Qt 6.8.3 | `FFmpeg-LGPL-2.1.txt`, `FFmpeg-LICENSE.md`, `Qt-FFmpeg-attribution.json`; https://github.com/FFmpeg/FFmpeg/tree/n7.1 |

The SDK's original build-info is also shipped under `livekit-notices/livekit/build-info.json`. Qt's FFmpeg attribution file records its additional component licenses and the source/build-script locations for the binary provider. Source code for these versions is available at the revision links above. Pairwise's CMake project and packaging script allow rebuilding the application and packaging substituted shared libraries under the rebuilder's own publisher identity.

This is the baseline native notice bundle, not a complete transitive dependency audit. Before production redistribution, reconcile notices and corresponding source availability for all bundled Qt third-party code, WebRTC/Rust/C++ dependencies, software OpenGL/Mesa and Microsoft redistributables with the exact provider binaries. The unsigned CI preview must not be represented as a completed production distribution review.
