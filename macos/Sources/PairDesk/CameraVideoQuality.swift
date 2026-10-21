import Foundation
import LiveKit

enum CameraVideoQuality: String, CaseIterable, Codable, Identifiable {
    case economy
    case balanced
    case sharp

    static let defaultsKey = "cameraVideoQuality"
    static let defaultValue: Self = .balanced

    var id: String { rawValue }
    var title: String {
        switch self {
        case .economy: "Economy · 360p"
        case .balanced: "Balanced · 720p"
        case .sharp: "Sharp · 1080p"
        }
    }
    var shortTitle: String {
        switch self {
        case .economy: "360p"
        case .balanced: "720p"
        case .sharp: "1080p"
        }
    }
    var dimensions: Dimensions {
        switch self {
        case .economy: Dimensions(width: 640, height: 360)
        case .balanced: Dimensions(width: 1280, height: 720)
        case .sharp: Dimensions(width: 1920, height: 1080)
        }
    }
    var framesPerSecond: Int { 30 }
    var maxBitrate: Int {
        switch self {
        case .economy: 500_000
        case .balanced: 1_500_000
        case .sharp: 3_000_000
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        guard let raw = defaults.string(forKey: defaultsKey), let value = Self(rawValue: raw) else { return defaultValue }
        return value
    }

    func persist(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }
}
