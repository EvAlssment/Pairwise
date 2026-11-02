import Foundation

enum ScreenShareSenderLimitation: Equatable {
    case none
    case bandwidth
    case cpu
    case other

    var label: String? {
        switch self {
        case .none: nil
        case .bandwidth: "network constrained"
        case .cpu: "Mac load constrained"
        case .other: "encoder constrained"
        }
    }
}

/// Read-only measurements from the active screen-share sender track. These
/// report the encoder's current output; the selected quality is only a cap.
struct ScreenShareSenderMetrics: Equatable {
    let width: Int?
    let height: Int?
    let framesPerSecond: Int?
    let bitrateMegabitsPerSecond: Double?
    let limitation: ScreenShareSenderLimitation

    init(width: UInt? = nil,
         height: UInt? = nil,
         framesPerSecond: Double? = nil,
         bitrateMegabitsPerSecond: Double? = nil,
         limitation: ScreenShareSenderLimitation = .none) {
        if let width, let height, width > 0, height > 0 {
            self.width = Int(width)
            self.height = Int(height)
        } else {
            self.width = nil
            self.height = nil
        }
        if let framesPerSecond, framesPerSecond.isFinite, (0...120).contains(framesPerSecond) {
            self.framesPerSecond = Int(framesPerSecond.rounded())
        } else {
            self.framesPerSecond = nil
        }
        if let bitrateMegabitsPerSecond,
           bitrateMegabitsPerSecond.isFinite,
           (0...10_000).contains(bitrateMegabitsPerSecond) {
            self.bitrateMegabitsPerSecond = bitrateMegabitsPerSecond
        } else {
            self.bitrateMegabitsPerSecond = nil
        }
        self.limitation = limitation
    }

    var summary: String {
        var values: [String] = []
        if let width, let height { values.append("\(width) × \(height)") }
        if let framesPerSecond { values.append("\(framesPerSecond) fps") }
        if let bitrateMegabitsPerSecond {
            values.append("\(bitrateMegabitsPerSecond.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        if let label = limitation.label { values.append(label) }
        return values.isEmpty ? "Measuring outbound video" : values.joined(separator: " · ")
    }
}

enum ScreenShareSenderReport {
    static func text(metrics: ScreenShareSenderMetrics,
                     maximum: ScreenShareQuality,
                     adaptiveQualityEnabled: Bool,
                     localProcessCPU: ScreenShareProcessCPUUsage) -> String {
        """
        PairDesk screen-share sender report
        Encoder output: \(metrics.summary)
        Selected maximum: \(maximum.title)
        Adaptive quality: \(adaptiveQualityEnabled ? "on" : "off")
        PairDesk process CPU (percentage of one logical core): \(localProcessCPU.summary)

        Privacy: local technical measurements only; no account names, screen content, or network addresses.
        """
    }
}
