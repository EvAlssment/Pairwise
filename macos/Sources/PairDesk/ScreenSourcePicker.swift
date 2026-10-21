import Foundation
import AppKit
import ScreenCaptureKit
import SwiftUI

enum ScreenShareSource: String, CaseIterable, Identifiable {
    case display, region, window

    var id: String { rawValue }
    var title: String {
        switch self {
        case .display: return "Entire display"
        case .region: return "Region"
        case .window: return "Window"
        }
    }
    var explanation: String {
        switch self {
        case .display: return "Choose the entire display you want to share in the macOS picker."
        case .region: return "Choose a display in the macOS picker, then select the region you want to share."
        case .window: return "Choose a window in the macOS picker. Other windows stay private."
        }
    }
}

enum ScreenCropGeometry {
    static func normalizedCrop(dragRect: CGRect, contentRect: CGRect) -> CGRect? {
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }
        let clipped = dragRect.standardized.intersection(contentRect)
        guard !clipped.isNull, clipped.width >= 24, clipped.height >= 24 else { return nil }
        return CGRect(x: (clipped.minX - contentRect.minX) / contentRect.width,
                      y: (clipped.minY - contentRect.minY) / contentRect.height,
                      width: clipped.width / contentRect.width,
                      height: clipped.height / contentRect.height)
    }

    static func sourceRect(normalizedCrop: CGRect, displaySize: CGSize) -> CGRect? {
        guard displaySize.width > 0, displaySize.height > 0,
              normalizedCrop.minX >= 0, normalizedCrop.minY >= 0,
              normalizedCrop.maxX <= 1, normalizedCrop.maxY <= 1,
              normalizedCrop.width > 0, normalizedCrop.height > 0 else { return nil }
        return CGRect(x: normalizedCrop.minX * displaySize.width,
                      y: normalizedCrop.minY * displaySize.height,
                      width: normalizedCrop.width * displaySize.width,
                      height: normalizedCrop.height * displaySize.height)
    }
}

private struct ScreenCropSelectionView: View {
    let image: NSImage
    let onCancel: () -> Void
    let onShare: (CGRect?) -> Void
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var normalizedSelection: CGRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select the part of your screen to share")
                .font(.headline)
            Text("Drag over the code or app you want to show. The rest of your screen stays private.")
                .font(.caption).foregroundStyle(.secondary)
            GeometryReader { geometry in
                let content = ScreenCoordinateMapper.contentRect(
                    container: CGRect(origin: .zero, size: geometry.size),
                    contentSize: image.size
                ) ?? CGRect(origin: .zero, size: geometry.size)
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Canvas { context, _ in
                        let selection = visibleSelection(in: content)
                        if let selection {
                            context.fill(Path(selection), with: .color(.white.opacity(0.12)))
                            context.stroke(Path(selection), with: .color(.white), lineWidth: 2)
                            context.stroke(Path(selection.insetBy(dx: 1, dy: 1)), with: .color(.black.opacity(0.7)), lineWidth: 1)
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .local)
                    .onChanged { value in
                        if dragStart == nil { dragStart = value.startLocation }
                        dragCurrent = value.location
                    }
                    .onEnded { value in
                        let start = dragStart ?? value.startLocation
                        let drag = CGRect(x: min(start.x, value.location.x),
                                          y: min(start.y, value.location.y),
                                          width: abs(value.location.x - start.x),
                                          height: abs(value.location.y - start.y))
                        normalizedSelection = ScreenCropGeometry.normalizedCrop(dragRect: drag, contentRect: content)
                        dragStart = nil
                        dragCurrent = nil
                    })
                .onChange(of: geometry.size) { _, _ in normalizedSelection = nil }
            }
            .frame(minHeight: 330)
            HStack {
                Spacer()
                Button("Share entire display") { onShare(nil) }.buttonStyle(QuietButtonStyle())
                Button("Cancel", action: onCancel).buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Share selected region") {
                    if let normalizedSelection { onShare(normalizedSelection) }
                }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedSelection == nil)
            }
        }
        .padding(18)
        .frame(width: 820, height: 600)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }

    private func visibleSelection(in content: CGRect) -> CGRect? {
        if let normalizedSelection {
            return CGRect(x: content.minX + normalizedSelection.minX * content.width,
                          y: content.minY + normalizedSelection.minY * content.height,
                          width: normalizedSelection.width * content.width,
                          height: normalizedSelection.height * content.height)
        }
        guard let start = dragStart, let current = dragCurrent else { return nil }
        return CGRect(x: min(start.x, current.x), y: min(start.y, current.y),
                      width: abs(current.x - start.x), height: abs(current.y - start.y))
    }
}

/// Uses Apple's native picker and limits capture access to one user-selected display or window.
@available(macOS 14.0, *)
@MainActor
final class SystemScreenPicker: NSObject, @preconcurrency SCContentSharingPickerObserver, NSWindowDelegate {
    static let shared = SystemScreenPicker()
    private var continuation: CheckedContinuation<SCContentFilter, Error>?
    private var cropContinuation: CheckedContinuation<CGRect?, Error>?
    private var cropWindow: NSWindow?
    private var privacyContinuation: CheckedContinuation<[SCRunningApplication], Error>?
    private var privacyWindow: NSWindow?
    private var privacyWindowDelegate: PrivacyVeilWindowDelegate?

    func chooseSource(_ source: ScreenShareSource = .display) async throws -> (filter: SCContentFilter, sourceRect: CGRect, excludedApplications: [SCRunningApplication]) {
        let filter = try await chooseDisplay(source)
        guard source == .region, filter.style != .window else {
            let excluded = try await choosePrivacyVeilApplications(for: filter, source: source)
            return (filter, .zero, excluded)
        }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(filter.contentRect.width * 2))
        configuration.height = max(1, Int(filter.contentRect.height * 2))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let normalized = try await chooseCrop(for: NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height)))
        guard let normalized else { return (filter, .zero, []) }
        let displaySize = CGSize(width: filter.contentRect.width, height: filter.contentRect.height)
        guard let sourceRect = ScreenCropGeometry.sourceRect(normalizedCrop: normalized, displaySize: displaySize) else {
            throw CocoaError(.validationMissingMandatoryProperty)
        }
        let excluded = try await choosePrivacyVeilApplications(for: filter, source: source)
        return (filter, sourceRect, excluded)
    }

    /// Captures one user-selected window for the local agent. The image remains
    /// in memory and is returned only to the already-authorized local request.
    func captureAgentScreenshot() async throws -> Data {
        let filter = try await chooseDisplay(.window)
        guard filter.style == .window else { throw CocoaError(.userCancelled) }
        let maxDimension: CGFloat = 1_920
        let width = max(1, filter.contentRect.width)
        let height = max(1, filter.contentRect.height)
        let scale = min(1, maxDimension / max(width, height))
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(width * scale))
        configuration.height = max(1, Int(height * scale))
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        guard let png, !png.isEmpty, png.count <= 2_000_000 else {
            throw NSError(domain: "PairDesk.AgentScreenshot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The selected window screenshot is too large to share safely."])
        }
        return png
    }

    /// Offer app exclusions only after the person explicitly picked a display.
    /// Rebuilding the filter retains that exact display and can only narrow it.
    private func choosePrivacyVeilApplications(for filter: SCContentFilter, source: ScreenShareSource) async throws -> [SCRunningApplication] {
        let preferences = PrivacyVeilPreferences.shared
        if #available(macOS 15.2, *), filter.style == .window,
           let bundleIdentifier = filter.includedWindows.first?.owningApplication?.bundleIdentifier,
           preferences.bundleIdentifiers.contains(bundleIdentifier) {
            throw Self.privacyVeilError("That window belongs to an app in your hidden-app list. Choose another window or remove the app from Privacy settings.")
        }
        if source == .window {
            if !preferences.bundleIdentifiers.isEmpty, #unavailable(macOS 15.2) {
                throw Self.privacyVeilError("Update to macOS 15.2 or later before using hidden-app settings with window shares.")
            }
            return []
        }
        guard (source == .display || source == .region), filter.style == .display,
              #available(macOS 15.2, *), let display = filter.includedDisplays.first else {
            if !preferences.bundleIdentifiers.isEmpty || preferences.hideNotificationBanners {
                throw Self.privacyVeilError("Display privacy filters require macOS 15.2 or later. Choose a window only if notification hiding is not required, or update macOS.")
            }
            return []
        }
        // The person has already selected an exact display in Apple's picker.
        // Listing all running apps now lets the filter cover windows opened or
        // moved onto that display later in the same share.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard content.displays.contains(where: { $0.displayID == display.displayID }) else {
            if !preferences.bundleIdentifiers.isEmpty || preferences.hideNotificationBanners {
                throw Self.privacyVeilError("macOS did not provide the selected display details needed to apply privacy filters. No screen was shared.")
            }
            return []
        }
        let apps = content.applications
            .filter { $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
        let availableIDs = Set(apps.map(\.bundleIdentifier))
        let missingIDs = preferences.bundleIdentifiers.subtracting(availableIDs)
        if !missingIDs.isEmpty {
            let names = preferences.applications.filter { missingIDs.contains($0.bundleIdentifier) }.map(\.name).sorted()
            throw Self.privacyVeilError("Open every app in your hidden-app list before sharing a display. PairDesk could not verify: \(names.joined(separator: ", ")).")
        }
        var excludedApplications = try await choosePrivacyVeilApplications(apps)
        if preferences.hideNotificationBanners {
            let availableIDs = Set(apps.map(\.bundleIdentifier))
            guard let notificationIDs = PrivacyVeilSelection.notificationBundleIdentifiersToExclude(
                hideNotifications: true, availableBundleIDs: availableIDs
            ), let notificationCenter = apps.first(where: { notificationIDs.contains($0.bundleIdentifier) }) else {
                throw Self.privacyVeilError("macOS did not expose Notification Center for capture filtering. No screen was shared; turn off notification hiding or try again after restarting Notification Center.")
            }
            if !excludedApplications.contains(where: { $0.bundleIdentifier == notificationCenter.bundleIdentifier }) {
                excludedApplications.append(notificationCenter)
            }
        }
        return excludedApplications
    }

    private static func privacyVeilError(_ message: String) -> NSError {
        NSError(domain: "PairDesk.PrivacyVeil", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func choosePrivacyVeilApplications(_ applications: [SCRunningApplication]) async throws -> [SCRunningApplication] {
        guard !applications.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "PairDesk · Privacy veil"
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            privacyContinuation = continuation
            privacyWindow = window
            let delegate = PrivacyVeilWindowDelegate { [weak self] in
                self?.finishPrivacyVeil(.failure(CocoaError(.userCancelled)))
            }
            privacyWindowDelegate = delegate
            window.delegate = delegate
            window.contentViewController = NSHostingController(rootView: PrivacyVeilApplicationPicker(
                applications: applications,
                initiallyExcludedBundleIDs: PrivacyVeilPreferences.shared.bundleIdentifiers,
                hideNotifications: PrivacyVeilPreferences.shared.hideNotificationBanners,
                onContinue: { [weak self, weak window] selected in
                    PrivacyVeilPreferences.shared.saveShareSelection(selected, visible: applications)
                    self?.finishPrivacyVeil(.success(selected))
                    window?.close()
                },
                onCancel: { [weak self, weak window] in
                    self?.finishPrivacyVeil(.failure(CocoaError(.userCancelled)))
                    window?.close()
                }
            ))
            NSApp.activate(ignoringOtherApps: true)
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func finishPrivacyVeil(_ result: Result<[SCRunningApplication], Error>) {
        let continuation = privacyContinuation
        privacyContinuation = nil
        privacyWindow = nil
        privacyWindowDelegate = nil
        continuation?.resume(with: result)
    }

    private func chooseDisplay(_ source: ScreenShareSource) async throws -> SCContentFilter {
        guard continuation == nil else {
            throw NSError(domain: "PairDesk.ScreenPicker", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Another screen selection is already in progress."])
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let picker = SCContentSharingPicker.shared
            var configuration = picker.defaultConfiguration
            configuration.allowedPickerModes = source == .window ? [.singleWindow] : [.singleDisplay]
            picker.defaultConfiguration = configuration
            picker.add(self)
            picker.isActive = true
            NSApp.activate(ignoringOtherApps: true)
            picker.present(using: source == .window ? .window : .display)
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        finish(.success(filter), picker: picker)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        finish(.failure(CocoaError(.userCancelled)), picker: picker)
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        finish(.failure(error), picker: .shared)
    }

    private func chooseCrop(for image: NSImage) async throws -> CGRect? {
        try await withCheckedThrowingContinuation { continuation in
            cropContinuation = continuation
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "PairDesk · Share a region"
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            // Resume before closing: closing also reaches windowWillClose, which
            // must only act when the person dismissed the window with its close button.
            window.contentViewController = NSHostingController(rootView: ScreenCropSelectionView(
                image: image,
                onCancel: { [weak self, weak window] in
                    self?.finishCrop(.failure(CocoaError(.userCancelled)))
                    window?.close()
                },
                onShare: { [weak self, weak window] crop in
                    self?.finishCrop(.success(crop))
                    window?.close()
                }
            ))
            window.delegate = self
            cropWindow = window
            NSApp.activate(ignoringOtherApps: true)
            window.center()
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func finishCrop(_ result: Result<CGRect?, Error>) {
        let continuation = cropContinuation
        cropContinuation = nil
        cropWindow = nil
        continuation?.resume(with: result)
    }

    /// The red close button is a cancel; without this the picker's caller
    /// would wait forever and the app would stay busy.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === cropWindow else { return }
        finishCrop(.failure(CocoaError(.userCancelled)))
    }

    private func finish(_ result: Result<SCContentFilter, Error>, picker: SCContentSharingPicker) {
        picker.remove(self)
        picker.isActive = false
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

private struct PrivacyVeilApplicationPicker: View {
    let applications: [SCRunningApplication]
    let initiallyExcludedBundleIDs: Set<String>
    let hideNotifications: Bool
    let onContinue: ([SCRunningApplication]) -> Void
    let onCancel: () -> Void
    @State private var excludedBundleIDs: Set<String>

    init(applications: [SCRunningApplication], initiallyExcludedBundleIDs: Set<String>, hideNotifications: Bool,
         onContinue: @escaping ([SCRunningApplication]) -> Void, onCancel: @escaping () -> Void) {
        self.applications = applications
        self.initiallyExcludedBundleIDs = initiallyExcludedBundleIDs
        self.hideNotifications = hideNotifications
        self.onContinue = onContinue
        self.onCancel = onCancel
        _excludedBundleIDs = State(initialValue: initiallyExcludedBundleIDs)
    }

    private var uniqueApplications: [SCRunningApplication] {
        var seen = Set<String>()
        return applications.filter { seen.insert($0.bundleIdentifier).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hide apps from this share")
                .font(.headline)
            Text("PairDesk will capture only the display you selected and exclude every window owned by the apps you choose. This is optional and can be changed by stopping and sharing again.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(hideNotifications
                 ? "Notification Center is also excluded from this display share. PairDesk cancels sharing if macOS cannot verify that filter."
                 : "macOS notification banners may appear. Turn on a Focus mode before sharing if you need to silence them.")
                .font(.caption).foregroundStyle(hideNotifications ? Theme.textMuted : Theme.attention)
                .fixedSize(horizontal: false, vertical: true)
            List(uniqueApplications, id: \.bundleIdentifier) { app in
                Toggle(app.applicationName, isOn: Binding(
                    get: { excludedBundleIDs.contains(app.bundleIdentifier) },
                    set: { enabled in
                        if enabled { excludedBundleIDs.insert(app.bundleIdentifier) }
                        else { excludedBundleIDs.remove(app.bundleIdentifier) }
                    }
                ))
            }
            HStack {
                Button("Cancel") { onCancel() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") { onContinue(PrivacyVeilSelection.resolve(excludedBundleIDs, from: applications)) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 440, height: 520)
        .background(Theme.surface)
        .preferredColorScheme(.dark)
    }
}

private final class PrivacyVeilWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

enum PrivacyVeilSelection {
    static func notificationBundleIdentifiersToExclude(hideNotifications: Bool,
                                                        availableBundleIDs: Set<String>) -> Set<String>? {
        guard hideNotifications else { return [] }
        let available = PrivacyVeilPreferences.notificationCenterBundleIdentifiers.intersection(availableBundleIDs)
        return available.isEmpty ? nil : available
    }

    static func resolve(_ bundleIDs: Set<String>, from applications: [SCRunningApplication]) -> [SCRunningApplication] {
        let selected = resolve(bundleIDs, availableBundleIDs: applications.map(\.bundleIdentifier))
        return applications.filter { selected.contains($0.bundleIdentifier) }
    }

    static func resolve(_ requested: Set<String>, availableBundleIDs: [String]) -> Set<String> {
        requested.intersection(availableBundleIDs)
    }
}
