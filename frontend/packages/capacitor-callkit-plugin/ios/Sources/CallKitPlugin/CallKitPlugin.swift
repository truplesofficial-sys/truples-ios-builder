import Foundation
import Capacitor
import CallKit
import PushKit

@objc(CallKitPlugin)
public class CallKitPlugin: CAPPlugin, CAPBridgedPlugin, CXProviderDelegate, PKPushRegistryDelegate {
    public let identifier = "CallKitPlugin"
    public let jsName = "CallKitPlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getVoipToken", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reportIncomingCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPendingCallIntent", returnType: CAPPluginReturnPromise)
    ]

    public static weak var sharedInstance: CallKitPlugin?
    public static var sharedVoipToken: String?
    private var provider: CXProvider?
    private var callController: CXCallController?
    private var voipRegistry: PKPushRegistry?
    private var pendingPayloads: [String: [AnyHashable: Any]] = [:]

    override public func load() {
        super.load()
        CallKitPlugin.sharedInstance = self
        self.callController = CXCallController()

        if let savedToken = UserDefaults.standard.string(forKey: "truples_apple_voip_token"), !savedToken.isEmpty {
            CallKitPlugin.sharedVoipToken = savedToken
        }

        let configuration = CXProviderConfiguration(localizedName: "Truples")
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = true

        self.provider = CXProvider(configuration: configuration)
        self.provider?.setDelegate(self, queue: nil)

        // Initialize PushKit inside plugin for direct VoIP token capture
        let mainQueue = DispatchQueue.main
        let registry = PKPushRegistry(queue: mainQueue)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.voipRegistry = registry

        print("[CallKitPlugin] SPM Package Plugin & PushKit Registry loaded into Capacitor 7 Bridge.")
    }

    // MARK: - PKPushRegistryDelegate
    public func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        if type == .voIP {
            let hexToken = credentials.token.map { String(format: "%02.2hhx", $0) }.joined()
            print("[CallKitPlugin] Direct PKPushRegistry received VoIP token: \(hexToken)")
            self.setVoipToken(hexToken)
        }
    }

    public func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        print("[CallKitPlugin] PushKit token invalidated.")
    }

    public func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload, for type: PKPushType, completion: @escaping () -> Void) {
        if type == .voIP {
            let dict = payload.dictionaryPayload
            print("[CallKitPlugin] Received VoIP Push Payload: \(dict)")

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

            self.reportIncomingCallNative(uuidString: uuidString, callerName: callerName, hasVideo: isVideo, payload: stringPayload) {
                completion()
            }
        } else {
            completion()
        }
    }

    public func setVoipToken(_ token: String) {
        CallKitPlugin.sharedVoipToken = token
        UserDefaults.standard.set(token, forKey: "truples_apple_voip_token")
        UserDefaults.standard.synchronize()
        self.notifyListeners("onVoipTokenReceived", data: ["token": token])
    }

    @objc func getVoipToken(_ call: CAPPluginCall) {
        let token = CallKitPlugin.sharedVoipToken ?? UserDefaults.standard.string(forKey: "truples_apple_voip_token") ?? ""
        call.resolve(["token": token])
    }

    @objc func getPendingCallIntent(_ call: CAPPluginCall) {
        if let dataStr = UserDefaults.standard.string(forKey: "pending_push_call_intent"),
           let data = dataStr.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            UserDefaults.standard.removeObject(forKey: "pending_push_call_intent")
            UserDefaults.standard.synchronize()
            call.resolve(["hasIntent": true, "intent": json])
        } else {
            call.resolve(["hasIntent": false])
        }
    }

    @objc func reportIncomingCall(_ call: CAPPluginCall) {
        guard let uuidString = call.getString("uuid"),
              let uuid = UUID(uuidString: uuidString),
              let callerName = call.getString("callerName") else {
            call.reject("Missing uuid or callerName")
            return
        }

        let isVideo = call.getBool("hasVideo", false)
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = isVideo

        self.provider?.reportNewIncomingCall(with: uuid, update: update) { error in
            if let error = error {
                call.reject("Failed to report incoming call: \(error.localizedDescription)")
            } else {
                call.resolve(["status": "REPORTED"])
            }
        }
    }

    public func reportIncomingCallNative(uuidString: String, callerName: String, hasVideo: Bool, payload: [AnyHashable: Any]?, completion: (() -> Void)?) {
        let callUUID = UUID(uuidString: uuidString) ?? UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = hasVideo

        if let payload = payload {
            self.pendingPayloads[callUUID.uuidString] = payload
        }

        self.provider?.reportNewIncomingCall(with: callUUID, update: update) { error in
            if let error = error {
                print("[CallKit] reportNewIncomingCall error: \(error.localizedDescription)")
            } else {
                print("[CallKit] Native CallKit incoming call presented successfully for: \(callerName)")
            }
            completion?()
        }
    }

    @objc func endCall(_ call: CAPPluginCall) {
        guard let uuidString = call.getString("uuid"),
              let uuid = UUID(uuidString: uuidString) else {
            call.reject("Missing uuid")
            return
        }

        let endAction = CXEndCallAction(call: uuid)
        let transaction = CXTransaction(action: endAction)

        self.callController?.request(transaction) { error in
            if let error = error {
                call.reject("Failed to end call: \(error.localizedDescription)")
            } else {
                call.resolve(["status": "ENDED"])
            }
        }
    }

    // MARK: - CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        self.pendingPayloads.removeAll()
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        let uuidStr = action.callUUID.uuidString
        var data: [String: Any] = ["callUuid": uuidStr]
        if let payload = self.pendingPayloads[uuidStr] {
            data["payload"] = payload
        }
        self.notifyListeners("onCallAnswer", data: data)
        action.fulfill()
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuidStr = action.callUUID.uuidString
        self.pendingPayloads.removeValue(forKey: uuidStr)
        let data: [String: Any] = ["callUuid": uuidStr]
        self.notifyListeners("onCallReject", data: data)
        action.fulfill()
    }
}
