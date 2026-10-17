import AppKit
import AVFoundation
import ApplicationServices
import Security
import SwiftUI

enum AppCopyLocation: Equatable {
    case applications
    case diskImage
    case other(String)

    static func classify(bundleURL: URL, homeDirectory: URL) -> AppCopyLocation {
        let bundlePath = bundleURL.standardizedFileURL.path
        if bundlePath.hasPrefix("/Volumes/") { return .diskImage }
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
        if roots.contains(where: { bundlePath.hasPrefix($0.standardizedFileURL.path + "/") }) {
            return .applications
        }
        return .other(bundlePath)
    }

    var guidance: String {
        switch self {
        case .applications:
            return "PairDesk is running from an Applications folder."
        case .diskImage:
            return "PairDesk is running from a mounted disk image. Drag it to Applications, eject the image, and open the Applications copy."
        case .other(let path):
            return "This copy is outside Applications: \(path). For normal team use, keep one copy in Applications and open that copy."
        }
    }
}

@MainActor
final class PermissionManager: ObservableObject {
    static let shared = PermissionManager()
    private var requestedAccessibility = false
    @Published private(set) var microphone = false
    @Published private(set) var camera = false
    @Published private(set) var accessibility = false
    init() { refresh() }
    func refresh() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        accessibility = AXIsProcessTrusted()
    }
    func requestMicrophone() async {
        refresh()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else { open("Privacy_Microphone") }
        refresh()
    }
    func requestCamera() async {
        refresh()
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        } else { open("Privacy_Camera") }
        refresh()
    }
    func requestAccessibility() {
        refresh()
        if !accessibility && !requestedAccessibility {
            requestedAccessibility = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        open("Privacy_Accessibility")
        refresh()
    }
    func open(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app")) }
    }
}

struct PermissionsView: View {
    @ObservedObject private var permissions = PermissionManager.shared
    @Environment(\.dismiss) private var dismiss
    private var appCopyLocation: AppCopyLocation {
        AppCopyLocation.classify(bundleURL: Bundle.main.bundleURL, homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }
    private var signingSummary: String {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return "Signature status unavailable" }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return "Signature status unavailable" }
        let identifier = values[kSecCodeInfoIdentifier as String] as? String ?? Bundle.main.bundleIdentifier ?? "unknown"
        if let team = values[kSecCodeInfoTeamIdentifier as String] as? String {
            return "\(identifier) · Apple team \(team)"
        }
        return "\(identifier) · no Apple Developer team"
    }
    var body: some View {
        // One row per capability; the long troubleshooting copy is collapsed so
        // the fixed-size window fits on a 13-inch display.
        VStack(alignment: .leading, spacing: 20) {
            Text("Privacy and access").font(.title2.bold())
            Text("PairDesk asks for access only when you use the related feature. You can call and view a teammate's screen without enabling remote control.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            row("Microphone", detail: "Needed to talk. You can still join a call and listen without it.", ready: permissions.microphone) { if permissions.microphone { permissions.open("Privacy_Microphone") } else { Task { await permissions.requestMicrophone() } } }
            row("Camera", detail: "Optional. Turn it on during a call to share live video. Camera stays off until you choose to enable it.", ready: permissions.camera) { if permissions.camera { permissions.open("Privacy_Camera") } else { Task { await permissions.requestCamera() } } }
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "display").foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Screen sharing").bold()
                    Text("Choose a display or window in Apple's picker each time. No separate Screen Recording setting is needed.").font(.caption).foregroundStyle(.secondary)
                }
            }
            row("Remote control", detail: "Optional, and needed only on the Mac being shared. Lets a teammate use your mouse and keyboard. Stop it from the menu bar or press Control–Option–Escape at any time.", ready: permissions.accessibility) { if permissions.accessibility { permissions.open("Privacy_Accessibility") } else { permissions.requestAccessibility() } }
            DisclosureGroup("Troubleshooting") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("If you enable Accessibility while sharing a display, return to PairDesk; control becomes available automatically.")
                    Text("Settings labels and placement vary by macOS version. If the Accessibility page does not open directly, search System Settings for ‘Accessibility’ and find the list of apps allowed to control your Mac.")
                    Text("If System Settings shows PairDesk as enabled but input still does not work, check that the enabled entry matches the copy in Applications. Remove any stale PairDesk entry and add the Applications copy, then quit and reopen PairDesk.")
                    Text("Ad-hoc builds change their signing identity with every update and may need fresh approval. Builds made with the same local signing certificate can keep a stable identity, but normal distribution still requires Developer ID signing and notarization.")
                    Text(appCopyLocation.guidance).textSelection(.enabled)
                    Text("App signature: \(signingSummary)").font(.caption.monospaced()).textSelection(.enabled)
                }.font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }.font(.callout)
            HStack { Button("Check again") { permissions.refresh() }; Spacer(); Button("Done") { PermissionWindowController.shared.close(); dismiss() } }
        }.padding(26).frame(width: 490)
        .task {
            while !Task.isCancelled {
                permissions.refresh()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissions.refresh() }
    }
    private func row(_ title: String, detail: String, ready: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle").foregroundStyle(ready ? Color.green : Color.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) { Text(title).bold(); Text(detail).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(ready ? "Settings" : "Allow", action: action)
        }
    }
}

// Retain a standalone window so permission setup is reachable from an accessory
// menu-bar app even when SwiftUI's menu popover is closing.
@MainActor
final class PermissionWindowController {
    static let shared = PermissionWindowController()
    private var window: NSWindow?
    func close() { window?.orderOut(nil) }
    func show() {
        PermissionManager.shared.refresh()
        if window == nil {
            let controller = NSHostingController(rootView: PermissionsView())
            // Track the view's size so expanding Troubleshooting grows the window.
            controller.sizingOptions = [.preferredContentSize]
            let created = NSWindow(contentViewController: controller)
            created.title = "PairDesk permissions"
            created.styleMask = [.titled, .closable]
            created.isReleasedWhenClosed = false
            created.center()
            window = created
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
