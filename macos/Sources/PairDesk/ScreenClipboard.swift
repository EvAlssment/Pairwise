import AppKit

enum ScreenClipboardError: Error, Equatable, LocalizedError {
    case privateText, unavailable, copyTimedOut, inputFailed

    var errorDescription: String? {
        switch self {
        case .privateText: "Private clipboard content wasn't shared."
        case .unavailable: "The text clipboard couldn't be updated."
        case .copyTimedOut: "The remote app didn't copy text. Select text and try again."
        case .inputFailed: "Copy or paste failed. Check Accessibility access on the sharing Mac."
        }
    }
}

/// Pasteboard and native shortcut boundary. Tests use isolated pasteboards and
/// a synthetic destination app; production posts marked, balanced CGEvents.
@MainActor
final class ScreenClipboard {
    let pasteboard: NSPasteboard
    var postShortcut: (UInt16) -> Bool
    private var pasteEpoch: String?
    private var assembler = ClipboardTransferAssembler()
    private var replay = ClipboardTransferReplayWindow()

    init(pasteboard: NSPasteboard = .general, postShortcut: @escaping (UInt16) -> Bool = { code in
        RemoteInputInjector.clipboardShortcut(code: code)
    }) {
        self.pasteboard = pasteboard
        self.postShortcut = postShortcut
    }

    nonisolated static func shortcut(code: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let relevant = modifiers.intersection([.command, .control, .option, .shift, .function])
        return relevant == .command && [UInt16(8), 9].contains(code)
    }

    func readText(includePrivate: Bool = false) throws -> String {
        let types = ((pasteboard.pasteboardItems ?? []).flatMap(\.types) + (pasteboard.types ?? [])).map(\.rawValue)
        guard includePrivate || ClipboardSyncPolicy.mayShare(pasteboardTypes: types) else { throw ScreenClipboardError.privateText }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { throw ClipboardTransferError.emptyText }
        guard text.utf8.count <= ClipboardTransferMessage.maximumTextBytes else { throw ClipboardTransferError.textTooLarge }
        return text
    }

    func writeText(_ text: String) throws {
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else { throw ScreenClipboardError.unavailable }
    }

    /// A copy must observe a *new* pasteboard write. Returning the old value on
    /// a slow/unsupported app would disclose unrelated clipboard content.
    func copyText(ifAllowed: () -> Bool) async throws -> String {
        guard ifAllowed(), !Task.isCancelled else { throw CancellationError() }
        let previous = pasteboard.changeCount
        guard postShortcut(8) else { throw ScreenClipboardError.inputFailed }
        for _ in 0..<40 {
            guard ifAllowed(), !Task.isCancelled else { throw CancellationError() }
            if pasteboard.changeCount != previous { return try readText(includePrivate: true) }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ScreenClipboardError.copyTimedOut
    }

    /// Called only after RTC's authenticated lease gate accepts each part.
    /// The paste shortcut is posted once, after the entire clip is available.
    func paste(_ part: ClipboardTransferMessage, from sender: String, epoch: String) throws -> String? {
        if pasteEpoch != epoch { assembler = ClipboardTransferAssembler(); pasteEpoch = epoch }
        guard let message = assembler.add(part, from: sender), replay.insert(message.id) else { return nil }
        try writeText(message.text)
        guard postShortcut(9) else { throw ScreenClipboardError.inputFailed }
        return message.text
    }

    func reset() {
        assembler = ClipboardTransferAssembler()
        pasteEpoch = nil
    }
}
