import Foundation

/// Read-only dimensions and frame rate reported for a camera track. Missing
/// values stay unavailable instead of being presented as zero.
struct CameraVideoMetrics: Equatable {
    let width: Int?
    let height: Int?
    let framesPerSecond: Int?

    /// Use measured camera geometry when available. A constrained fallback
    /// keeps an invalid or transient stats value from collapsing a tile.
    var aspectRatio: CGFloat {
        guard let width, let height else { return 16.0 / 9.0 }
        let ratio = CGFloat(width) / CGFloat(height)
        guard ratio.isFinite, (0.5...2.5).contains(ratio) else { return 16.0 / 9.0 }
        return ratio
    }

    init(width: UInt? = nil, height: UInt? = nil, framesPerSecond: Double? = nil) {
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
    }

    var summary: String {
        var values: [String] = []
        if let width, let height { values.append("\(width) × \(height)") }
        if let framesPerSecond { values.append("\(framesPerSecond) fps") }
        return values.isEmpty ? "Video stats unavailable" : values.joined(separator: " · ")
    }
}
