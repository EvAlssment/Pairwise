import XCTest
@testable import PairDesk

final class AppTests: XCTestCase {
    func testPasswordPolicyExplainsCharacterMinimumAndUTF8ByteMaximum() {
        XCTAssertFalse(PairDeskPasswordPolicy.isValid("short-pass"))
        XCTAssertEqual(PairDeskPasswordPolicy.hint(for: "short-pass"), "2 more characters needed")
        XCTAssertTrue(PairDeskPasswordPolicy.isValid("twelve-chars"))
        XCTAssertTrue(PairDeskPasswordPolicy.isValid(String(repeating: "🧑", count: 18)))
        XCTAssertFalse(PairDeskPasswordPolicy.isValid(String(repeating: "🧑", count: 19)))
        XCTAssertEqual(PairDeskPasswordPolicy.hint(for: String(repeating: "🧑", count: 19)), "Too long by 4 UTF-8 bytes")
    }

    func testCallInviteAvailabilityExplainsEachRosterState() {
        let online = TeamUser(id: "available", name: "Available", email: "a@example.com", online: true, busy: false)
        let busy = TeamUser(id: "busy", name: "Busy", email: "b@example.com", online: true, busy: true)
        let offline = TeamUser(id: "offline", name: "Offline", email: "o@example.com", online: false, busy: false)

        XCTAssertEqual(CallInviteAvailability.resolve(user: online, participantIDs: [], outgoingInviteIDs: [], canAddPerson: true), .available)
        XCTAssertEqual(CallInviteAvailability.resolve(user: offline, participantIDs: [], outgoingInviteIDs: [], canAddPerson: true), .offline)
        XCTAssertEqual(CallInviteAvailability.resolve(user: busy, participantIDs: [], outgoingInviteIDs: [], canAddPerson: true), .inAnotherCall)
        XCTAssertEqual(CallInviteAvailability.resolve(user: online, participantIDs: [], outgoingInviteIDs: ["available"], canAddPerson: true), .alreadyInvited)
        XCTAssertEqual(CallInviteAvailability.resolve(user: online, participantIDs: ["available"], outgoingInviteIDs: [], canAddPerson: true), .alreadyInThisCall)
        XCTAssertEqual(CallInviteAvailability.resolve(user: online, participantIDs: [], outgoingInviteIDs: [], canAddPerson: false), .callFull)
    }

    func testCallMediaModeNamesTheMediaCurrentlyInUse() {
        XCTAssertEqual(CallMediaMode.title(screenSharing: false, cameraActive: false), "Audio call")
        XCTAssertEqual(CallMediaMode.title(screenSharing: false, cameraActive: true), "Video call")
        XCTAssertEqual(CallMediaMode.title(screenSharing: true, cameraActive: false), "Screen share")
        XCTAssertEqual(CallMediaMode.title(screenSharing: true, cameraActive: true), "Screen + video")
    }

    func testSharedScreenWindowUsesMostAvailableDisplaySpace() {
        XCTAssertEqual(
            SharedScreenWindowLayout.initialContentSize(available: CGSize(width: 1920, height: 1080)),
            CGSize(width: 1888, height: 1032)
        )
        XCTAssertEqual(
            SharedScreenWindowLayout.initialContentSize(available: CGSize(width: 2560, height: 1600)),
            CGSize(width: 2400, height: 1552)
        )
        XCTAssertEqual(
            SharedScreenWindowLayout.initialContentSize(available: CGSize(width: 640, height: 400)),
            CGSize(width: 700, height: 450)
        )
    }

    func testSingleInstancePolicyOnlyForwardsTheSameBundleFromTheSamePath() {
        let installedCopy = URL(fileURLWithPath: "/Applications/PairDesk.app")
        XCTAssertTrue(PairDeskInstancePolicy.isSameInstalledCopy(
            existingBundleIdentifier: "app.internal.pairdesk",
            existingBundleURL: installedCopy,
            currentBundleIdentifier: "app.internal.pairdesk",
            currentBundleURL: installedCopy
        ))
        XCTAssertFalse(PairDeskInstancePolicy.isSameInstalledCopy(
            existingBundleIdentifier: "app.internal.pairdesk",
            existingBundleURL: URL(fileURLWithPath: "/Volumes/PairDesk/PairDesk.app"),
            currentBundleIdentifier: "app.internal.pairdesk",
            currentBundleURL: installedCopy
        ))
        XCTAssertFalse(PairDeskInstancePolicy.isSameInstalledCopy(
            existingBundleIdentifier: "app.internal.pairdesk.old",
            existingBundleURL: installedCopy,
            currentBundleIdentifier: "app.internal.pairdesk",
            currentBundleURL: installedCopy
        ))
    }

    func testMicrophoneMeterIsSilentForEmptyAndClampsRMS() {
        XCTAssertEqual(AudioMeter.level(samples: []), 0)
        XCTAssertEqual(AudioMeter.level(samples: [0, 0, 0]), 0)
        XCTAssertEqual(AudioMeter.level(samples: [0.5, -0.5]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioMeter.level(samples: [2, -2]), 1)
    }
    func testSpeakerTestToneIsShortQuietAndFadeShaped() {
        let samples = SpeakerTestTone.samples()

        XCTAssertEqual(samples.count, 38_400)
        XCTAssertEqual(samples.first, 0)
        XCTAssertEqual(samples.last, 0)
        XCTAssertLessThanOrEqual(samples.map(abs).max() ?? 1, 0.0801)
        let positiveCrossings = zip(samples, samples.dropFirst()).filter { $0 <= 0 && $1 > 0 }.count
        XCTAssertEqual(Double(positiveCrossings) / 0.8, 440, accuracy: 1)
    }
    func testCameraSelectionFallsBackWhenSavedDeviceIsMissing() {
        let choices = [CameraDeviceChoice(id: "built-in", name: "Built-in"),
                       CameraDeviceChoice(id: "usb", name: "USB camera")]
        XCTAssertEqual(CameraDeviceSelection.resolve(savedID: "usb", available: choices).id, "usb")
        XCTAssertFalse(CameraDeviceSelection.resolve(savedID: "usb", available: choices).savedDeviceUnavailable)
        XCTAssertEqual(CameraDeviceSelection.resolve(savedID: "removed", available: choices).id, "built-in")
        XCTAssertTrue(CameraDeviceSelection.resolve(savedID: "removed", available: choices).savedDeviceUnavailable)
        XCTAssertNil(CameraDeviceSelection.resolve(savedID: nil, available: []).id)
    }
    func testScreenNetworkQualityUsesMeasuredRTTAndHandlesMissingStats() {
        XCTAssertEqual(ScreenNetworkQuality.from(roundTripTimeSeconds: nil), .measuring)
        XCTAssertEqual(ScreenNetworkQuality.from(roundTripTimeSeconds: .nan), .measuring)
        XCTAssertEqual(ScreenNetworkQuality.from(roundTripTimeSeconds: 0.08), .good(roundTripMilliseconds: 80))
        XCTAssertEqual(ScreenNetworkQuality.from(roundTripTimeSeconds: 0.151), .fair(roundTripMilliseconds: 151))
        XCTAssertEqual(ScreenNetworkQuality.from(roundTripTimeSeconds: 0.301), .highLatency(roundTripMilliseconds: 301))
        XCTAssertEqual(ScreenNetworkQuality.measuring.shortTitle, "Measuring")
        XCTAssertEqual(ScreenNetworkQuality.good(roundTripMilliseconds: 80).shortTitle, "Good")
        XCTAssertEqual(ScreenNetworkQuality.fair(roundTripMilliseconds: 151).shortTitle, "Fair")
        XCTAssertEqual(ScreenNetworkQuality.highLatency(roundTripMilliseconds: 301).shortTitle, "High latency")
    }
    func testScreenQualityReportContainsOnlyShareMeasurements() {
        var history = ScreenQualityHistory()
        history.record(ScreenQualitySample(uptimeSeconds: 1, roundTripMilliseconds: 40,
                                           framesPerSecond: 30, packetLossPercent: 0))
        history.record(ScreenQualitySample(uptimeSeconds: 2, roundTripMilliseconds: 120,
                                           framesPerSecond: 30, packetLossPercent: 0.5))
        let report = ScreenQualityReport(networkQuality: .fair(roundTripMilliseconds: 212),
                                         controlChannelRTT: "38 ms",
                                         receivedStream: "1920 × 1080 · 30 fps · 0.4% loss",
                                         firstFrameMilliseconds: 460,
                                         history: history)
        XCTAssertTrue(report.text.contains("Network: Fair · 212 ms RTT"))
        XCTAssertTrue(report.text.contains("Recent path: RTT median 80 ms · peak 120 ms · 2 readings"))
        XCTAssertTrue(report.text.contains("Control channel RTT: 38 ms"))
        XCTAssertTrue(report.text.contains("Received screen: 1920 × 1080 · 30 fps · 0.4% loss"))
        XCTAssertTrue(report.text.contains("PairDesk process CPU: unavailable"))
        XCTAssertTrue(report.text.contains("First frame: 460 ms"))
        XCTAssertFalse(report.text.localizedCaseInsensitiveContains("email"))
        XCTAssertFalse(report.text.localizedCaseInsensitiveContains("token"))

        let incomplete = ScreenQualityReport(networkQuality: .measuring,
                                             controlChannelRTT: "unavailable",
                                             receivedStream: "Stream stats unavailable",
                                             firstFrameMilliseconds: nil)
        XCTAssertTrue(incomplete.text.contains("First frame: unavailable"))
    }
    func testSupportDiagnosticsReduceErrorsToSafeCategories() {
        XCTAssertEqual(SupportDiagnostics.safeErrorCategory(nil), "none")
        XCTAssertEqual(SupportDiagnostics.safeErrorCategory("Accessibility permission denied for alice@example.com"), "permission")
        XCTAssertEqual(SupportDiagnostics.safeErrorCategory("Bearer secret-token connection failed"), "network")
        XCTAssertEqual(SupportDiagnostics.safeErrorCategory("Unexpected opaque error with private details"), "other (details omitted)")
    }
    func testSupportDiagnosticsSanitizeAPICommitIdentifier() {
        XCTAssertEqual(SupportDiagnostics.safeBuildIdentifier("a1b2c3d4"), "a1b2c3d4")
        XCTAssertEqual(SupportDiagnostics.safeBuildIdentifier("unknown"), "unknown")
        XCTAssertEqual(SupportDiagnostics.safeBuildIdentifier("abc\nToken: secret"), "unavailable")
        XCTAssertEqual(SupportDiagnostics.safeBuildIdentifier(String(repeating: "a", count: 65)), "unavailable")
        XCTAssertEqual(SupportDiagnostics.safeBuildIdentifier(nil), "unavailable")
    }
    func testSupportDiagnosticsOmitIPAddressesFromAPIHost() {
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("136.80.31.73"), "IP address omitted")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("2001:db8::1"), "IP address omitted")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("api.136-80-31-73.sslip.io"), "IP address omitted")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("136.80.31.73.nip.io"), "IP address omitted")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("api-192-168-4-12.futurepath.ai"), "IP address omitted")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("pair.example.test"), "pair.example.test")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost(nil), "unavailable")
    }

    func testRuntimeArchitectureDiagnosticsIdentifyNativeIntelAndAppleSilicon() {
        XCTAssertEqual(RuntimeArchitectureDiagnostics.summary(processArchitecture: "x86_64",
                                                              arm64Hardware: 0,
                                                              translated: nil),
                       "x86_64 process · Intel · native")
        XCTAssertEqual(RuntimeArchitectureDiagnostics.summary(processArchitecture: "arm64",
                                                              arm64Hardware: 1,
                                                              translated: 0),
                       "arm64 process · Apple silicon · native")
    }

    func testRuntimeArchitectureDiagnosticsFlagRosettaAndUnknownState() {
        XCTAssertEqual(RuntimeArchitectureDiagnostics.summary(processArchitecture: "x86_64",
                                                              arm64Hardware: 1,
                                                              translated: 1),
                       "x86_64 process · Apple silicon · Rosetta translated")
        XCTAssertEqual(RuntimeArchitectureDiagnostics.summary(processArchitecture: "x86_64",
                                                              arm64Hardware: nil,
                                                              translated: nil),
                       "x86_64 process · unknown hardware · translation status unavailable")
    }
    func testPrivateTokensRequireHTTPSOutsideLoopback() throws {
        XCTAssertThrowsError(try APIClient(server: "http://192.168.1.1:8080"))
        XCTAssertThrowsError(try APIClient(server: "https://user:secret@example.com"))
        XCTAssertThrowsError(try APIClient(server: "https://example.com/path"))
        XCTAssertNoThrow(try APIClient(server: "http://127.0.0.1:8080"))
        XCTAssertNoThrow(try APIClient(server: "https://pair.example.com"))
    }
    func testPackagedServerReplacesStaleLocalhostPreference() {
        let packaged = "https://api.team.example"
        for local in ["http://localhost:18080", "http://127.0.0.1:18080", "http://[::1]:18080"] {
            let initial = ServerAddressPolicy.initialAddress(saved: local, packaged: packaged, fallback: "fallback")
            XCTAssertEqual(initial.value, packaged)
            XCTAssertTrue(initial.shouldPersist)
            XCTAssertTrue(ServerAddressPolicy.shouldDiscardSession(savedServer: local, packaged: packaged))
        }
    }
    func testPackagedServerPreservesExplicitRemoteServerOverride() {
        let initial = ServerAddressPolicy.initialAddress(
            saved: "https://pair.other-team.example", packaged: "https://api.team.example", fallback: "fallback"
        )
        XCTAssertEqual(initial.value, "https://pair.other-team.example")
        XCTAssertFalse(initial.shouldPersist)
        XCTAssertFalse(ServerAddressPolicy.shouldDiscardSession(
            savedServer: "https://pair.other-team.example", packaged: "https://api.team.example"
        ))
    }
    func testLocalDevelopmentWithoutPackagedServerKeepsLoopback() {
        let initial = ServerAddressPolicy.initialAddress(
            saved: "http://localhost:18080", packaged: nil, fallback: "http://127.0.0.1:18080"
        )
        XCTAssertEqual(initial.value, "http://localhost:18080")
        XCTAssertFalse(initial.shouldPersist)
        XCTAssertFalse(ServerAddressPolicy.shouldDiscardSession(savedServer: initial.value, packaged: nil))
    }
    func testPortraitLetterboxRejectsOutsideClicks() {
        let box = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let screen = CGSize(width: 600, height: 1000)
        XCTAssertNil(ScreenCoordinateMapper.normalized(point: CGPoint(x: 100, y: 300), container: box, contentSize: screen))
        let center = ScreenCoordinateMapper.normalized(point: CGPoint(x: 500, y: 300), container: box, contentSize: screen)
        XCTAssertEqual(center?.x, 0.5)
        XCTAssertEqual(center?.y, 0.5)
    }
    func testLandscapeLetterboxCoordinatesAreNotStretched() {
        let p = ScreenCoordinateMapper.normalized(point: CGPoint(x: 100, y: 50), container: CGRect(x: 0, y: 0, width: 200, height: 200), contentSize: CGSize(width: 200, height: 100))
        XCTAssertEqual(p?.x, 0.5)
        XCTAssertEqual(p?.y, 0)
        XCTAssertNil(ScreenCoordinateMapper.normalized(point: CGPoint(x: 100, y: 25), container: CGRect(x: 0, y: 0, width: 200, height: 200), contentSize: CGSize(width: 200, height: 100)))
    }
    func testRemotePointerMapsIntoAspectFitContentAndRejectsOutsideCoordinates() {
        let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(ScreenCoordinateMapper.displayedPoint(normalized: CGPoint(x: 0.5, y: 0.5), container: container, contentSize: size), CGPoint(x: 500, y: 300))
        XCTAssertEqual(ScreenCoordinateMapper.displayedPoint(normalized: CGPoint(x: 0, y: 0), container: container, contentSize: size), CGPoint(x: 0, y: 50))
        XCTAssertNil(ScreenCoordinateMapper.displayedPoint(normalized: CGPoint(x: 1.1, y: 0.5), container: container, contentSize: size))
    }
    func testZoomedScreenMapsVisibleClicksBackToTheCorrectRemoteCoordinates() {
        let container = CGRect(x: 0, y: 0, width: 1000, height: 600)
        let screen = CGSize(width: 200, height: 100)
        XCTAssertEqual(ScreenCoordinateMapper.normalized(
            point: CGPoint(x: 500, y: 300), container: container, contentSize: screen, zoomScale: 2
        ), CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(ScreenCoordinateMapper.normalized(
            point: CGPoint(x: 0, y: 300), container: container, contentSize: screen, zoomScale: 2
        ), CGPoint(x: 0.25, y: 0.5))
        XCTAssertEqual(ScreenCoordinateMapper.zoomedContentRect(
            container: container, contentSize: screen, zoomScale: 2
        ), CGRect(x: -500, y: -200, width: 2_000, height: 1_000))
        XCTAssertNil(ScreenCoordinateMapper.normalized(
            point: CGPoint(x: 500, y: 300), container: container, contentSize: screen, zoomScale: .infinity
        ))
        XCTAssertEqual(ScreenCoordinateMapper.normalized(
            point: CGPoint(x: 100, y: 300), container: container, contentSize: screen,
            zoomScale: 2, panOffset: CGSize(width: -100, height: 0)
        ), CGPoint(x: 0.35, y: 0.5))
        XCTAssertEqual(ScreenCoordinateMapper.clampedPanOffset(
            CGSize(width: 1_000, height: -1_000), container: container, contentSize: screen, zoomScale: 2
        ), CGSize(width: 500, height: -200))
        XCTAssertEqual(ScreenCoordinateMapper.clampedPanOffset(
            CGSize(width: 50, height: 50), container: container, contentSize: screen, zoomScale: 1
        ), .zero)
        XCTAssertEqual(ScreenCoordinateMapper.clampedPanOffset(
            CGSize(width: CGFloat.nan, height: 0), container: container, contentSize: screen, zoomScale: 2
        ), .zero)
    }
    func testPermissionGuidanceIdentifiesMountedImageAndInstalledCopies() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: URL(fileURLWithPath: "/Applications/PairDesk.app"), homeDirectory: home), .applications)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: URL(fileURLWithPath: "/Users/example/Applications/PairDesk.app"), homeDirectory: home), .applications)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: URL(fileURLWithPath: "/Volumes/PairDesk/PairDesk.app"),
                                                  homeDirectory: home,
                                                  diskImageMountPoints: [URL(fileURLWithPath: "/Volumes/PairDesk", isDirectory: true)]),
                       .diskImage)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: URL(fileURLWithPath: "/tmp/PairDesk.app"), homeDirectory: home), .other("/tmp/PairDesk.app"))
    }
    func testDuplicateAppCopyDiagnosticsIgnoreCurrentProcessAndOtherBundles() {
        let current = RunningAppCopy(processIdentifier: 10, bundleIdentifier: "app.internal.pairdesk",
                                     bundleURL: URL(fileURLWithPath: "/Applications/PairDesk.app"))
        let duplicate = RunningAppCopy(processIdentifier: 11, bundleIdentifier: "app.internal.pairdesk",
                                       bundleURL: URL(fileURLWithPath: "/tmp/PairDesk.app"))
        let unrelated = RunningAppCopy(processIdentifier: 12, bundleIdentifier: "com.example.other",
                                       bundleURL: URL(fileURLWithPath: "/Applications/Other.app"))
        XCTAssertEqual(RunningAppCopyDiagnostics.otherCopyPaths(
            bundleIdentifier: "app.internal.pairdesk", currentProcessIdentifier: 10,
            runningApplications: [current, duplicate, unrelated]), ["/tmp/PairDesk.app"])
        XCTAssertEqual(RunningAppCopyDiagnostics.otherCopyPaths(
            bundleIdentifier: "app.internal.pairdesk", currentProcessIdentifier: 10,
            runningApplications: [current]), [])
        XCTAssertEqual(RunningAppCopyDiagnostics.otherCopyPaths(
            bundleIdentifier: nil, currentProcessIdentifier: 10,
            runningApplications: [current, duplicate]), [])
    }
    func testBackendWireContractsDecode() throws {
        let data = Data(#"{"room":{"id":"abc","name":"Debugging","participantCount":1,"participants":[{"id":"u1","name":"Sam","email":"sam@example.com"}]},"url":"wss://rtc.example.com","token":"opaque","participantIdentity":"u1"}"#.utf8)
        let join = try JSONDecoder().decode(JoinResponse.self, from: data)
        XCTAssertEqual(join.participantIdentity, join.room.participants.first?.id)
    }
    func testCallHistoryWireContractDecodesCreationTime() throws {
        func call(createdAtField: String) throws -> CallInvitation? {
            let json = #"{"calls":[{"id":"call-1","status":"expired","caller":{"id":"u1","name":"Sam","email":"sam@example.com"},"target":{"id":"u2","name":"Lee","email":"lee@example.com"},"room":{"id":"room-1","name":"Direct call","participantCount":0,"participants":[]},"#
                + createdAtField + #""expiresAt":"2026-10-28T10:00:45Z"}]}"#
            return try JSONDecoder().decode(CallsResponse.self, from: Data(json.utf8)).calls.first
        }
        let whole = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-28T10:00:00Z"))
        let plain = try call(createdAtField: #""createdAt":"2026-10-28T10:00:00Z","#)
        XCTAssertEqual(plain?.status, "expired")
        XCTAssertEqual(plain?.createdDate, whole)
        // Go marshals time.Time with nanoseconds; the previous parser read this as the distant past.
        let precise = try XCTUnwrap(try call(createdAtField: #""createdAt":"2026-10-28T10:00:00.123456789Z","#)?.createdDate)
        XCTAssertEqual(precise.timeIntervalSince(whole), 0.123456789, accuracy: 0.001)
        let offset = try XCTUnwrap(try call(createdAtField: #""createdAt":"2026-10-28T15:30:00.5+05:30","#)?.createdDate)
        XCTAssertEqual(offset.timeIntervalSince(whole), 0.5, accuracy: 0.001)
        // No placeholder date from an older server or an unreadable value.
        let missing = try call(createdAtField: "")
        XCTAssertNil(missing?.createdDate)
        let unreadable = try call(createdAtField: #""createdAt":"yesterday","#)
        XCTAssertNil(unreadable?.createdDate)
    }
    func testAdminAuditWireContractDecodesRFC3339Timestamp() throws {
        let data = Data(#"{"events":[{"actorId":"admin-1","targetId":"member-2","action":"account.password_reset","occurredAt":"2026-10-20T03:00:00Z"}]}"#.utf8)
        let response = try JSONDecoder().decode(AdminAuditResponse.self, from: data)
        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events[0].action, "account.password_reset")
        XCTAssertEqual(response.events[0].date, ISO8601DateFormatter().date(from: "2026-10-20T03:00:00Z"))
        let precise = Data(#"{"events":[{"actorId":"admin-1","targetId":"member-2","action":"account.password_reset","occurredAt":"2026-10-20T03:00:00.25Z"}]}"#.utf8)
        let preciseDate = try XCTUnwrap(JSONDecoder().decode(AdminAuditResponse.self, from: precise).events[0].date)
        let wholeDate = try XCTUnwrap(response.events[0].date)
        XCTAssertEqual(preciseDate.timeIntervalSince(wholeDate), 0.25, accuracy: 0.001)
    }
    func testHostAccessibilityBlockIsReportedOverControlChannel() throws {
        let message = RemoteControlMessage(epoch: "", sequence: 1, kind: .hostPermissionRequired)
        let decoded = try JSONDecoder().decode(RemoteControlMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.kind, .hostPermissionRequired)
        XCTAssertFalse(RemoteControlState.hostPermissionRequired.isGranted)
    }
}
