import Foundation

enum ParticipantAudioVolumePreset: Double, CaseIterable, Identifiable {
    case muted = 0
    case quiet = 0.5
    case reduced = 0.75
    case normal = 1
    case louder = 1.25
    case boosted = 1.5

    var id: Double { rawValue }

    var title: String {
        switch self {
        case .muted: "Mute"
        case .quiet: "50%"
        case .reduced: "75%"
        case .normal: "Normal · 100%"
        case .louder: "125%"
        case .boosted: "Boost · 150%"
        }
    }
}

enum ParticipantAudioVolume {
    static let `default` = ParticipantAudioVolumePreset.normal.rawValue

    static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return `default` }
        return min(ParticipantAudioVolumePreset.boosted.rawValue,
                   max(ParticipantAudioVolumePreset.muted.rawValue, value))
    }

    static func symbol(for value: Double) -> String {
        if value <= 0 { return "speaker.slash.fill" }
        if value < 0.75 { return "speaker.wave.1.fill" }
        if value > 1 { return "speaker.wave.3.fill" }
        return "speaker.wave.2.fill"
    }
}

struct ParticipantAudioVolumePreferences {
    static let defaultsKey = "participantAudioVolumePreferences.v2"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    static func scope(localIdentity: String, mediaServerURL: String) -> String? {
        let identity = localIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty,
              let components = URLComponents(string: mediaServerURL),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else { return nil }

        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path == "/" ? "" : components.path
        return "\(identity)@\(scheme)://\(host)\(port)\(path)"
    }

    func load(scope: String) -> [String: Double] {
        guard !scope.isEmpty,
              let data = defaults.data(forKey: Self.defaultsKey),
              let stored = try? JSONDecoder().decode([String: [String: Double]].self, from: data),
              let values = stored[scope] else { return [:] }
        return values.reduce(into: [:]) { result, entry in
            guard !entry.key.isEmpty else { return }
            result[entry.key] = ParticipantAudioVolume.clamped(entry.value)
        }
    }

    func save(_ values: [String: Double], scope: String) {
        guard !scope.isEmpty else { return }
        var stored = (try? defaults.data(forKey: Self.defaultsKey)
            .map { try JSONDecoder().decode([String: [String: Double]].self, from: $0) }) ?? [:]
        stored[scope] = values.reduce(into: [:]) { result, entry in
            guard !entry.key.isEmpty else { return }
            result[entry.key] = ParticipantAudioVolume.clamped(entry.value)
        }
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Self.defaultsKey) }
    }
}
