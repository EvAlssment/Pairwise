import Foundation
import LiveKit

/// Sender-side screen-share quality preset. The chosen preset is applied when
/// the next display share starts; an already-published track is not renegotiated.
enum ScreenShareQuality: String, CaseIterable, Codable, Identifiable {
    case fast
    case balanced
    case sharp

    static let defaultsKey = "screenShareQuality"
    // Product default: give the share enough detail for code and text at 4K30;
    // adaptive capture can step down to 1440p30 or the 1080p30 floor.
    static let defaultValue: Self = .sharp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast: "Fast · 1080p"
        case .balanced: "Balanced · 1440p"
        case .sharp: "Sharp · 4K"
        }
    }

    var width: Int32 {
        switch self {
        case .fast: 1_920
        case .balanced: 2_560
        case .sharp: 3_840
        }
    }

    var height: Int32 {
        switch self {
        case .fast: 1_080
        case .balanced: 1_440
        case .sharp: 2_160
        }
    }

    var framesPerSecond: Int { 30 }

    var maxBitrate: Int {
        switch self {
        case .fast: 3_000_000
        case .balanced: 5_000_000
        case .sharp: 8_000_000
        }
    }

    var dimensions: Dimensions { Dimensions(width: width, height: height) }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: defaultsKey),
              let quality = Self(rawValue: rawValue) else { return defaultValue }
        return quality
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
