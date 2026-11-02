import Foundation

/// Read-only measurements from the video stream as decoded by this viewer.
/// These describe the received stream, not the sender's requested preset.
struct ScreenStreamMetrics: Equatable {
    let width: Int?
    let height: Int?
    let framesPerSecond: Int?
    let bitrateMegabitsPerSecond: Double?
    let packetLossPercent: Double?

    init(width: UInt? = nil,
         height: UInt? = nil,
         framesPerSecond: Double? = nil,
         bitrateMegabitsPerSecond: Double? = nil,
         packetsReceived: UInt64? = nil,
         packetsLost: Int64? = nil) {
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

        if let packetsReceived, let packetsLost, packetsLost >= 0 {
            let lost = UInt64(packetsLost)
            let total = packetsReceived.addingReportingOverflow(lost)
            if !total.overflow, total.partialValue > 0 {
                self.packetLossPercent = Double(lost) / Double(total.partialValue) * 100
            } else {
                self.packetLossPercent = nil
            }
        } else {
            self.packetLossPercent = nil
        }
    }

    var summary: String {
        var values: [String] = []
        if let width, let height { values.append("\(width) × \(height)") }
        if let framesPerSecond { values.append("\(framesPerSecond) fps") }
        if let bitrateMegabitsPerSecond {
            values.append("\(bitrateMegabitsPerSecond.formatted(.number.precision(.fractionLength(1)))) Mbps")
        }
        if let packetLossPercent { values.append(String(format: "%.1f%% loss", packetLossPercent)) }
        return values.isEmpty ? "Stream stats unavailable" : values.joined(separator: " · ")
    }
}
