# Releasing Pairwise for macOS

Installable releases are built by the [`macOS release` workflow](../.github/workflows/macos-release.yml) after a `v*` tag is pushed. It tests and cross-compiles the macOS app for arm64 and x86_64, builds the universal Whisper runtime and app bundle, signs the app with Developer ID, notarizes and staples the app and disk image, runs Gatekeeper checks, then publishes the DMG, app ZIP, and checksums to a GitHub Release. The release DMG is intended for Apple silicon and Intel Macs running macOS 14 or later; physical Intel hardware acceptance is still required before claiming full Intel support.

## Required GitHub configuration

Configure these repository secrets before pushing a release tag:

- `DEVELOPER_SIGNING_IDENTITY`: the exact `Developer ID Application: ...` identity.
- `DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded `.p12` containing that certificate and private key.
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`: password used to export the `.p12`.
- `APPLE_ID`: Apple ID authorized for notarization.
- `APPLE_TEAM_ID`: Apple Developer team identifier.
- `APPLE_APP_SPECIFIC_PASSWORD`: app-specific password used by `notarytool`.

Configure this repository variable:

- `PAIRDESK_SERVER_URL`: the HTTPS API origin embedded in the release app, with no path or credentials.

Before packaging, the workflow runs the same baseline/constrained media and cursor regression gate as the regular macOS test workflow and archives its metadata-only reports. A missing or invalid report blocks publication. These synthetic loopback measurements are not hardware performance budgets; see [media quality benchmark status](media-quality-benchmarks.md) for current limits and the physical reference procedure.

The workflow imports the signing certificate into a temporary keychain, stores notarization credentials in that keychain, and deletes the keychain and certificate after the job. Do not commit signing material or put it in workflow logs. Limit access to release secrets and protect the `v*` tag pattern with repository rules.

## Creating a release

1. Update `CFBundleShortVersionString` in `macos/Info.plist`, review the changes, and merge them to `main`.
2. Create an annotated tag whose version matches the plist, for example `v0.3.4` for app version `0.3.4`.
3. Push the tag. The workflow rejects a version mismatch or missing signing configuration before building.
4. Confirm the workflow's notarization, stapling, and Gatekeeper assessment steps pass. The GitHub Release contains the installable `PairDesk.dmg`, a `PairDesk.zip` with the app bundle, and `SHA256SUMS`.
5. Download the DMG on a clean supported Mac, install it from Applications, and verify microphone, screen picker, Accessibility, login item, and in-place update behavior.

## Local development builds

`scripts/build-app.sh` and `scripts/create-dmg.sh` remain available for local development. `build-app.sh` builds arm64 and x86_64 executables and combines them into one universal app. The scripts are signed with the local identity from `scripts/create-signing-identity.sh`; without it `build-app.sh` stops unless `PAIRDESK_ALLOW_ADHOC=1` is set, because an ad-hoc build is a new app to macOS each time, so the saved sign-in prompts for the Mac password twice and permissions may need approval again. Keep building with the same identity. The local DMG defaults to `dist/PairDesk-<version>-build<build>-test.dmg` and refuses to overwrite an existing DMG or checksum; increment `CFBundleVersion` for another build or select a new path with `PAIRDESK_DMG_OUTPUT`. Neither local script is a substitute for this release workflow, and Gatekeeper may block both. Never bypass Gatekeeper to distribute a development image.
