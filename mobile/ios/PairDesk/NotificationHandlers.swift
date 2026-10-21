import CallKit
import AVFAudio
import Foundation
import PushKit
import SwiftUI
import UserNotifications

@MainActor final class PairDeskAppDelegate: NSObject, UIApplicationDelegate, PKPushRegistryDelegate, CXProviderDelegate, UNUserNotificationCenterDelegate {
    private static weak var current: PairDeskAppDelegate?
    private let callProvider: CXProvider
    private var pushRegistry: PKPushRegistry?
    private var isCheckingNotificationAuthorization = false
    private var invitationByCallUUID: [UUID: String] = [:]
    private var acceptedElsewhereFirstSeen: [UUID: Date] = [:]

    override init() {
        let configuration = CXProviderConfiguration(localizedName: "PairDesk")
        configuration.supportsVideo = false
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        callProvider = CXProvider(configuration: configuration)
        super.init()
        Self.current = self
        callProvider.setDelegate(self, queue: .main)
    }

    static func reconcileIncomingCalls(with invitations: [CallInvitation], activeRoomID: String?) {
        guard let current else { return }
        for (uuid, invitationID) in Array(current.invitationByCallUUID) {
            guard let invitation = invitations.first(where: { $0.id == invitationID }), invitation.status == "pending" else {
                let accepted = invitations.first(where: { $0.id == invitationID && $0.status == "accepted" })
                if let accepted {
                    if activeRoomID == accepted.room.id {
                        current.acceptedElsewhereFirstSeen.removeValue(forKey: uuid)
                        continue
                    }
                    if activeRoomID == nil {
                        let firstSeen = current.acceptedElsewhereFirstSeen[uuid] ?? Date()
                        current.acceptedElsewhereFirstSeen[uuid] = firstSeen
                        if Date().timeIntervalSince(firstSeen) < 5 { continue }
                    }
                }
                current.callProvider.reportCall(with: uuid, endedAt: Date(), reason: accepted == nil ? .unanswered : .answeredElsewhere)
                current.invitationByCallUUID.removeValue(forKey: uuid)
                current.acceptedElsewhereFirstSeen.removeValue(forKey: uuid)
                continue
            }
            current.acceptedElsewhereFirstSeen.removeValue(forKey: uuid)
        }
    }

    static func reportActiveCallsEnded() {
        guard let current else { return }
        for uuid in current.invitationByCallUUID.keys {
            current.callProvider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
        }
        current.invitationByCallUUID.removeAll()
        current.acceptedElsewhereFirstSeen.removeAll()
    }

    static func requestNotificationAuthorizationAfterAuthentication() {
        current?.requestNotificationAuthorization()
    }

    private func requestNotificationAuthorization() {
        guard !isCheckingNotificationAuthorization else { return }
        isCheckingNotificationAuthorization = true
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, _ in
                    DispatchQueue.main.async {
                        self?.isCheckingNotificationAuthorization = false
                        guard granted else { return }
                        self?.registerForRemoteNotificationsIfNeeded()
                    }
                }
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async {
                    self?.isCheckingNotificationAuthorization = false
                    self?.registerForRemoteNotificationsIfNeeded()
                }
            case .denied:
                DispatchQueue.main.async { self?.isCheckingNotificationAuthorization = false }
            @unknown default:
                DispatchQueue.main.async { self?.isCheckingNotificationAuthorization = false }
            }
        }
    }

    private func registerForRemoteNotificationsIfNeeded() {
        guard !UIApplication.shared.isRegisteredForRemoteNotifications else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        pushRegistry = registry
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { @MainActor in await AppModel.shared.receivedAlertPushToken(deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Alert delivery is optional for a foreground-only session; surface the
        // failure after sign-in, when the user can take action.
        Task { @MainActor in AppModel.shared.error = "Push notifications could not be enabled: \(error.localizedDescription)" }
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in await AppModel.shared.receivedVoIPToken(pushCredentials.token) }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        Task { @MainActor in await AppModel.shared.invalidatedVoIPToken() }
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        guard type == .voIP,
              let event = payload.dictionaryPayload["event"] as? String, event == "direct_call",
              let invitationID = payload.dictionaryPayload["callId"] as? String, !invitationID.isEmpty else {
            completion()
            return
        }
        let callUUID = invitationByCallUUID.first(where: { $0.value == invitationID })?.key ?? UUID()
        invitationByCallUUID[callUUID] = invitationID
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "PairDesk teammate")
        update.localizedCallerName = "PairDesk call"
        update.hasVideo = false
        callProvider.reportNewIncomingCall(with: callUUID, update: update) { [weak self] error in
            if error != nil { self?.invitationByCallUUID.removeValue(forKey: callUUID) }
            completion()
        }
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let invitationID = invitationByCallUUID[action.callUUID] else { action.fail(); return }
        Task { @MainActor in
            do {
                try await AppModel.shared.answerCallFromCallKit(invitationID: invitationID)
                action.fulfill()
            } catch {
                action.fail()
                provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
                invitationByCallUUID.removeValue(forKey: action.callUUID)
            }
        }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let invitationID = invitationByCallUUID[action.callUUID] else { action.fulfill(); return }
        Task { @MainActor in
            await AppModel.shared.endCallFromCallKit(invitationID: invitationID)
            invitationByCallUUID.removeValue(forKey: action.callUUID)
            action.fulfill()
        }
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            do { try await AppModel.shared.call.activateMicrophoneAfterCallKit() }
            catch { AppModel.shared.error = "Microphone could not be enabled: \(error.localizedDescription)" }
        }
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in await AppModel.shared.call.deactivateMicrophoneForCallKit() }
    }

    func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in await AppModel.shared.leaveCall() }
        invitationByCallUUID.removeAll()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in await AppModel.shared.refresh() }
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            await AppModel.shared.refresh()
            completionHandler()
        }
    }
}
