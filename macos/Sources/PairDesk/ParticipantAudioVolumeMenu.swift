import SwiftUI

struct ParticipantAudioVolumeMenu: View {
    let participantIdentity: String
    let participantName: String
    @ObservedObject var rtc: RTCService

    init(participant: CallParticipant, rtc: RTCService) {
        participantIdentity = participant.identity
        participantName = participant.name
        self.rtc = rtc
    }

    init(identity: String, name: String, rtc: RTCService) {
        participantIdentity = identity
        participantName = name
        self.rtc = rtc
    }

    private var volume: Double { rtc.participantAudioVolume(for: participantIdentity) }

    var body: some View {
        Menu {
            Section("\(participantName)'s volume · this Mac") {
                ForEach(ParticipantAudioVolumePreset.allCases) { preset in
                    Button {
                        rtc.setParticipantAudioVolume(preset.rawValue, for: participantIdentity)
                    } label: {
                        if abs(volume - preset.rawValue) < 0.001 {
                            Label(preset.title, systemImage: "checkmark")
                        } else {
                            Text(preset.title)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: ParticipantAudioVolume.symbol(for: volume))
                .foregroundStyle(volume == 0 ? Theme.attention : Theme.textMuted)
                .frame(width: 18, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Adjust \(participantName)'s volume on this Mac")
        .accessibilityLabel("Adjust \(participantName)'s volume")
    }
}
