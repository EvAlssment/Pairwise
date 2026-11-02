import Foundation

/// Aggregated quality from the subscribed remote audio streams. No participant
/// identity or audio content is retained in this value.
struct AudioStreamQualityMetrics: Equatable {
    let packetLossPercent: Double?
    let jitterMilliseconds: Int?
    let windowSampleCount: Int

    init(packetLossPercent: Double?, jitterMilliseconds: Int?, windowSampleCount: Int = 1) {
        self.windowSampleCount = min(max(windowSampleCount, 0), 100)
        if let packetLossPercent, packetLossPercent.isFinite, (0...100).contains(packetLossPercent) {
            self.packetLossPercent = packetLossPercent
        } else {
            self.packetLossPercent = nil
        }
        if let jitterMilliseconds, (0...10_000).contains(jitterMilliseconds) {
            self.jitterMilliseconds = jitterMilliseconds
        } else {
            self.jitterMilliseconds = nil
        }
    }

    init(packetsReceived: UInt64?, packetsLost: Int64?, jitterSeconds: Double?) {
        windowSampleCount = 1
        if let packetsReceived, let packetsLost, packetsLost >= 0 {
            let lost = UInt64(packetsLost)
            let total = packetsReceived.addingReportingOverflow(lost)
            if !total.overflow, total.partialValue > 0 {
                packetLossPercent = Double(lost) / Double(total.partialValue) * 100
            } else {
                packetLossPercent = nil
            }
        } else {
            packetLossPercent = nil
        }

        if let jitterSeconds, jitterSeconds.isFinite, (0...10).contains(jitterSeconds) {
            jitterMilliseconds = Int((jitterSeconds * 1_000).rounded())
        } else {
            jitterMilliseconds = nil
        }
    }

    var hasMeasurements: Bool { packetLossPercent != nil || jitterMilliseconds != nil }

    var diagnosticSummary: String? {
        guard hasMeasurements else { return nil }
        var measurements: [String] = []
        if let packetLossPercent {
            measurements.append("\(packetLossPercent.formatted(.number.precision(.fractionLength(1))))% packet loss")
        }
        if let jitterMilliseconds { measurements.append("\(jitterMilliseconds) ms jitter") }
        let state = warningSummary.map { "Elevated: \($0)" } ?? "No elevated loss or jitter"
        return "\(state) · Recent measurements: \(measurements.joined(separator: ", "))"
    }

    var warningSummary: String? {
        guard windowSampleCount >= 3 else { return nil }
        var warnings: [String] = []
        if let packetLossPercent, packetLossPercent >= 3 {
            warnings.append("\(packetLossPercent.formatted(.number.precision(.fractionLength(1))))% packet loss")
        }
        if let jitterMilliseconds, jitterMilliseconds >= 40 {
            warnings.append("\(jitterMilliseconds) ms jitter")
        }
        return warnings.isEmpty ? nil : warnings.joined(separator: " · ")
    }
}

struct AudioQualitySummary: Equatable {
    let streamCount: Int
    let measuredStreamCount: Int
    let peakPacketLossPercent: Double?
    let maximumJitterMilliseconds: Int?
    let warningMetrics: AudioStreamQualityMetrics?

    init(streams: [AudioStreamQualityMetrics?]) {
        streamCount = streams.count
        let measured = streams.compactMap { $0 }.filter(\.hasMeasurements)
        measuredStreamCount = measured.count
        peakPacketLossPercent = measured.compactMap(\.packetLossPercent).max()
        maximumJitterMilliseconds = measured.compactMap(\.jitterMilliseconds).max()

        // Only compare tracks that have enough recent samples to distinguish
        // sustained degradation from a single transient measurement.
        let warningReady = measured.filter { $0.windowSampleCount >= 3 }
        warningMetrics = warningReady.isEmpty ? nil : AudioStreamQualityMetrics(
            packetLossPercent: warningReady.compactMap(\.packetLossPercent).max(),
            jitterMilliseconds: warningReady.compactMap(\.jitterMilliseconds).max(),
            windowSampleCount: warningReady.map(\.windowSampleCount).max() ?? 0
        )
    }

    var summary: String {
        guard streamCount > 0 else { return "unavailable" }
        guard measuredStreamCount > 0 else {
            return streamCount == 1 ? "1 audio path · stats unavailable" : "\(streamCount) audio paths · stats unavailable"
        }

        let streamLabel = streamCount == 1 ? "1 remote audio path" : "\(streamCount) remote audio paths"
        var values = [streamLabel]
        if measuredStreamCount < streamCount { values.append("\(measuredStreamCount) measured") }
        if let peakPacketLossPercent {
            values.append("peak loss \(peakPacketLossPercent.formatted(.number.precision(.fractionLength(1))))%")
        }
        if let maximumJitterMilliseconds { values.append("max jitter \(maximumJitterMilliseconds) ms") }
        return values.joined(separator: " · ")
    }
}

/// Tracks short-window RTP deltas so a long call's historical counters do not
/// mask a recent audio-path regression. Jitter uses a median over the same
/// window to avoid a one-sample spike flashing the warning indicator.
struct AudioQualityWindow {
    private struct CounterSample {
        let packetsReceived: UInt64
        let packetsLost: UInt64
        let uptime: TimeInterval
    }

    private struct Sample {
        let uptime: TimeInterval
        let receivedDelta: UInt64?
        let lostDelta: UInt64?
        let jitterMilliseconds: Int?
    }

    private struct StreamState {
        var previousCounters: CounterSample?
        var samples: [Sample] = []
    }

    private let windowDuration: TimeInterval
    private var streams: [String: StreamState] = [:]

    init(windowDuration: TimeInterval = 10) {
        self.windowDuration = windowDuration.isFinite && windowDuration > 0 ? windowDuration : 10
    }

    mutating func record(streamID: String,
                         packetsReceived: UInt64?,
                         packetsLost: Int64?,
                         jitterSeconds: Double?,
                         at uptime: TimeInterval) -> AudioStreamQualityMetrics? {
        guard !streamID.isEmpty, uptime.isFinite else { return nil }
        var state = streams[streamID] ?? StreamState()
        var receivedDelta: UInt64?
        var lostDelta: UInt64?

        if let packetsReceived, let packetsLost, packetsLost >= 0 {
            let current = CounterSample(packetsReceived: packetsReceived,
                                        packetsLost: UInt64(packetsLost),
                                        uptime: uptime)
            if let previous = state.previousCounters,
               uptime > previous.uptime,
               uptime - previous.uptime <= windowDuration,
               packetsReceived >= previous.packetsReceived,
               current.packetsLost >= previous.packetsLost {
                receivedDelta = packetsReceived - previous.packetsReceived
                lostDelta = current.packetsLost - previous.packetsLost
            }
            state.previousCounters = current
        } else {
            state.previousCounters = nil
        }

        let jitterMilliseconds: Int?
        if let jitterSeconds, jitterSeconds.isFinite, (0...10).contains(jitterSeconds) {
            jitterMilliseconds = Int((jitterSeconds * 1_000).rounded())
        } else {
            jitterMilliseconds = nil
        }

        if receivedDelta != nil || jitterMilliseconds != nil {
            state.samples.append(Sample(uptime: uptime,
                                        receivedDelta: receivedDelta,
                                        lostDelta: lostDelta,
                                        jitterMilliseconds: jitterMilliseconds))
        }
        state.samples.removeAll { uptime - $0.uptime > windowDuration }
        streams[streamID] = state
        return metrics(for: state)
    }

    mutating func reset(streamID: String) {
        streams.removeValue(forKey: streamID)
    }

    mutating func reset() {
        streams.removeAll()
    }

    private func metrics(for state: StreamState) -> AudioStreamQualityMetrics? {
        let counters = state.samples.compactMap { sample -> (UInt64, UInt64)? in
            guard let received = sample.receivedDelta, let lost = sample.lostDelta else { return nil }
            return (received, lost)
        }
        let receivedTotal = counters.reduce(0.0) { $0 + Double($1.0) }
        let lostTotal = counters.reduce(0.0) { $0 + Double($1.1) }
        let packetLoss: Double? = receivedTotal + lostTotal > 0
            ? lostTotal / (receivedTotal + lostTotal) * 100
            : nil
        let jitterSamples = state.samples.compactMap(\.jitterMilliseconds).sorted()
        let jitter: Int?
        if jitterSamples.isEmpty {
            jitter = nil
        } else {
            let middle = jitterSamples.count / 2
            jitter = jitterSamples.count.isMultiple(of: 2)
                ? Int((Double(jitterSamples[middle - 1] + jitterSamples[middle]) / 2).rounded())
                : jitterSamples[middle]
        }
        let result = AudioStreamQualityMetrics(packetLossPercent: packetLoss,
                                               jitterMilliseconds: jitter,
                                               windowSampleCount: state.samples.count)
        return result.hasMeasurements ? result : nil
    }
}
