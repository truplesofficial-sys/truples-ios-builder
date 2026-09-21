import Foundation
import Capacitor
import CallKit
import PushKit
import AVFoundation

@objc(CallKitPlugin)
public class CallKitPlugin: CAPPlugin, CAPBridgedPlugin, CXProviderDelegate, PKPushRegistryDelegate {
    public let identifier = "CallKitPlugin"
    public let jsName = "CallKitPlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getVoipToken", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reportIncomingCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPendingCallIntent", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setSpeakerphoneOn", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "resetAudioMode", returnType: CAPPluginReturnPromise)
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

            let pushType = (stringPayload["type"] as? String) ?? (dict["type"] as? String) ?? ""
            let uuidString = (stringPayload["chatRoomId"] as? String) ?? (stringPayload["callUuid"] as? String) ?? (dict["chatRoomId"] as? String) ?? UUID().uuidString

            if pushType == "CALL_CANCEL" || pushType == "CALL_REJECT" || pushType == "CALL_HANGUP" || pushType == "CALL_TIMEOUT" || pushType == "CALL_CLOSED" || pushType.contains("HANGUP") || pushType.contains("CANCEL") || pushType.contains("REJECT") {
                print("[CallKitPlugin] Received VoIP Call Cancel/Hangup signal (\(pushType)) for UUID: \(uuidString)")
                if let callUUID = UUID(uuidString: uuidString) {
                    let endAction = CXEndCallAction(call: callUUID)
                    let transaction = CXTransaction(action: endAction)
                    self.callController?.request(transaction) { _ in
                        completion()
                    }
                } else {
                    completion()
                }
                return
            }

            let nickname = (stringPayload["callerNickname"] as? String) ?? (dict["callerNickname"] as? String)
            let loginId = (stringPayload["callerLoginId"] as? String) ?? (dict["callerLoginId"] as? String)
            let callerName = (nickname != nil && !nickname!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && nickname != "Someone") ? nickname! :
                             ((loginId != nil && !loginId!.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? loginId! : "Caller")
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

    @objc func setSpeakerphoneOn(_ call: CAPPluginCall) {
        let enabled = call.getBool("enabled", false)
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker])
            if enabled {
                try audioSession.overrideOutputAudioPort(.speaker)
            } else {
                try audioSession.overrideOutputAudioPort(.none)
            }
            call.resolve(["status": "OK", "isSpeaker": enabled])
        } catch {
            call.reject("Failed to set audio route: \(error.localizedDescription)")
        }
    }

    @objc func resetAudioMode(_ call: CAPPluginCall) {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.overrideOutputAudioPort(.none)
            try audioSession.setCategory(.playback, mode: .default, options: [])
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
            call.resolve(["status": "RESET"])
        } catch {
            call.resolve(["status": "RESET_SKIPPED"])
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
