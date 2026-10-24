import AppKit
import Foundation
import LiveKit
import SwiftUI

enum SupportDiagnostics {
    @MainActor
    static func report(store: AppStore, rtc: RTCService, apiBuildCommit: String? = nil, now: Date = .now) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info["CFBundleVersion"] as? String ?? "unknown"
        let endpoint = safeAPIHost(URLComponents(string: store.serverAddress)?.host)
        let callState = rtc.isReconnecting ? "reconnecting" : (rtc.connected ? "connected" : "not connected")
        let route = screenRouteSummary(rtc.screenTrack?.statistics)
        let errorCategory = safeErrorCategory(store.error ?? rtc.error)

        return """
        PairDesk support diagnostics
        Captured: \(ISO8601DateFormatter().string(from: now))
        App: \(appVersion) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        API host: \(endpoint)
        API protocol: v1
        API build commit: \(safeBuildIdentifier(apiBuildCommit))
        Call: \(callState)
        Screen sharing: \(rtc.isSharing ? "yes" : (rtc.screenTrack == nil ? "no" : "viewing"))
        Microphone: \(rtc.isMicrophoneEnabled ? "on" : "off")
        Screen RTT: \(rtc.screenNetworkQuality.label)
        Received screen stream: \(rtc.screenStreamMetrics.summary)
        Screen time to first rendered frame: \(rtc.screenTimeToFirstFrameMilliseconds.map { "\($0) ms" } ?? "unavailable")
        Screen interruptions: \(rtc.screenShareContinuityMetrics.summary)
        Selected ICE route: \(route)
        Current error category: \(errorCategory)

        Privacy: this report contains no account names, email addresses, passwords, tokens, transcript text, audio, screen images, or IP addresses. Review it before sharing.
        """
    }

    static func safeBuildIdentifier(_ value: String?) -> String {
        guard let value else { return "unavailable" }
        if value == "unknown" { return value }
        guard (7...40).contains(value.count),
              value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else {
            return "unavailable"
        }
        return value
    }

    static func screenRouteSummary(_ statistics: TrackStatistics?) -> String {
        guard let statistics,
              let pair = statistics.iceCandidatePair.first(where: { $0.state == .succeeded && $0.nominated != false }) else {
            return "unavailable"
        }

        // Candidate addresses and relay URLs can reveal private network details.
        // Include only candidate type and transport when the SDK can associate
        // the exposed candidates with the selected pair.
        let local = statistics.localIceCandidate.flatMap { $0.id == pair.localCandidateId ? $0 : nil }
        let remote = statistics.remoteIceCandidate.flatMap { $0.id == pair.remoteCandidateId ? $0 : nil }
        guard let local, let remote else { return "selected route active; candidate details unavailable" }
        return "\(candidateDescription(local)) → \(candidateDescription(remote))"
    }

    static func safeErrorCategory(_ message: String?) -> String {
        guard let message, !message.isEmpty else { return "none" }
        let value = message.lowercased()
        if value.contains("accessibility") || value.contains("permission") { return "permission" }
        if value.contains("network") || value.contains("connection") || value.contains("transport") { return "network" }
        if value.contains("microphone") || value.contains("audio") { return "audio" }
        if value.contains("screen") || value.contains("share") { return "screen sharing" }
        if value.contains("call") || value.contains("room") { return "call" }
        return "other (details omitted)"
    }

    static func safeAPIHost(_ host: String?) -> String {
        guard let host else { return "unavailable" }
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !normalized.isEmpty else { return "unavailable" }

        // Some wildcard DNS providers encode the address into the hostname,
        // for example 136-80-31-73.sslip.io. Treat these as IPs even though
        // URLComponents reports them as ordinary DNS names.
        let addressEncodingSuffixes = ["sslip.io", "nip.io", "traefik.me", "xip.io"]
        if addressEncodingSuffixes.contains(where: {
            normalized == $0 || normalized.hasSuffix("." + $0)
        }) {
            return "IP address omitted"
        }

        // Redact literal IPv6 and any hostname containing four consecutive
        // IPv4 octets separated by dots or hyphens. This also covers common
        // wildcard-DNS encodings without depending on a particular provider.
        if normalized.contains(":") { return "IP address omitted" }
        let addressParts = normalized.split { $0 == "." || $0 == "-" }
        if addressParts.count >= 4 {
            for start in 0...(addressParts.count - 4) {
                if addressParts[start..<(start + 4)].allSatisfy({ UInt8($0) != nil }) {
                    return "IP address omitted"
                }
            }
        }
        return normalized
    }

    private static func candidateDescription(_ candidate: IceCandidateStatistics) -> String {
        let kind = candidate.candidateType.map { String(describing: $0) } ?? "candidate"
        let transport = candidate.protocol ?? "transport unknown"
        return "\(kind)/\(transport)"
    }
}

struct SupportDiagnosticsView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var rtc: RTCService
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var apiBuildCommit: String?

    private var report: String { SupportDiagnostics.report(store: store, rtc: rtc, apiBuildCommit: apiBuildCommit) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Support diagnostics").font(.title2.bold())
            Text("Review this report before sharing. It omits account identity, credentials, audio, transcripts, and screen content.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextEditor(text: .constant(report))
                .font(.system(.caption, design: .monospaced))
                .frame(minHeight: 250)
                .textSelection(.enabled)
                .accessibilityLabel("Redacted support diagnostics")
            HStack {
                Button("Close") { dismiss() }
                Spacer()
                if copied { Text("Copied").font(.caption).foregroundStyle(.secondary) }
                Button("Copy report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                    copied = true
                }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .frame(width: 570, height: 430)
        .task {
            do {
                let client = try APIClient(server: store.serverAddress)
                let metadata: ServerVersionResponse = try await client.request("version")
                apiBuildCommit = metadata.buildCommit
            } catch {
                apiBuildCommit = nil
            }
        }
    }
}

private struct ServerVersionResponse: Decodable {
    let buildCommit: String
}
