import Foundation

/// A short rolling view of control-channel request/ack RTT. This measures the
/// PairDesk data channel through the sharer's receive/ack path; it does not
/// claim to measure OS input injection or display scanout.
struct ControlChannelLatency: Equatable {
    private(set) var samples: [Int] = []
    private(set) var lastSampleUptime: TimeInterval?
    static let maximumSampleCount = 5

    var latestMilliseconds: Int? { samples.last }

    var medianMilliseconds: Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }

    var summary: String {
        summary(at: ProcessInfo.processInfo.systemUptime)
    }

    func summary(at uptime: TimeInterval) -> String {
        guard let medianMilliseconds, let latestMilliseconds else { return "Measuring" }
        if let lastSampleUptime, uptime - lastSampleUptime > 10 {
            return "No recent response · median \(medianMilliseconds) ms"
        }
        return "median \(medianMilliseconds) ms · latest \(latestMilliseconds) ms · \(samples.count) samples"
    }

    mutating func record(milliseconds: Int, at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard (0...60_000).contains(milliseconds), uptime.isFinite else { return }
        samples.append(milliseconds)
        lastSampleUptime = uptime
        if samples.count > Self.maximumSampleCount {
            samples.removeFirst(samples.count - Self.maximumSampleCount)
        }
    }

    mutating func reset() {
        samples.removeAll()
        lastSampleUptime = nil
    }
}
