import Darwin
import Foundation

struct ProcessCPUReading: Equatable {
    let uptimeSeconds: TimeInterval
    let cpuSeconds: TimeInterval

    static func capture() -> Self? {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        let reading = Self(uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                           cpuSeconds: user + system)
        return reading.isValid ? reading : nil
    }

    var isValid: Bool {
        uptimeSeconds.isFinite && uptimeSeconds >= 0 && cpuSeconds.isFinite && cpuSeconds >= 0
    }
}

struct ScreenShareProcessCPUUsage: Equatable {
    let averagePercent: Double?
    let peakPercent: Double?
    let durationSeconds: Int?

    static let unavailable = Self(averagePercent: nil, peakPercent: nil, durationSeconds: nil)

    var summary: String {
        guard let averagePercent, let peakPercent, let durationSeconds,
              averagePercent.isFinite, peakPercent.isFinite else { return "unavailable" }
        return "avg \(Int(averagePercent.rounded()))% · peak \(Int(peakPercent.rounded()))% · \(durationSeconds)s"
    }
}

/// Estimates PairDesk process CPU as a percentage of one logical core.
/// Samples are local-only and retained for the most recent 15 seconds.
struct ScreenShareProcessCPUWindow {
    private struct Sample: Equatable {
        let uptimeSeconds: TimeInterval
        let elapsedSeconds: TimeInterval
        let percent: Double
    }

    static let durationSeconds: TimeInterval = 15
    static let maximumSamples = 60
    private let maximumSamplingGapSeconds: TimeInterval = 4
    private var previous: ProcessCPUReading?
    private var samples: [Sample] = []

    mutating func observe(_ reading: ProcessCPUReading?) {
        guard let reading, reading.isValid else {
            reset()
            return
        }

        guard let previous else {
            self.previous = reading
            return
        }
        self.previous = reading

        let elapsed = reading.uptimeSeconds - previous.uptimeSeconds
        let cpuElapsed = reading.cpuSeconds - previous.cpuSeconds
        guard elapsed > 0, elapsed <= maximumSamplingGapSeconds,
              cpuElapsed >= 0, cpuElapsed.isFinite else {
            samples.removeAll(keepingCapacity: true)
            return
        }

        let percent = cpuElapsed / elapsed * 100
        guard percent.isFinite, percent >= 0 else { return }
        samples.append(Sample(uptimeSeconds: reading.uptimeSeconds,
                              elapsedSeconds: elapsed,
                              percent: percent))
        let oldestAllowed = reading.uptimeSeconds - Self.durationSeconds
        samples.removeAll { $0.uptimeSeconds < oldestAllowed }
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }

    mutating func reset() {
        previous = nil
        samples.removeAll(keepingCapacity: true)
    }

    var usage: ScreenShareProcessCPUUsage {
        guard !samples.isEmpty else { return .unavailable }
        let latest = samples[samples.count - 1].uptimeSeconds
        let oldestAllowed = latest - Self.durationSeconds
        var weightedCPUSeconds = 0.0
        var coveredSeconds = 0.0
        var peakPercent: Double?
        for sample in samples {
            let intervalStart = sample.uptimeSeconds - sample.elapsedSeconds
            let covered = max(0, sample.uptimeSeconds - max(intervalStart, oldestAllowed))
            guard covered > 0 else { continue }
            weightedCPUSeconds += sample.percent * covered
            coveredSeconds += covered
            peakPercent = max(peakPercent ?? 0, sample.percent)
        }
        guard coveredSeconds > 0, let peakPercent else { return .unavailable }
        return ScreenShareProcessCPUUsage(averagePercent: weightedCPUSeconds / coveredSeconds,
                                          peakPercent: peakPercent,
                                          durationSeconds: max(1, Int(coveredSeconds.rounded())))
    }
}
