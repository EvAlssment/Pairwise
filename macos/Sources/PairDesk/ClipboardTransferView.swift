import AppKit
import SwiftUI

struct ClipboardPeer: Identifiable, Equatable {
    let identity: String
    let name: String
    var id: String { identity }
}

/// Call-level sync consent and explicit, reviewable one-off clipboard offers.
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
            VStack(alignment: .leading, spacing: 10) {
                Label("Copy & paste between Macs", systemImage: "doc.on.clipboard")
                    .font(.headline)
                HStack(spacing: 8) {
                    Text("⌘C  Copy here")
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Text("⌘V  Paste there")
                }
                .font(.callout.weight(.medium))
                Toggle("Sync clipboard text for this call", isOn: Binding(
                    get: { clipboardSyncEnabled },
                    set: onToggleSync
                ))
                .font(.callout.weight(.medium))
                Text(clipboardSyncEnabled
                     ? "Turn this on on both Macs for automatic plain-text sync. It turns off when the call ends."
                     : "For automatic sync, both Macs must opt in. Otherwise, send a clip once and let the other person approve copying it.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("On a shared display: select text and press ⌘C to copy here. Copy locally, click the remote app, then press ⌘V to paste there.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

            if !peers.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Send text once", systemImage: "paperplane")
                        .font(.callout.weight(.medium))
                    HStack(spacing: 8) {
                        Picker("Send to", selection: $selectedPeerIdentity) {
                            ForEach(peers) { peer in Text(peer.name).tag(peer.identity) }
                        }
                        .frame(maxWidth: .infinity)

                        Button(sending ? "Sending…" : "Send") { sendClipboard() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(selectedPeerIdentity.isEmpty || sending)
                    }
                    Text("They approve copying it to their clipboard, then press ⌘V.")
                        .font(.caption).foregroundStyle(.secondary)
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
                        Button("Copy to clipboard", action: onPaste).buttonStyle(PrimaryButtonStyle())
                        Button("Dismiss", action: onDismiss).buttonStyle(QuietButtonStyle(compact: true))
                    }
                    Text("Then press ⌘V in the app where you want the text.")
                        .font(.caption).foregroundStyle(.secondary)
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
        // One-off offers read only when the sender presses Send.
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
            do { try await onSend(text, peer); status = "Sent to \(peerName). They can approve it in the call." }
            catch { status = error.localizedDescription }
            sending = false
        }
    }

}
