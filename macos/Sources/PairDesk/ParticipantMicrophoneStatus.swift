import SwiftUI

/// A named, readable state rather than relying on color or speech activity.
struct ParticipantMicrophoneStatus: View {
    let participant: CallParticipant
    var audioQuality: AudioStreamQualityMetrics? = nil

    private var status: String {
        participant.isMicrophoneMuted ? "Muted" : (participant.isSpeaking ? "Speaking" : "Mic on")
    }

    private var accessibilityStatus: String {
        guard let quality = audioQuality?.diagnosticSummary else { return "\(participant.name), \(status)" }
        return "\(participant.name), \(status), \(quality)"
    }

    var body: some View {
        HStack(spacing: 5) {
            Label {
                Text(status).foregroundStyle(.primary)
            } icon: {
                Image(systemName: participant.isMicrophoneMuted ? "mic.slash.fill" :
                      (participant.isSpeaking ? "waveform" : "mic.fill"))
                    .foregroundStyle(participant.isMicrophoneMuted ? Theme.attention :
                                     (participant.isSpeaking ? Theme.online : Theme.textMuted))
            }
            if let warning = audioQuality?.warningSummary {
                Image(systemName: "waveform.badge.exclamationmark")
                    .foregroundStyle(Theme.attention)
                    .help("Elevated voice packet loss or jitter: \(warning)")
                    .accessibilityLabel("Voice quality warning: \(warning)")
            }
        }
        .font(.caption)
        .fixedSize()
        .help(audioQuality?.diagnosticSummary ?? "Recent voice quality measurements are not available yet.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityStatus)
    }
}
