import UIKit
import Capacitor
import UserNotifications
import PushKit
import CallKit
import AVFoundation

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, CXProviderDelegate, UNUserNotificationCenterDelegate, PKPushRegistryDelegate {

    public static weak var shared: AppDelegate?

    var window: UIWindow?
    private var provider: CXProvider?
    private var callController: CXCallController?
    private var voipRegistry: PKPushRegistry?
    private var pendingCallPayloads: [String: [String: Any]] = [:]
    // Track UUIDs that were ended programmatically (not by user tapping decline)
    // so CXEndCallAction knows not to send reject to backend
    private var programmaticEndUUIDs: Set<String> = []

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        AppDelegate.shared = self

        // Force-link Capacitor CallKit Plugin so Xcode linker preserves it
        _ = CallKitPlugin.self

        // 1. Setup Push Notifications
        UNUserNotificationCenter.current().delegate = self

        // 2. Setup Native CallKit Provider for KakaoTalk-style Pill Call Banner
        let config = CXProviderConfiguration(localizedName: "Truples")
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        self.provider = CXProvider(configuration: config)
        self.provider?.setDelegate(self, queue: nil)
        self.callController = CXCallController()

        // 3. Initialize PushKit VoIP Registry
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.voipRegistry = registry

        print("[AppDelegate] KakaoTalk-style CallKit & PushKit initialized.")
        return true
    }

    // MARK: - CallKit Public API (Called by PushKit, APNs, and CallKitPlugin)

    public func reportIncomingCall(uuid: UUID, callerName: String, isVideo: Bool, payload: [String: Any]? = nil, completion: ((Error?) -> Void)? = nil) {
        // End any existing active CallKit calls before reporting new incoming call
        // This prevents iOS from auto-rejecting due to maximumCallGroups = 1
        for (existingUuidStr, _) in pendingCallPayloads {
            if existingUuidStr != uuid.uuidString, let existingUuid = UUID(uuidString: existingUuidStr) {
                print("[CallKit Native] Clearing stale call \(existingUuidStr) before new incoming call.")
                programmaticEndUUIDs.insert(existingUuidStr)
                let endAction = CXEndCallAction(call: existingUuid)
                callController?.request(CXTransaction(action: endAction)) { _ in }
            }
        }
        pendingCallPayloads.removeAll()

        if let p = payload {
            self.pendingCallPayloads[uuid.uuidString] = p
            // Persist payload to UserDefaults immediately so it survives app kill/restart
            if let jsonData = try? JSONSerialization.data(withJSONObject: p, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                UserDefaults.standard.set(jsonString, forKey: "pending_incoming_call_payload")
                UserDefaults.standard.set(uuid.uuidString, forKey: "pending_incoming_call_uuid")
                UserDefaults.standard.synchronize()
            }
        }

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = true // Force iOS to unlock & open app directly to foreground upon answer
        update.supportsDTMF = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        self.provider?.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                print("[CallKit Native] reportNewIncomingCall error: \(error.localizedDescription)")
            } else {
                print("[CallKit Native] Presented KakaoTalk-style CallKit banner for: \(callerName) (UUID: \(uuid.uuidString))")
            }
            completion?(error)
        }
    }

    public func endCall(uuid: UUID, completion: ((Error?) -> Void)? = nil) {
        // Mark as programmatic end so CXEndCallAction won't send reject to backend
        programmaticEndUUIDs.insert(uuid.uuidString)
        self.pendingCallPayloads.removeValue(forKey: uuid.uuidString)
        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)
        self.callController?.request(transaction) { error in
            if let error = error {
                print("[CallKit Native] Failed to end call: \(error.localizedDescription)")
            } else {
                print("[CallKit Native] Call successfully ended: \(uuid.uuidString)")
            }
            completion?(error)
        }
    }

    // MARK: - PKPushRegistryDelegate (Apple PushKit VoIP ➔ CallKit Pill Banner)

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        if type == .voIP {
            let dict = payload.dictionaryPayload
            print("[PushKit Native] Received VoIP Push Payload: \(dict)")

            let rawData: [AnyHashable: Any] = (dict["data"] as? [AnyHashable: Any]) ?? dict
            var stringPayload: [String: Any] = [:]
            for (k, v) in rawData {
                if let keyStr = k as? String {
                    stringPayload[keyStr] = v
                }
            }

            let nickname = (stringPayload["callerNickname"] as? String) ?? (dict["callerNickname"] as? String)
            let loginId = (stringPayload["callerLoginId"] as? String) ?? (dict["callerLoginId"] as? String)
            let callerName = (nickname != nil && !nickname!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? nickname! :
                             ((loginId != nil && !loginId!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? loginId! : "Caller")
            let uuidString = (stringPayload["chatRoomId"] as? String) ?? (stringPayload["callUuid"] as? String) ?? (dict["chatRoomId"] as? String) ?? UUID().uuidString
            let callType = (stringPayload["callType"] as? String) ?? (dict["callType"] as? String) ?? "audio"
            let isVideo = callType.lowercased() == "video"
            let type = (stringPayload["type"] as? String) ?? ""
            if type == "CALL_CANCEL" || type == "CALL_REJECT" || type == "CALL_HANGUP" || type == "CALL_TIMEOUT" || type == "CALL_CLOSED" {
                print("[PushKit Native] Received VoIP Call Cancel/Hangup signal for UUID: \(uuidString)")
                if let callUUID = UUID(uuidString: uuidString) {
                    self.endCall(uuid: callUUID) { _ in
                        completion()
                    }
                } else {
                    completion()
                }
                return
            }

            let callUUID = UUID(uuidString: uuidString) ?? UUID()
            self.reportIncomingCall(uuid: callUUID, callerName: callerName, isVideo: isVideo, payload: stringPayload) { _ in
                completion()
            }
        } else {
            completion()
        }
    }

    // MARK: - CXProviderDelegate (User taps [Decline] or [Answer] on CallKit Pill Banner)

    func providerDidReset(_ provider: CXProvider) {
        self.pendingCallPayloads.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuidStr = action.callUUID.uuidString

        // If this end was triggered programmatically (e.g. CALL_CANCEL from remote),
        // do NOT send reject to backend - just clean up CallKit state
        let isProgrammatic = programmaticEndUUIDs.contains(uuidStr)
        programmaticEndUUIDs.remove(uuidStr)

        if isProgrammatic {
            print("[CallKit Native] Programmatic endCall for UUID: \(uuidStr) - skipping backend reject.")
            self.pendingCallPayloads.removeValue(forKey: uuidStr)
            action.fulfill()
            return
        }

        print("[CallKit Native] User tapped DECLINE [x] on CallKit banner. UUID: \(uuidStr)")

        var backendCallUuid = uuidStr
        var matchedPayload: [String: Any]? = self.pendingCallPayloads[uuidStr]
        if matchedPayload == nil, let firstPayload = self.pendingCallPayloads.values.first {
            matchedPayload = firstPayload
        }
        // Fallback: restore payload from UserDefaults if memory was cleared
        if matchedPayload == nil,
           let saved = UserDefaults.standard.string(forKey: "pending_incoming_call_payload"),
           let data = saved.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            matchedPayload = obj
            print("[CallKit Native] Restored call payload from UserDefaults fallback (reject).")
        }
        // Clear persisted payload after consuming
        UserDefaults.standard.removeObject(forKey: "pending_incoming_call_payload")
        UserDefaults.standard.removeObject(forKey: "pending_incoming_call_uuid")
        UserDefaults.standard.synchronize()

        if let payload = matchedPayload {
            if let realUuid = (payload["callUuid"] as? String) ?? (payload["chatRoomId"] as? String), !realUuid.isEmpty {
                backendCallUuid = realUuid
            }
        }
        self.pendingCallPayloads.removeAll()
        UserDefaults.standard.removeObject(forKey: "pending_native_call_answer")
        UserDefaults.standard.synchronize()

        let callerLoginId = (matchedPayload?["callerLoginId"] as? String) ?? ""

        // Report reject to backend via ephemeral URLSession (PC terminates immediately)
        if let url = URL(string: "https://api.truples.com/api/call/reject") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = ["callUuid": backendCallUuid, "callerLoginId": callerLoginId]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
            let session = URLSession(configuration: .ephemeral)
            session.dataTask(with: request).resume()
        }

        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("[CallKit Native] didActivate AVAudioSession for WebRTC.")
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("[CallKit Native] didDeactivate AVAudioSession.")
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let uuidStr = action.callUUID.uuidString
        print("[CallKit Native] User tapped ANSWER [v] on CallKit banner. UUID: \(uuidStr)")

        var backendCallUuid = uuidStr
        var matchedPayload: [String: Any]? = self.pendingCallPayloads[uuidStr]
        if matchedPayload == nil, let firstPayload = self.pendingCallPayloads.values.first {
            matchedPayload = firstPayload
        }
        // Fallback: restore payload from UserDefaults if memory was cleared (app killed/restarted)
        if matchedPayload == nil,
           let saved = UserDefaults.standard.string(forKey: "pending_incoming_call_payload"),
           let data = saved.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            matchedPayload = obj
            print("[CallKit Native] Restored call payload from UserDefaults fallback.")
        }

        if let payload = matchedPayload {
            if let realUuid = (payload["callUuid"] as? String) ?? (payload["chatRoomId"] as? String), !realUuid.isEmpty {
                backendCallUuid = realUuid
            }
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                UserDefaults.standard.set(jsonString, forKey: "pending_native_call_answer")
                UserDefaults.standard.set(jsonString, forKey: "pending_push_call_intent")
                UserDefaults.standard.synchronize()
            }
        }
        // Clear persisted payload after consuming
        UserDefaults.standard.removeObject(forKey: "pending_incoming_call_payload")
        UserDefaults.standard.removeObject(forKey: "pending_incoming_call_uuid")
        UserDefaults.standard.synchronize()

        // Notify backend of accept
        if let url = URL(string: "https://api.truples.com/api/call/accept") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: String] = ["callUuid": backendCallUuid]
            if let targetUser = (matchedPayload?["targetLoginId"] as? String) ?? (matchedPayload?["receiverId"] as? String), !targetUser.isEmpty {
                body["receiverId"] = targetUser
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
            let session = URLSession(configuration: .ephemeral)
            session.dataTask(with: request).resume()
        }

        action.fulfill()

        // Force bring Truples app directly to foreground upon answering from lockscreen
        if let appUrl = URL(string: "truples://call/accept") {
            DispatchQueue.main.async {
                UIApplication.shared.open(appUrl, options: [:], completionHandler: nil)
            }
        }

        let callerName = (matchedPayload?["callerNickname"] as? String) ?? (matchedPayload?["callerName"] as? String) ?? (matchedPayload?["callerLoginId"] as? String) ?? "Caller"
        let callerLoginId = (matchedPayload?["callerLoginId"] as? String) ?? ""
        let callType = (matchedPayload?["callType"] as? String) ?? "audio"

        let notifyData: [String: Any] = [
            "callUuid": backendCallUuid,
            "callerLoginId": callerLoginId,
            "callerName": callerName,
            "callType": callType
        ]

        // Primary: notify JS via Capacitor plugin event (if sharedInstance is available)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            CallKitPlugin.sharedInstance?.notifyListeners("onCallAnswer", data: notifyData, retainUntilConsumed: true)
            print("[CallKit Native] Emitted onCallAnswer event to JS: \(backendCallUuid)")
        }

        // Fallback: programmatically dismiss CallKit active screen after 1s
        // This brings app to foreground → visibilitychange → checkStartupCallIntent() → handles the call
        // programmaticEndUUIDs prevents backend reject signal from being sent
        let answerUUID = action.callUUID
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.programmaticEndUUIDs.insert(answerUUID.uuidString)
            let endAction = CXEndCallAction(call: answerUUID)
            self.callController?.request(CXTransaction(action: endAction)) { error in
                if let error = error {
                    print("[CallKit Native] Failed to auto-dismiss CallKit screen: \(error)")
                } else {
                    print("[CallKit Native] CallKit screen dismissed - app moving to foreground")
                }
            }
        }
    }


    // MARK: - UNUserNotificationCenterDelegate (Push Notifications)

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let rawData: [AnyHashable: Any] = (userInfo["data"] as? [AnyHashable: Any]) ?? userInfo
        var stringPayload: [String: Any] = [:]
        for (k, v) in rawData {
            if let keyStr = k as? String {
                stringPayload[keyStr] = v
            }
        }
        let type = (stringPayload["type"] as? String) ?? ""
        if type.starts(with: "CALL_") || stringPayload["callType"] != nil {
            if let jsonData = try? JSONSerialization.data(withJSONObject: stringPayload, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                UserDefaults.standard.set(jsonString, forKey: "pending_push_call_intent")
                UserDefaults.standard.synchronize()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let userInfo = notification.request.content.userInfo
        let type = (userInfo["type"] as? String) ?? ""
        if type.starts(with: "CALL_") || userInfo["callType"] != nil {
            // For call events, suppress regular text banner so CallKit takes full precedence
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound, .badge])
    }

    // MARK: - APNs Device Token Registration

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)
        let hexToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[APNs Native] Registered APNs Device Token: \(hexToken)")
        UserDefaults.standard.set(hexToken, forKey: "truples_fcm_token")
        UserDefaults.standard.synchronize()
        self.sendApnsTokenToBackend(hexToken: hexToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
        print("[APNs Native] Failed to register APNs Device Token: \(error.localizedDescription)")
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any], fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        NotificationCenter.default.post(name: Notification.Name("didReceiveRemoteNotification"), object: completionHandler, userInfo: userInfo)

        let rawData: [AnyHashable: Any] = (userInfo["data"] as? [AnyHashable: Any]) ?? userInfo
        var stringPayload: [String: Any] = [:]
        for (k, v) in rawData {
            if let keyStr = k as? String {
                stringPayload[keyStr] = v
            }
        }
        let type = (stringPayload["type"] as? String) ?? ""
        if type == "CALL_INITIATE" {
            let nickname = (stringPayload["callerNickname"] as? String)
            let loginId = (stringPayload["callerLoginId"] as? String)
            let callerName = (nickname != nil && !nickname!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? nickname! :
                             ((loginId != nil && !loginId!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? loginId! : "Caller")
            let uuidString = (stringPayload["chatRoomId"] as? String) ?? (stringPayload["callUuid"] as? String) ?? UUID().uuidString
            let callType = (stringPayload["callType"] as? String) ?? "audio"
            let isVideo = callType.lowercased() == "video"
            let callUUID = UUID(uuidString: uuidString) ?? UUID()

            self.reportIncomingCall(uuid: callUUID, callerName: callerName, isVideo: isVideo, payload: stringPayload)
        } else if type == "CALL_CANCEL" {
            let uuidString = (stringPayload["chatRoomId"] as? String) ?? (stringPayload["callUuid"] as? String) ?? ""
            if let callUUID = UUID(uuidString: uuidString) {
                self.endCall(uuid: callUUID)
            }
        }

        completionHandler(.newData)
    }

    public func sendApnsTokenToBackend(hexToken: String, customLoginId: String? = nil) {
        guard let url = URL(string: "https://api.truples.com/api/notifications/token") else { return }

        var deviceId = UserDefaults.standard.string(forKey: "truples_device_id") ?? ""
        if deviceId.isEmpty {
            deviceId = "device-ios-" + UUID().uuidString.prefix(8).lowercased()
            UserDefaults.standard.set(deviceId, forKey: "truples_device_id")
        }
        let loginId = customLoginId ?? UserDefaults.standard.string(forKey: "truples_last_login_id") ?? ""
        guard !loginId.isEmpty else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "loginId": loginId,
            "token": hexToken,
            "deviceId": deviceId
        ]

        if let data = try? JSONSerialization.data(withJSONObject: body, options: []) {
            request.httpBody = data
            URLSession.shared.dataTask(with: request).resume()
        }
    }

    // MARK: - PKPushRegistryDelegate (VoIP Tokens)

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        if type == .voIP {
            let hexToken = credentials.token.map { String(format: "%02.2hhx", $0) }.joined()
            print("[PushKit Native] Received Apple VoIP Device Token: \(hexToken)")
            // Always persist the token locally for later use
            UserDefaults.standard.set(hexToken, forKey: "truples_apple_voip_token")
            UserDefaults.standard.set(hexToken, forKey: "truples_apple_voip_token_pending")
            UserDefaults.standard.synchronize()
            CallKitPlugin.sharedVoipToken = hexToken
            CallKitPlugin.sharedInstance?.setVoipToken(hexToken)
            // Send to backend (will retry after login if loginId not yet available)
            self.sendVoipTokenToBackend(hexToken: hexToken)
        }
    }

    public func sendVoipTokenToBackend(hexToken: String, customLoginId: String? = nil) {
        guard let url = URL(string: "https://api.truples.com/api/notifications/token") else { return }

        var deviceId = UserDefaults.standard.string(forKey: "truples_device_id") ?? ""
        if deviceId.isEmpty {
            deviceId = "device-ios-" + UUID().uuidString.prefix(8).lowercased()
            UserDefaults.standard.set(deviceId, forKey: "truples_device_id")
        }
        let voipDeviceId = deviceId.hasSuffix("-voip") ? deviceId : (deviceId + "-voip")
        let loginId = customLoginId ?? UserDefaults.standard.string(forKey: "truples_last_login_id") ?? ""

        // If loginId is not available yet (fresh install), save as pending and return.
        // The JS side will pick up 'truples_apple_voip_token_pending' after login and re-register.
        guard !loginId.isEmpty else {
            print("[PushKit Native] loginId not available yet. VoIP token saved as pending for post-login registration.")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "loginId": loginId,
            "token": hexToken,
            "deviceId": voipDeviceId
        ]

        if let data = try? JSONSerialization.data(withJSONObject: body, options: []) {
            request.httpBody = data
            URLSession.shared.dataTask(with: request) { _, _, error in
                if let error = error {
                    print("[PushKit Native] Failed to register VoIP token: \(error.localizedDescription)")
                } else {
                    print("[PushKit Native] VoIP token registered to backend for loginId=\(loginId)")
                }
            }.resume()
        }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("[PushKit Native] Apple VoIP Device Token invalidated.")
    }

    // MARK: - Capacitor URL Handling & Deep Linking

    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        return ApplicationDelegateProxy.shared.application(app, open: url, options: options)
    }

    func application(_ application: UIApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
        return ApplicationDelegateProxy.shared.application(application, continue: userActivity, restorationHandler: restorationHandler)
    }
}
