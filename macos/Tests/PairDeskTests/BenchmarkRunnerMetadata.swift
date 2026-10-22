import Darwin
import Foundation

/// Publicly identifying runner characteristics used to compare synthetic CI
/// reports. This intentionally excludes hostnames, serial numbers, usernames,
/// and other per-machine identity.
struct BenchmarkRunnerMetadata: Codable, Equatable {
    let platform: String
    let osVersion: String
    let architecture: String
    let modelIdentifier: String
    let logicalCPUCount: Int

    static func current() -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var system = utsname()
        let architecture: String
        if uname(&system) == 0 {
            var machine = system.machine
            let capacity = MemoryLayout.size(ofValue: machine)
            architecture = withUnsafePointer(to: &machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
        } else {
            architecture = "unknown"
        }
        return Self(platform: "macOS",
                    osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                    architecture: architecture,
                    modelIdentifier: sysctlString("hw.model") ?? "unknown",
                    logicalCPUCount: ProcessInfo.processInfo.processorCount)
    }

    private static func sysctlString(_ key: String) -> String? {
        var length = 0
        guard sysctlbyname(key, nil, &length, nil, 0) == 0, length > 1 else { return nil }
        var value = [CChar](repeating: 0, count: length)
        guard sysctlbyname(key, &value, &length, nil, 0) == 0 else { return nil }
        return String(cString: value)
    }
}
