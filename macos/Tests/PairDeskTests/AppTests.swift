import XCTest
@testable import PairDesk

final class AppTests: XCTestCase {
    func testMicrophoneMeterIsSilentForEmptyAndClampsRMS() {
        XCTAssertEqual(AudioMeter.level(samples: []), 0)
        XCTAssertEqual(AudioMeter.level(samples: [0, 0, 0]), 0)
        XCTAssertEqual(AudioMeter.level(samples: [0.5, -0.5]), 0.5, accuracy: 0.0001)
        XCTAssertEqual(AudioMeter.level(samples: [2, -2]), 1)
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
    }
    func testSupportDiagnosticsReduceErrorsToSafeCategories() {
        XCTAssertEqual(SupportDiagnostics.safeErrorCategory(nil), "none")
        XCTAssertEqual(SupportDiagnostics.safeErrorCategory("Accessibility permission denied for alice@example.com"), "permission")
        XCTAssertEqual(SupportDiagnostics.safeErrorCategory("Bearer secret-token connection failed"), "network")
        XCTAssertEqual(SupportDiagnostics.safeErrorCategory("Unexpected opaque error with private details"), "other (details omitted)")
    }
    func testSupportDiagnosticsOmitIPAddressesFromAPIHost() {
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("136.80.31.73"), "IP address omitted")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("2001:db8::1"), "IP address omitted")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost("pair.example.test"), "pair.example.test")
        XCTAssertEqual(SupportDiagnostics.safeAPIHost(nil), "unavailable")
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
    func testPermissionGuidanceIdentifiesMountedImageAndInstalledCopies() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: URL(fileURLWithPath: "/Applications/PairDesk.app"), homeDirectory: home), .applications)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: URL(fileURLWithPath: "/Users/example/Applications/PairDesk.app"), homeDirectory: home), .applications)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: URL(fileURLWithPath: "/Volumes/PairDesk/PairDesk.app"), homeDirectory: home), .diskImage)
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
    func testAdminAuditWireContractDecodesRFC3339Timestamp() throws {
        let data = Data(#"{"events":[{"actorId":"admin-1","targetId":"member-2","action":"account.password_reset","occurredAt":"2026-10-20T03:00:00Z"}]}"#.utf8)
        let response = try JSONDecoder().decode(AdminAuditResponse.self, from: data)
        XCTAssertEqual(response.events.count, 1)
        XCTAssertEqual(response.events[0].action, "account.password_reset")
        XCTAssertEqual(response.events[0].date, ISO8601DateFormatter().date(from: "2026-10-20T03:00:00Z"))
    }
    func testHostAccessibilityBlockIsReportedOverControlChannel() throws {
        let message = RemoteControlMessage(epoch: "", sequence: 1, kind: .hostPermissionRequired)
        let decoded = try JSONDecoder().decode(RemoteControlMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.kind, .hostPermissionRequired)
        XCTAssertFalse(RemoteControlState.hostPermissionRequired.isGranted)
    }
}
