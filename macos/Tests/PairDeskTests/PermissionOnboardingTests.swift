import Foundation
import XCTest
@testable import PairDesk

final class PermissionOnboardingTests: XCTestCase {
    func testOnlyPathsInsideActualDiskImageMountsAreClassifiedAsDiskImages() {
        let mount = URL(fileURLWithPath: "/Volumes/PairDesk Installer", isDirectory: true)
        let imageApp = URL(fileURLWithPath: "/Volumes/PairDesk Installer/PairDesk.app", isDirectory: true)
        let externalDriveApp = URL(fileURLWithPath: "/Volumes/PairDesk Installer Backup/PairDesk.app", isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

        XCTAssertEqual(AppCopyLocation.classify(bundleURL: imageApp, homeDirectory: home,
                                                 diskImageMountPoints: [mount]), .diskImage)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: externalDriveApp, homeDirectory: home,
                                                 diskImageMountPoints: [mount]), .other(externalDriveApp.path))
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: externalDriveApp, homeDirectory: home),
                       .other(externalDriveApp.path), "An external volume is not necessarily a disk image")
    }

    func testApplicationsLocationsUsePathBoundaries() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        let systemApp = URL(fileURLWithPath: "/Applications/PairDesk.app", isDirectory: true)
        let userApp = URL(fileURLWithPath: "/Users/test/Applications/PairDesk.app", isDirectory: true)
        let similarlyNamedRoot = URL(fileURLWithPath: "/Applications-Archive/PairDesk.app", isDirectory: true)

        XCTAssertEqual(AppCopyLocation.classify(bundleURL: systemApp, homeDirectory: home), .applications)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: userApp, homeDirectory: home), .applications)
        XCTAssertEqual(AppCopyLocation.classify(bundleURL: similarlyNamedRoot, homeDirectory: home),
                       .other(similarlyNamedRoot.path))
    }

    func testDiskImageMountPointParserReadsMountedSystemEntitiesOnly() throws {
        let plist: [String: Any] = [
            "images": [
                ["system-entities": [
                    ["dev-entry": "/dev/disk4s1", "mount-point": "/Volumes/PairDesk"],
                    ["dev-entry": "/dev/disk4", "content-hint": "GUID_partition_scheme"]
                ]],
                ["system-entities": [["dev-entry": "/dev/disk5"]]]
            ]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)

        XCTAssertEqual(MountedDiskImageDiagnostics.mountPoints(in: data), [
            URL(fileURLWithPath: "/Volumes/PairDesk", isDirectory: true)
        ])
        XCTAssertTrue(MountedDiskImageDiagnostics.mountPoints(in: Data("invalid".utf8)).isEmpty)
    }

    func testDuplicateCopyDiagnosticsIgnoreCurrentAndDifferentApps() {
        let first = URL(fileURLWithPath: "/Applications/PairDesk.app", isDirectory: true)
        let second = URL(fileURLWithPath: "/Users/test/Downloads/PairDesk.app", isDirectory: true)
        let copies = [
            RunningAppCopy(processIdentifier: 10, bundleIdentifier: "app.internal.pairdesk", bundleURL: first),
            RunningAppCopy(processIdentifier: 11, bundleIdentifier: "app.internal.pairdesk", bundleURL: second),
            RunningAppCopy(processIdentifier: 12, bundleIdentifier: "com.example.other", bundleURL: second),
            RunningAppCopy(processIdentifier: 13, bundleIdentifier: "app.internal.pairdesk", bundleURL: nil)
        ]

        XCTAssertEqual(RunningAppCopyDiagnostics.otherCopyPaths(bundleIdentifier: "app.internal.pairdesk",
                                                                 currentProcessIdentifier: 10,
                                                                 runningApplications: copies), [second.path])
        XCTAssertTrue(RunningAppCopyDiagnostics.otherCopyPaths(bundleIdentifier: nil,
                                                                currentProcessIdentifier: 10,
                                                                runningApplications: copies).isEmpty)
    }
}
