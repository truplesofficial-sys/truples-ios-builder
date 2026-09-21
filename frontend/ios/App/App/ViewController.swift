import UIKit
import Capacitor

class ViewController: CAPBridgeViewController {
    override open func capacitorDidLoad() {
        super.capacitorDidLoad()
        // Register custom in-app CallKitPlugin directly to the Capacitor 7 bridge
        bridge?.registerPluginInstance(CallKitPlugin())
        print("[ViewController] CallKitPlugin registered to Capacitor Bridge.")
    }
}
