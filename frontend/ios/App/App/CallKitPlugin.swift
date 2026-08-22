import Foundation
import Capacitor
import CallKit
import PushKit

@objc(CallKitPlugin)
public class CallKitPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "CallKitPlugin"
    public let jsName = "CallKitPlugin"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "getVoipToken", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setLoginId", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "getPendingCallIntent", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "reportIncomingCall", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "endCall", returnType: CAPPluginReturnPromise)
    ]

    public static weak var sharedInstance: CallKitPlugin?
    public static var sharedVoipToken: String?

    override public func load() {
        super.load()
        CallKitPlugin.sharedInstance = self

        if let savedToken = UserDefaults.standard.string(forKey: "truples_apple_voip_token"), !savedToken.isEmpty {
            CallKitPlugin.sharedVoipToken = savedToken
        }

        print("[CallKitPlugin] Direct In-App Plugin loaded into Capacitor Bridge.")
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

    @objc func setLoginId(_ call: CAPPluginCall) {
        guard let loginId = call.getString("loginId"), !loginId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            call.reject("Missing loginId")
            return
        }
        let cleanLoginId = loginId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        UserDefaults.standard.set(cleanLoginId, forKey: "truples_last_login_id")
        UserDefaults.standard.synchronize()

        if let token = CallKitPlugin.sharedVoipToken ?? UserDefaults.standard.string(forKey: "truples_apple_voip_token"), !token.isEmpty {
            AppDelegate.shared?.sendVoipTokenToBackend(hexToken: token, customLoginId: cleanLoginId)
        }
        if let apnsToken = UserDefaults.standard.string(forKey: "truples_fcm_token"), !apnsToken.isEmpty {
            AppDelegate.shared?.sendApnsTokenToBackend(hexToken: apnsToken, customLoginId: cleanLoginId)
        }
        call.resolve(["status": "OK", "loginId": cleanLoginId])
    }

    @objc func reportIncomingCall(_ call: CAPPluginCall) {
        guard let uuidString = call.getString("uuid"),
              let uuid = UUID(uuidString: uuidString),
              let callerName = call.getString("callerName") else {
            call.reject("Missing uuid or callerName")
            return
        }
        let isVideo = call.getBool("isVideo", false)
        AppDelegate.shared?.reportIncomingCall(uuid: uuid, callerName: callerName, isVideo: isVideo, payload: call.options as? [String: Any]) { error in
            if let error = error {
                call.reject("Failed to report incoming call: \(error.localizedDescription)")
            } else {
                call.resolve(["status": "REPORTED"])
            }
        }
    }

    @objc func endCall(_ call: CAPPluginCall) {
        guard let uuidString = call.getString("uuid"),
              let uuid = UUID(uuidString: uuidString) else {
            call.reject("Missing uuid")
            return
        }
        AppDelegate.shared?.endCall(uuid: uuid) { error in
            if let error = error {
                call.reject("Failed to end call: \(error.localizedDescription)")
            } else {
                call.resolve(["status": "ENDED"])
            }
        }
    }

    @objc func getPendingCallIntent(_ call: CAPPluginCall) {
        if let savedJson = UserDefaults.standard.string(forKey: "pending_native_call_answer"),
           let data = savedJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            UserDefaults.standard.removeObject(forKey: "pending_native_call_answer")
            UserDefaults.standard.synchronize()
            call.resolve([
                "hasPending": true,
                "call": obj,
                "intent": obj
            ])
            return
        }
        if let savedPushJson = UserDefaults.standard.string(forKey: "pending_push_call_intent"),
           let data = savedPushJson.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
            UserDefaults.standard.removeObject(forKey: "pending_push_call_intent")
            UserDefaults.standard.synchronize()
            call.resolve([
                "hasPending": true,
                "call": obj,
                "intent": obj
            ])
            return
        }
        call.resolve([
            "hasPending": false,
            "intent": NSNull()
        ])
    }
}
