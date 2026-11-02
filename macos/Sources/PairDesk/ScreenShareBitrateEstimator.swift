import Foundation

/// Estimates current video bitrate from consecutive WebRTC byte counters.
/// The first sample and counter resets intentionally show no value.
struct ScreenShareBitrateEstimator {
    private var previousByteCount: UInt64?
    private var previousTime: TimeInterval?

    mutating func sample(byteCount: UInt64?, at time: TimeInterval) -> Double? {
        guard let byteCount, time.isFinite else {
            reset()
            return nil
        }

        defer {
            previousByteCount = byteCount
            previousTime = time
        }

        guard let previousByteCount, let previousTime,
              byteCount >= previousByteCount else { return nil }
        let elapsed = time - previousTime
        guard elapsed.isFinite, (0.25...15).contains(elapsed) else { return nil }

        let megabitsPerSecond = Double(byteCount - previousByteCount) * 8 / elapsed / 1_000_000
        guard megabitsPerSecond.isFinite, (0...10_000).contains(megabitsPerSecond) else { return nil }
        return megabitsPerSecond
    }

    mutating func reset() {
        previousByteCount = nil
        previousTime = nil
    }
}
