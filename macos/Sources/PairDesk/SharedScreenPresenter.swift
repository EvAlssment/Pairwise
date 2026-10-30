import Combine
import Foundation

/// The viewer follows remote screen-share sessions, while the call remains in
/// the menu bar. Repeated updates must not reopen a manually dismissed viewer.
@MainActor
final class SharedScreenPresenter {
    private let store: AppStore
    private let windows: AppWindows
    private var subscriptions = Set<AnyCancellable>()
    private struct Session: Equatable {
        let roomID: String
        let sharer: String
        let track: ObjectIdentifier
    }
    private var shownSession: Session?

    init(store: AppStore, windows: AppWindows? = nil) {
        self.store = store
        self.windows = windows ?? .shared
        let rtc = store.rtc
        Publishers.Merge4(rtc.$activeSharerIdentity.map { _ in () }, rtc.$screenTrack.map { _ in () },
                          rtc.$isSharing.map { _ in () }, rtc.$connected.map { _ in () })
            .merge(with: store.$activeRoom.map { _ in () })
            .sink { [weak self] in
                // @Published emits before storage changes; read the settled state.
                Task { @MainActor [weak self] in self?.sync() }
            }.store(in: &subscriptions)
        sync()
    }

    private func sync() {
        let rtc = store.rtc
        guard let roomID = store.activeRoom?.id, rtc.connected, !rtc.isSharing,
              let sharer = rtc.activeSharerIdentity, let track = rtc.screenTrack else {
            shownSession = nil
            windows.closeSharedScreen()
            return
        }
        let session = Session(roomID: roomID, sharer: sharer, track: ObjectIdentifier(track))
        guard session != shownSession else { return }
        shownSession = session
        windows.showSharedScreen(store: store)
    }
}
