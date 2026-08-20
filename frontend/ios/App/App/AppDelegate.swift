import UIKit
import Capacitor
import UserNotifications
import PushKit
import CallKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate, CXProviderDelegate, UNUserNotificationCenterDelegate {

    var window: UIWindow?
    private var provider: CXProvider?
    private var callController: CXCallController?
    private var voipRegistry: PKPushRegistry?
    private var pendingCallPayloads: [String: [String: Any]] = [:]

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // Force-link CapacitorCallKitPlugin so Xcode linker never strips it from the binary
        _ = CallKitPlugin.self
        
        // Set UserNotificationCenter delegate to handle push banner taps
        UNUserNotificationCenter.current().delegate = self

        // Setup Native CallKit CXProvider for Background Incoming Calls
        let config = CXProviderConfiguration(localizedName: "Truples")
        config.supportsVideo = true
        config.maximumCallGroups = 1
        config.maximumCallsPerCallGroup = 1
        config.supportedHandleTypes = [.generic]
        config.includesCallsInRecents = true
        self.provider = CXProvider(configuration: config)
        self.provider?.setDelegate(self, queue: nil)
        self.callController = CXCallController()

        // Setup PushKit VoIP Registry immediately at startup
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.voipRegistry = registry

        return true
    }

    // MARK: - UNUserNotificationCenterDelegate
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        print("[APNs Native] User tapped push notification: \(userInfo)")

        // Extract call data if present
        let rawData: [AnyHashable: Any] = (userInfo["data"] as? [AnyHashable: Any]) ?? userInfo
        var stringPayload: [String: Any] = [:]
        for (k, v) in rawData {
            if let keyStr = k as? String {
                stringPayload[keyStr] = v
            }
        }

        let type = (stringPayload["type"] as? String) ?? ""
        let isCallPush = type.starts(with: "CALL_") || stringPayload["callType"] != nil

        if isCallPush {
            if let jsonData = try? JSONSerialization.data(withJSONObject: stringPayload, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                UserDefaults.standard.set(jsonString, forKey: "pending_push_call_intent")
                UserDefaults.standard.synchronize()
                print("[APNs Native] Cached pending_push_call_intent for webview pickup.")
            }
        }

        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .badge, .sound])
        } else {
            completionHandler([.alert, .badge, .sound])
        }
    }

    // MARK: - APNs Remote Notifications Handling
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        NotificationCenter.default.post(name: .capacitorDidRegisterForRemoteNotifications, object: deviceToken)

        let hexToken = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        print("[APNs Native] Received APNs device token: \(hexToken)")
        UserDefaults.standard.set(hexToken, forKey: "truples_fcm_token")
        UserDefaults.standard.synchronize()

        // Send APNs token directly to Backend via Native Swift URLSession
        self.sendApnsTokenToBackend(hexToken: hexToken)

        // Also sync VoIP token if already cached in UserDefaults
        if let voipToken = UserDefaults.standard.string(forKey: "truples_apple_voip_token"), !voipToken.isEmpty {
            self.sendVoipTokenToBackend(hexToken: voipToken)
        }
    }

    func applicationDidBecomeActive(_ application: UIApplication) {
        if let apnsToken = UserDefaults.standard.string(forKey: "truples_fcm_token"), !apnsToken.isEmpty {
            self.sendApnsTokenToBackend(hexToken: apnsToken)
        }
        if let voipToken = UserDefaults.standard.string(forKey: "truples_apple_voip_token"), !voipToken.isEmpty {
            self.sendVoipTokenToBackend(hexToken: voipToken)
        }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        NotificationCenter.default.post(name: .capacitorDidFailToRegisterForRemoteNotifications, object: error)
        print("[APNs Native] Failed to register for remote notifications: \(error.localizedDescription)")
    }

    private func sendApnsTokenToBackend(hexToken: String) {
        guard let url = URL(string: "https://truples.com/api/notifications/token") else { return }

        var deviceId = UserDefaults.standard.string(forKey: "truples_device_id") ?? ""
        if deviceId.isEmpty {
            deviceId = "device-ios-" + UUID().uuidString.prefix(8).lowercased()
            UserDefaults.standard.set(deviceId, forKey: "truples_device_id")
        }
        let loginId = UserDefaults.standard.string(forKey: "truples_last_login_id") ?? "iostest"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "loginId": loginId,
            "token": hexToken,
            "deviceId": deviceId
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("[APNs Native] Failed to register APNs token to backend: \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse {
                    print("[APNs Native] Backend APNs token registration HTTP status: \(httpResponse.statusCode)")
                }
            }
            task.resume()
        } catch {
            print("[APNs Native] JSON serialization error: \(error.localizedDescription)")
        }
    }

    // MARK: - PKPushRegistryDelegate (Apple VoIP PushKit)

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        if type == .voIP {
            let hexToken = credentials.token.map { String(format: "%02.2hhx", $0) }.joined()
            print("[PushKit Native] Received Apple VoIP Device Token: \(hexToken)")
            UserDefaults.standard.set(hexToken, forKey: "truples_apple_voip_token")
            UserDefaults.standard.synchronize()

            CallKitPlugin.sharedInstance?.setVoipToken(hexToken)

            // 1. Send VoIP token directly to Backend via Native Swift URLSession (Bypasses any JS Bridge dependency)
            self.sendVoipTokenToBackend(hexToken: hexToken)
        }
    }

    private func sendVoipTokenToBackend(hexToken: String) {
        guard let url = URL(string: "https://truples.com/api/notifications/token") else { return }

        var deviceId = UserDefaults.standard.string(forKey: "truples_device_id") ?? ""
        if deviceId.isEmpty {
            deviceId = "device-ios-" + UUID().uuidString.prefix(8).lowercased()
            UserDefaults.standard.set(deviceId, forKey: "truples_device_id")
        }
        let voipDeviceId = deviceId.hasSuffix("-voip") ? deviceId : (deviceId + "-voip")
        let loginId = UserDefaults.standard.string(forKey: "truples_last_login_id") ?? "iostest"

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: String] = [
            "loginId": loginId,
            "token": hexToken,
            "deviceId": voipDeviceId
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    print("[PushKit Native] Failed to register VoIP token to backend: \(error.localizedDescription)")
                } else if let httpResponse = response as? HTTPURLResponse {
                    print("[PushKit Native] Backend VoIP token registration HTTP status: \(httpResponse.statusCode)")
                }
            }
            task.resume()
        } catch {
            print("[PushKit Native] JSON serialization error: \(error.localizedDescription)")
        }
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("[PushKit Native] VoIP Push Token invalidated.")
    }

    func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        if type == .voIP {
            let dict = payload.dictionaryPayload
            print("[PushKit Native] Received VoIP Push Payload: \(dict)")

            // Extract call information from payload safely
            let rawData: [AnyHashable: Any] = (dict["data"] as? [AnyHashable: Any]) ?? dict
            var stringPayload: [String: Any] = [:]
            for (k, v) in rawData {
                if let keyStr = k as? String {
                    stringPayload[keyStr] = v
                }
            }

            let callerName = (stringPayload["callerNickname"] as? String) ?? (stringPayload["callerName"] as? String) ?? (dict["callerNickname"] as? String) ?? "Someone"
            let uuidString = (stringPayload["chatRoomId"] as? String) ?? (stringPayload["callUuid"] as? String) ?? (dict["chatRoomId"] as? String) ?? UUID().uuidString
            let callType = (stringPayload["callType"] as? String) ?? (dict["callType"] as? String) ?? "audio"
            let isVideo = callType.lowercased() == "video"

            let callUUID = UUID(uuidString: uuidString) ?? UUID()
            self.pendingCallPayloads[callUUID.uuidString] = stringPayload

            let update = CXCallUpdate()
            update.remoteHandle = CXHandle(type: .generic, value: callerName)
            update.localizedCallerName = callerName
            update.hasVideo = isVideo

            // Apple Requirement: Report new incoming call immediately within 1 second
            self.provider?.reportNewIncomingCall(with: callUUID, update: update) { error in
                if let error = error {
                    print("[CallKit Native] reportNewIncomingCall error: \(error.localizedDescription)")
                } else {
                    print("[CallKit Native] Apple Native CallKit Banner presented for: \(callerName)")
                }
                completion()
            }
        } else {
            completion()
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        self.pendingCallPayloads.removeAll()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let uuidStr = action.callUUID.uuidString
        print("[CallKit Native] User tapped ANSWER on Apple CallKit banner. UUID: \(uuidStr)")

        // Save answered call state to UserDefaults for web app recovery
        if let payload = self.pendingCallPayloads[uuidStr] {
            if let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                UserDefaults.standard.set(jsonString, forKey: "pending_native_call_answer")
                UserDefaults.standard.synchronize()
            }
        }

        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuidStr = action.callUUID.uuidString
        print("[CallKit Native] User tapped DECLINE/END on Apple CallKit banner. UUID: \(uuidStr)")
        self.pendingCallPayloads.removeValue(forKey: uuidStr)
        UserDefaults.standard.removeObject(forKey: "pending_native_call_answer")
        UserDefaults.standard.synchronize()

        // Report reject to backend via native HTTP
        if let url = URL(string: "https://api.truples.com/call/reject") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body = ["callUuid": uuidStr]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [])
            URLSession.shared.dataTask(with: request).resume()
        }

        action.fulfill()
    }
}
