import AppKit
import Combine
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

struct HiddenApplication: Codable, Hashable, Identifiable {
    let bundleIdentifier: String
    let name: String

    var id: String { bundleIdentifier }
}

@MainActor
final class PrivacyVeilPreferences: ObservableObject {
    static let shared = PrivacyVeilPreferences()
    static let defaultsKey = "privacyVeilHiddenApplications"

    @Published private(set) var applications: [HiddenApplication]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([HiddenApplication].self, from: data) {
            applications = Self.unique(stored)
        } else {
            applications = []
        }
    }

    var bundleIdentifiers: Set<String> { Set(applications.map(\.bundleIdentifier)) }

    func addApplicationsFromPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose apps to hide while sharing a display"
        panel.prompt = "Hide apps"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK else { return }

        let additions = panel.urls.compactMap { url -> HiddenApplication? in
            guard let bundle = Bundle(url: url), let identifier = bundle.bundleIdentifier else { return nil }
            guard identifier != Bundle.main.bundleIdentifier else { return nil }
            let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            return HiddenApplication(bundleIdentifier: identifier, name: name)
        }
        applications = Self.unique(applications + additions).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persist()
    }

    func remove(_ application: HiddenApplication) {
        applications.removeAll { $0.bundleIdentifier == application.bundleIdentifier }
        persist()
    }

    /// Keep configured apps that are not currently represented in the picker.
    /// For apps visible to this share, the review dialog becomes the source of truth.
    func saveShareSelection(_ selected: [SCRunningApplication], visible: [SCRunningApplication]) {
        let visibleIDs = Set(visible.map(\.bundleIdentifier))
        let selectedByID = Dictionary(selected.map { ($0.bundleIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
        let retained = applications.filter { !visibleIDs.contains($0.bundleIdentifier) }
        let chosen = selectedByID.values.map {
            HiddenApplication(bundleIdentifier: $0.bundleIdentifier, name: $0.applicationName)
        }
        applications = Self.unique(retained + chosen).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(applications) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func unique(_ applications: [HiddenApplication]) -> [HiddenApplication] {
        var byID: [String: HiddenApplication] = [:]
        for application in applications where !application.bundleIdentifier.isEmpty {
            byID[application.bundleIdentifier] = application
        }
        return Array(byID.values)
    }
}
