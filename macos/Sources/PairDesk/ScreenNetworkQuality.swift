import Foundation

/// One content-free sample of the screen stream's selected media path.
struct ScreenQualitySample: Equatable {
    let uptimeSeconds: TimeInterval
    let roundTripMilliseconds: Int?
    let framesPerSecond: Int?
    let packetLossPercent: Double?
}

/// A bounded, per-share one-minute history of media-path measurements.
struct ScreenQualityHistory: Equatable {
    static let capacity = 60
    static let windowDurationSeconds: TimeInterval = 60
    private(set) var samples: [ScreenQualitySample] = []

    var roundTripReadings: [Int] { samples.compactMap(\.roundTripMilliseconds) }
    var peakRoundTripMilliseconds: Int? { roundTripReadings.max() }
    var medianRoundTripMilliseconds: Int? {
        let readings = roundTripReadings.sorted()
        guard !readings.isEmpty else { return nil }
        let middle = readings.count / 2
        return readings.count.isMultiple(of: 2)
            ? (readings[middle - 1] + readings[middle]) / 2
            : readings[middle]
    }

    var summary: String {
        guard let median = medianRoundTripMilliseconds,
              let peak = peakRoundTripMilliseconds else { return "RTT unavailable" }
        return "RTT median \(median) ms · peak \(peak) ms · \(roundTripReadings.count) readings"
    }

    var chartCeilingMilliseconds: Int {
        guard let peak = peakRoundTripMilliseconds else { return 300 }
        if peak <= 150 { return 150 }
        if peak <= 300 { return 300 }
        if peak <= 600 { return 600 }
        if peak <= 1_000 { return 1_000 }
        return ((peak + 499) / 500) * 500
    }

    mutating func record(_ sample: ScreenQualitySample) {
        guard sample.uptimeSeconds.isFinite, sample.uptimeSeconds >= 0,
              sample.roundTripMilliseconds.map({ $0 >= 0 }) ?? true,
              sample.framesPerSecond.map({ (0...120).contains($0) }) ?? true,
              sample.packetLossPercent.map({ $0.isFinite && (0...100).contains($0) }) ?? true,
              samples.last.map({ sample.uptimeSeconds > $0.uptimeSeconds }) ?? true else { return }
        samples.append(sample)
        let oldestAllowed = sample.uptimeSeconds - Self.windowDurationSeconds
        samples.removeAll { $0.uptimeSeconds < oldestAllowed }
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }
}

struct CandidatePairRTT: Equatable {
    let id: String
    let roundTripTimeSeconds: Double?
}

enum ScreenNetworkQuality: Equatable {
    case measuring
    case good(roundTripMilliseconds: Int)
    case fair(roundTripMilliseconds: Int)
    case highLatency(roundTripMilliseconds: Int)

    static func from(roundTripTimeSeconds: Double?) -> Self {
        guard let seconds = roundTripTimeSeconds, seconds.isFinite, seconds >= 0 else { return .measuring }
        let milliseconds = Int((seconds * 1_000).rounded())
        if milliseconds <= 150 { return .good(roundTripMilliseconds: milliseconds) }
        if milliseconds <= 300 { return .fair(roundTripMilliseconds: milliseconds) }
        return .highLatency(roundTripMilliseconds: milliseconds)
    }

    /// Returns the RTT of the ICE pair selected by the transport. Other
    /// succeeded/nominated pairs can be probes or stale alternatives and must
    /// not make the active media path look faster than it is.
    static func selectedRoundTripTimeSeconds(selectedPairID: String?, pairs: [CandidatePairRTT]) -> Double? {
        guard let selectedPairID, !selectedPairID.isEmpty else { return nil }
        return pairs.first(where: { $0.id == selectedPairID })?.roundTripTimeSeconds
    }

    var label: String {
        switch self {
        case .measuring: "Measuring network"
        case let .good(milliseconds): "Good · \(milliseconds) ms RTT"
        case let .fair(milliseconds): "Fair · \(milliseconds) ms RTT"
        case let .highLatency(milliseconds): "High latency · \(milliseconds) ms RTT"
        }
    }

    var shortTitle: String {
        switch self {
        case .measuring: "Measuring"
        case .good: "Good"
        case .fair: "Fair"
        case .highLatency: "High latency"
        }
    }
}

struct ScreenQualityReport: Equatable {
    let networkQuality: ScreenNetworkQuality
    let controlChannelRTT: String
    let receivedStream: String
    let localProcessCPU: String
    let firstFrameMilliseconds: Int?
    let history: ScreenQualityHistory

    init(networkQuality: ScreenNetworkQuality,
         controlChannelRTT: String,
         receivedStream: String,
         localProcessCPU: String = "unavailable",
         firstFrameMilliseconds: Int?,
         history: ScreenQualityHistory = ScreenQualityHistory()) {
        self.networkQuality = networkQuality
        self.controlChannelRTT = controlChannelRTT
        self.receivedStream = receivedStream
        self.localProcessCPU = localProcessCPU
        self.firstFrameMilliseconds = firstFrameMilliseconds
        self.history = history
    }

    var text: String {
        """
        PairDesk shared-screen quality
        Network: \(networkQuality.label)
        Recent path: \(history.summary)
        Control channel RTT: \(controlChannelRTT)
        Received screen: \(receivedStream)
        PairDesk process CPU: \(localProcessCPU)
        First frame: \(firstFrameMilliseconds.map { "\($0) ms" } ?? "unavailable")
        """
    }
}
