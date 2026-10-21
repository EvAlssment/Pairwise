import AppKit
import SwiftUI

struct ClipboardPeer: Identifiable, Equatable {
    let identity: String
    let name: String
    var id: String { identity }
}

/// Embeddable in-call clipboard UI. Reading the local pasteboard only happens
/// after the sender presses Send; writing it only happens after the receiver
/// presses Paste on this Mac.
struct ClipboardTransferView: View {
    let peers: [ClipboardPeer]
    let incoming: (senderName: String, message: ClipboardTransferMessage)?
    let onSend: (String, String) async throws -> Void
    let onPaste: () -> Void
    let onDismiss: () -> Void
    let clipboardSyncEnabled: Bool
    let clipboardSyncNotice: String?
    let onToggleSync: (Bool) -> Void

    @State private var selectedPeerIdentity = ""
    @State private var status: String?
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 8) {
                Label("Copy here, paste there", systemImage: "doc.on.clipboard")
                    .font(.headline)
                Text("For hands-free copy and paste, turn this on for everyone in the call. Copy text on one Mac, then press ⌘V on another. It turns off when the call ends.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Sync text clipboard for this call", isOn: Binding(
                    get: { clipboardSyncEnabled },
                    set: onToggleSync
                ))
                .font(.callout.weight(.medium))
                Text("Only plain text is shared. Images and files stay on this Mac. If a teammate hasn't enabled sync, they get a preview and choose when to paste.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            if !peers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Send text once", systemImage: "paperplane")
                        .font(.headline)
                    Text("Send the text currently copied on your Mac to one teammate. They can review it before pasting.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Picker("Send to", selection: $selectedPeerIdentity) {
                            ForEach(peers) { peer in Text(peer.name).tag(peer.identity) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)

                        Button {
                            sendClipboard()
                        } label: {
                            Label("Send copied text", systemImage: "paperplane.fill")
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(selectedPeerIdentity.isEmpty || sending)
                    }
                }
            } else {
                Text("Start a call with a teammate to share text.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let incoming {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Text from \(incoming.senderName)", systemImage: "doc.text")
                        .font(.callout.weight(.semibold))
                    Text(incoming.message.text)
                        .font(.caption)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    HStack {
                        Button("Paste on this Mac", action: onPaste).buttonStyle(PrimaryButtonStyle())
                        Button("Dismiss", action: onDismiss).buttonStyle(QuietButtonStyle(compact: true))
                    }
                }
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }

            if let clipboardSyncNotice { Text(clipboardSyncNotice).font(.caption).foregroundStyle(.secondary) }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: peers) { _, newPeers in
            if !newPeers.contains(where: { $0.identity == selectedPeerIdentity }) {
                selectedPeerIdentity = newPeers.first?.identity ?? ""
            }
        }
        .onAppear {
            if selectedPeerIdentity.isEmpty { selectedPeerIdentity = peers.first?.identity ?? "" }
        }
    }

    private func sendClipboard() {
        // This explicit button is the only path that reads the system pasteboard.
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            status = "There is no text in the clipboard."
            return
        }
        guard text.utf8.count <= ClipboardTransferMessage.maximumTextBytes else {
            status = "Text is larger than the 64 KB sharing limit."
            return
        }
        guard !selectedPeerIdentity.isEmpty else { return }
        let peer = selectedPeerIdentity
        let peerName = peers.first(where: { $0.identity == peer })?.name ?? "teammate"
        sending = true
        status = "Sending…"
        Task {
            // The status reports the outcome, not the attempt: a clip that
            // exceeds the transport's packet limits fails here, visibly.
            do { try await onSend(text, peer); status = "Sent text to \(peerName)." }
            catch { status = error.localizedDescription }
            sending = false
        }
    }

}
